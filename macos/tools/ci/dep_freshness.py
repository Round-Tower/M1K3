#!/usr/bin/env python3
"""How far behind are our Swift dependencies — and who is holding each one back?

Born 2026-10-07: swift-transformers sat at 1.1.9 for seven months while 1.3.2 made Gemma
tokenization ~150x faster (the gemma-4 persona: 1,183 ms -> 8 ms, same ids), because
WhisperKit 0.18's own manifest pinned it `.upToNextMinor(from: "1.1.6")`. Nobody saw it:
`swift package resolve` is silent about versions it can't reach. This makes it loud.

For every pin in Package.resolved it reports the current version (or revision), the latest
upstream release, how many releases behind, WHO caps it (our Package.swift and every other
dependency's own manifest at its resolved tag), and the lines from missed release notes
that matter (speed, memory, crash, security). Revision pins (mlx-swift-lm) report commits
behind the default branch too.

    python3 dep_freshness.py [--resolved P] [--package P] [--json | --markdown] [--only-behind] [--fail-if-capped]

Network: GitHub via the `gh` CLI (authenticated, no checkouts needed — dependents'
manifests are read at their resolved tags). Read-only. `--fail-if-capped` exits 3 when a
newer release is unreachable because of a constraint — for a scheduled job, never a PR gate.
Any failed fetch (rate limit, auth, network) marks the report INCOMPLETE and exits 4: a
silent failure must never read as "nothing behind". Release-note text is third-party
input: it is rendered as short, inert code spans (no mentions, links or images).
The pure helpers (parsing, semver, caps, highlights, rows) are unit-tested in
test_dep_freshness.py with the fetchers injected.

Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.8, Prior: none (new file).
Review: same day (pre-push code + security review) — failed fetches are counted (INCOMPLETE,
exit 4), `..<`/`...` ranges keep their upper bound, `reachable` splits a stale lock from a
real cap, notes are inert code spans capped at 160 chars, the body at 60k.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import json
import re
import subprocess
import sys
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
MACOS = HERE.parent.parent

# Lines worth a human's attention in a release we haven't taken.
HIGHLIGHT = re.compile(
    r"\b(speed|faster|perf\w*|latency|memory|leak\w*|crash\w*|security|cve-\d|vulnerab\w*|"
    r"race|deadlock|hang\w*|regression)",
    re.IGNORECASE,
)
MAX_HIGHLIGHTS_PER_RELEASE = 3
MAX_NOTES_PER_PACKAGE = 5
MAX_NOTE_CHARS = 160  # release notes are third-party text: short, inert code spans only
MAX_BODY_CHARS = 60_000  # GitHub's issue body limit is 65,536


# --------------------------------------------------------------------------- #
# Pure helpers (unit-tested)
# --------------------------------------------------------------------------- #


def identity(url: str) -> str:
    """SwiftPM's package identity: the URL's last path component, lowercased, minus `.git`."""
    last = url.rstrip("/").rsplit("/", 1)[-1]
    return re.sub(r"\.git$", "", last).lower()


def owner_repo(url: str) -> tuple[str, str]:
    parts = re.sub(r"\.git$", "", url.rstrip("/")).split("/")
    return parts[-2], parts[-1]


def parse_version(tag: str) -> tuple[int, int, int] | None:
    """A release version as a comparable tuple; None for pre-releases and non-semver tags."""
    m = re.fullmatch(r"v?(\d+)\.(\d+)(?:\.(\d+))?", tag.strip())
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)


@dataclass(frozen=True)
class Requirement:
    kind: str  # upToNextMajor | upToNextMinor | exact | range | revision | branch
    value: str
    upper: str | None = None  # range only
    inclusive: bool = False  # range only: "a"..."b"

    def allows(self, version: str) -> bool | None:
        """SwiftPM's range semantics; None when the requirement isn't a version range."""
        if self.kind in ("revision", "branch"):
            return None
        v, base = parse_version(version), parse_version(self.value)
        if v is None or base is None:
            return None
        if self.kind == "exact":
            return v == base
        if self.kind == "range":
            top = parse_version(self.upper or "")
            if top is None:
                return None
            return base <= v <= top if self.inclusive else base <= v < top
        if self.kind == "upToNextMinor":
            return base <= v < (base[0], base[1] + 1, 0)
        return base <= v < (base[0] + 1, 0, 0)  # upToNextMajor (`from:`)

    def __str__(self) -> str:
        if self.kind == "range":
            return f"range {self.value}{'...' if self.inclusive else '..<'}{self.upper}"
        return f"{self.kind} {self.value}"


_PACKAGE = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*",\s*)?url:\s*"([^"]+)",\s*(.*?)\)\s*(?:,|\n|\]|$)', re.DOTALL)


def parse_requirements(manifest: str) -> dict[str, Requirement]:
    """`.package(url:…)` declarations in a Package.swift, keyed by identity."""
    out: dict[str, Requirement] = {}
    for url, rest in _PACKAGE.findall(manifest):
        rest = rest.strip()
        patterns = [
            (r'^\.upToNextMinor\(\s*from:\s*"([^"]+)"', "upToNextMinor"),
            (r'^\.upToNextMajor\(\s*from:\s*"([^"]+)"', "upToNextMajor"),
            (r'^from:\s*"([^"]+)"', "upToNextMajor"),
            (r'^exact:\s*"([^"]+)"', "exact"),
            (r'^\.exact\(\s*"([^"]+)"', "exact"),
            (r'^revision:\s*"([^"]+)"', "revision"),
            (r'^branch:\s*"([^"]+)"', "branch"),
        ]
        if m := re.search(r'^"([^"]+)"\s*(\.\.<|\.\.\.)\s*"([^"]+)"', rest):
            out[identity(url)] = Requirement("range", m.group(1), m.group(3), inclusive=m.group(2) == "...")
            continue
        for pattern, kind in patterns:
            m = re.search(pattern, rest)
            if m:
                out[identity(url)] = Requirement(kind, m.group(1))
                break
    return out


def capped_by(ident: str, latest: str, *, ours: dict[str, Requirement],
              dependents: dict[str, dict[str, Requirement]]) -> list[str]:
    """Every manifest whose requirement on `ident` excludes `latest` — the reason it's behind."""
    caps = []
    if ident in ours and ours[ident].allows(latest) is False:
        caps.append(f"M1K3 ({ours[ident]})")
    for dependent in sorted(dependents):
        req = dependents[dependent].get(ident)
        if req is not None and req.allows(latest) is False:
            caps.append(f"{dependent} ({req})")
    return caps


@dataclass(frozen=True)
class Release:
    version: str
    date: str
    notes: str


def highlights(releases: list[Release], current: str | None) -> list[str]:
    """Speed / memory / crash / security lines from the releases newer than `current`."""
    floor = parse_version(current) if current else None
    newer = [r for r in releases if (v := parse_version(r.version)) and (floor is None or v > floor)]
    lines = []
    for release in sorted(newer, key=lambda r: parse_version(r.version)):
        hits = [ln.strip().lstrip("-*• ").strip() for ln in release.notes.splitlines() if HIGHLIGHT.search(ln)]
        lines += [f"{release.version}: {hit}" for hit in hits[:MAX_HIGHLIGHTS_PER_RELEASE]]
    return lines


@dataclass(frozen=True)
class Row:
    identity: str
    current: str
    latest: str | None
    behind: int
    capped: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    commits_behind: int | None = None
    # The newest release EVERY constraint allows — above `current` means a stale lock
    # (`swift package update` reaches it), not a cap.
    reachable: str | None = None


@dataclass(frozen=True)
class Report:
    rows: list[Row]
    failures: int  # fetches that errored (rate limit, auth, network) — never read as "current"
    fetches: int


def reachable_version(ident: str, rels: list[Release], reqs: list[Requirement]) -> str | None:
    allowed = [r for r in rels if all(q.allows(r.version) is not False for q in reqs)]
    return max(allowed, key=lambda r: parse_version(r.version)).version if allowed else None


def build_rows(
    resolved: dict,
    ours: dict[str, Requirement],
    *,
    releases: Callable[[str, str], list[Release] | None],
    dependent_manifest: Callable[[str, str, str], str | None],
    commits_behind: Callable[[str, str], int | None],
) -> Report:
    """Fetchers return None when the fetch FAILED, and [] / "" when there's genuinely nothing."""
    pins = resolved.get("pins", [])
    fetches = failures = 0

    def fetched(value, empty):
        nonlocal fetches, failures
        fetches += 1
        if value is None:
            failures += 1
            return empty
        return value

    dependents = {
        p["identity"]: parse_requirements(
            fetched(dependent_manifest(p["identity"], p["location"], p["state"]["version"]), "")
        )
        for p in pins if p["state"].get("version")
    }
    rows = []
    for pin in pins:
        ident, url, state = pin["identity"], pin["location"], pin["state"]
        rels = [r for r in fetched(releases(ident, url), []) if parse_version(r.version)]
        latest = max(rels, key=lambda r: parse_version(r.version)).version if rels else None
        version = state.get("version")
        if version:
            cur = parse_version(version)
            behind = sum(1 for r in rels if parse_version(r.version) > cur) if cur else 0
            others = {k: v for k, v in dependents.items() if k != ident}
            caps = capped_by(ident, latest, ours=ours, dependents=others) if behind else []
            reqs = [q for q in [ours.get(ident), *(d.get(ident) for d in others.values())] if q]
            reach = reachable_version(ident, rels, reqs) if behind else None
            rows.append(Row(ident, version, latest, behind, caps, highlights(rels, version), reachable=reach))
        else:
            rev = state.get("revision", "")
            behind_commits = commits_behind(url, rev)
            fetches += 1
            failures += behind_commits is None
            rows.append(Row(ident, rev[:8], latest, 0, commits_behind=behind_commits))
    return Report(rows, failures, fetches)


def capped_rows(rows: list[Row]) -> list[Row]:
    return [r for r in rows if r.capped]


def _stale(r: Row) -> str:
    """The `swift package update` hint, when a newer release is reachable without moving anything."""
    cur, reach = parse_version(r.current), parse_version(r.reachable or "")
    return f"update → {r.reachable}" if cur and reach and reach > cur else ""


def _incomplete(report: Report) -> str:
    if not report.failures:
        return ""
    return f"⚠️ INCOMPLETE — {report.failures} of {report.fetches} GitHub fetches failed; rows may read current. "


def _inert(note: str) -> str:
    """Third-party release-note text as one inert code span: no mentions, links, images or HTML."""
    flat = re.sub(r"[`\r\n]+", " ", note).strip()
    if len(flat) > MAX_NOTE_CHARS:
        flat = flat[: MAX_NOTE_CHARS - 1] + "…"
    return f"`{flat}`"


def render(report: Report, only_behind: bool) -> str:
    rows = report.rows
    shown = [r for r in rows if not only_behind or r.behind or (r.commits_behind or 0) > 0]
    shown.sort(key=lambda r: (-(len(r.capped) > 0), -r.behind, r.identity))
    lines = [_incomplete(report)] if report.failures else []
    lines.append(f"{'package':28} {'current':10} {'latest':10} {'behind':>7}  capped by")
    for r in shown:
        behind = f"{r.commits_behind} commits" if r.commits_behind is not None else str(r.behind)
        why = "; ".join([*r.capped, *filter(None, [_stale(r)])]) or "—"
        lines.append(f"{r.identity:28} {r.current:10} {r.latest or '—':10} {behind:>7}  {why}")
        lines += [f"{'':4}↳ {note}" for note in r.notes]
    return "\n".join(lines)


def render_markdown(report: Report, generated: str) -> str:
    """The rolling issue body: capped packages first, each with its blocker and missed notes.

    The FIRST line carries `**N held back` — dep-freshness.yml reads exactly that (head -1).
    """
    shown = [r for r in report.rows if r.behind or (r.commits_behind or 0) > 0]
    shown.sort(key=lambda r: (-(len(r.capped) > 0), -r.behind, r.identity))
    capped = [r for r in shown if r.capped]
    out = [
        (f"{_incomplete(report)}Generated {generated} by `macos/tools/ci/dep_freshness.py` — "
         f"{len(shown)} behind, **{len(capped)} held back by a constraint**."),
        "",
        "| package | current | latest | behind | capped by |",
        "|---|---|---|---|---|",
    ]
    for r in shown:
        behind = f"{r.commits_behind} commits" if r.commits_behind is not None else str(r.behind)
        caps = "; ".join([*(f"**{c}**" for c in r.capped), *filter(None, [_stale(r)])]) or "—"
        out.append(f"| `{r.identity}` | {r.current} | {r.latest or '—'} | {behind} | {caps} |")
    notes = [f"- `{r.identity}` {_inert(note)}" for r in shown for note in r.notes[:MAX_NOTES_PER_PACKAGE]]
    if notes:
        out += ["", "### What we're missing (speed, memory, crash, security)", "", *notes]
    out += ["", ("A capped package needs its blocker moved first; `update → X` needs only "
                 "`swift package update`. Bumps are probe-first and owe the gemma-4 tool-call smoke "
                 "(`macos/CLAUDE.md`).")]
    body = "\n".join(out)
    return body if len(body) <= MAX_BODY_CHARS else body[: MAX_BODY_CHARS - 40] + "\n\n…(truncated)"


# --------------------------------------------------------------------------- #
# GitHub fetchers (the `gh` CLI)
# --------------------------------------------------------------------------- #


def _gh(path: str) -> object | None:
    proc = subprocess.run(["gh", "api", path], capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def gh_releases(_ident: str, url: str) -> list[Release] | None:
    """Releases (with notes) merged with plain tags — some repos tag newer than they release.
    None when the releases fetch itself failed."""
    if "github.com" not in url:
        return []
    owner, repo = owner_repo(url)
    data = _gh(f"repos/{owner}/{repo}/releases?per_page=50")
    if not isinstance(data, list):
        return None
    rels = {r["tag_name"].lstrip("v"): Release(r["tag_name"].lstrip("v"), (r.get("published_at") or "")[:10],
                                                r.get("body") or "")
            for r in data if not r.get("draft") and not r.get("prerelease")}
    tags = _gh(f"repos/{owner}/{repo}/tags?per_page=100")
    for t in tags if isinstance(tags, list) else []:
        rels.setdefault(t["name"].lstrip("v"), Release(t["name"].lstrip("v"), "", ""))
    return list(rels.values())


def gh_manifest(_ident: str, url: str, version: str) -> str | None:
    """The dependency's Package.swift at its resolved tag; None when no tag spelling fetched."""
    if "github.com" not in url:
        return ""
    owner, repo = owner_repo(url)
    for ref in (version, f"v{version}"):
        data = _gh(f"repos/{owner}/{repo}/contents/Package.swift?ref={ref}")
        if isinstance(data, dict) and data.get("content"):
            try:
                return base64.b64decode(data["content"]).decode("utf-8", "replace")
            except (ValueError, binascii.Error):
                return None
    return None


def gh_commits_behind(url: str, rev: str) -> int | None:
    if "github.com" not in url or not rev:
        return None
    owner, repo = owner_repo(url)
    meta = _gh(f"repos/{owner}/{repo}")
    branch = meta.get("default_branch") if isinstance(meta, dict) else None
    cmp = _gh(f"repos/{owner}/{repo}/compare/{rev}...{branch}") if branch else None
    return cmp.get("ahead_by") if isinstance(cmp, dict) else None


def _parallel(fn: Callable, keys: list[tuple]) -> dict[tuple, object]:
    with ThreadPoolExecutor(max_workers=8) as pool:
        return dict(zip(keys, pool.map(lambda k: fn(*k), keys)))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--resolved", type=Path, default=MACOS / "Package.resolved")
    ap.add_argument("--package", type=Path, default=MACOS / "Package.swift")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--markdown", action="store_true", help="the rolling-issue body (behind only)")
    ap.add_argument("--only-behind", action="store_true")
    ap.add_argument("--fail-if-capped", action="store_true", help="exit 3 when a constraint blocks a newer release")
    args = ap.parse_args(argv)

    resolved = json.loads(args.resolved.read_text())
    ours = parse_requirements(args.package.read_text())
    pins = resolved.get("pins", [])
    # Fetch everything up front, in parallel, then build from the caches.
    rel = _parallel(gh_releases, [(p["identity"], p["location"]) for p in pins])
    man = _parallel(gh_manifest, [(p["identity"], p["location"], p["state"]["version"])
                                  for p in pins if p["state"].get("version")])
    rev = _parallel(gh_commits_behind, [(p["location"], p["state"].get("revision", ""))
                                        for p in pins if not p["state"].get("version")])
    report = build_rows(
        resolved, ours,
        releases=lambda i, u: rel.get((i, u), []),
        dependent_manifest=lambda i, u, v: man.get((i, u, v), ""),
        commits_behind=lambda u, r: rev.get((u, r)),
    )
    if args.json:
        print(json.dumps({"failures": report.failures, "fetches": report.fetches,
                          "rows": [asdict(r) for r in report.rows]}, indent=1))
    elif args.markdown:
        print(render_markdown(report, generated=datetime.now(timezone.utc).strftime("%Y-%m-%d")))
    else:
        print(render(report, args.only_behind))
    if report.failures:
        print(f"✗ {report.failures} of {report.fetches} fetches failed — report incomplete", file=sys.stderr)
        return 4  # never let an incomplete report overwrite the rolling issue
    return 3 if args.fail_if_capped and capped_rows(report.rows) else 0


if __name__ == "__main__":
    sys.exit(main())
