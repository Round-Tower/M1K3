#!/usr/bin/env python3
"""Watch a PR until it is landable — by head sha, with the repo's own rules.

Landing a PR here means: the REQUIRED CI jobs are green on the head sha, and
enough review passes have been read against THAT head. Before this script the
watcher was rewritten in a session scratchpad every day (five times on
2026-09-12 alone) and died with the session; the rules it encodes were folklore
in project memory. Now they are code, tested in test_pr_watch.py:

* A summon pass (`@claude` on the PR, claude.yml) posts "**Claude finished …**"
  and names the head it reviewed in a backticked sha. A pass naming an OLDER
  head does not count — the summon reviews whatever head it checks out at run
  time, and a fold pushed seconds after the summon is reviewed by nobody.
* The auto pass (claude-code-review-mac.yml, fires on `synchronize`) names no
  sha; it counts when the review workflow's run FOR THIS HEAD completed green.
* Placeholders ("**Claude working…**", an unchecked `- [ ]` checklist, the
  older "I'll analyze this and get back to you") never count.
* The mobile job (iOS + visionOS shells, ~19 min) is ADVISORY unless the diff
  touches the mobile shell, the project spec, or ci.yml. Package-only changes
  do not wait for it; a break there is fixed forward, with Xcode Cloud as the
  backstop. Master has no required status checks (checked 2026-09-12) — every
  gate is ours.
* `--passes 0` is the trivial-head rule: a comment-only fold or a clean master
  merge whose substantive head already had two passes merges on green CI.

    python3 pr_watch.py <PR> [--passes 2] [--once] [--interval 60] [--timeout 5400]

Exit 0 = landable now; 1 = a required job failed; 2 = not ready (--once) or
timed out; 3 = the PR is not open; 4 = gh itself failed. Read-only: never
merges, never comments. tools/ci/land.sh wraps it.

Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85 (every comment
shape is pinned from bodies read off PR #293; the job names are the ci.yml
strings; the gh wiring is verify-by-run against a live PR). Prior: Unknown
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from enum import Enum

JOB_GATE = "Detect compilable changes"
JOB_SWIFT_TEST = "Swift · Mac MVP (swift test)"
JOB_APP = "Swift · App shell (xcodebuild)"
JOB_MOBILE = "Swift · iOS + visionOS shells (xcodebuild)"
JOB_GUARDS = "Project guards (test scheme · store targets)"
JOB_DOCS = "Docs match the code (module map)"

ALWAYS_REQUIRED = frozenset({JOB_GATE, JOB_SWIFT_TEST, JOB_APP, JOB_GUARDS, JOB_DOCS})
# Paths only the mobile job compiles. project.yml defines every target; ci.yml
# changes the jobs themselves — both make the full matrix required.
MOBILE_PATH_PREFIXES = (
    "macos/M1K3iOSApp/",
    "macos/M1K3visionOS/",
    "macos/UITests/",
    "macos/project.yml",
    ".github/workflows/ci.yml",
)

BOT_LOGIN = "claude[bot]"
GREEN = {"success", "skipped"}
RED = {"failure", "cancelled", "timed_out", "action_required", "startup_failure"}


class Kind(Enum):
    PLACEHOLDER = "placeholder"
    SUMMON = "summon"
    REVIEW = "review"


_CHECKBOX = re.compile(r"^\s*- \[( |x)\] ")
_PASS_HEADER = re.compile(r"^#{2,4} .*\bpass\b", re.IGNORECASE)
_HEAD = re.compile(r"\bhead `([0-9a-f]{7,40})`")


def _progress_unchecked(text: str) -> bool:
    """An unchecked box in the bot's OWN progress checklist — the list block
    directly under its "### … pass" header. An unchecked item elsewhere (a
    trailing "optional cleanup" list in a finished review) is not progress."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if _PASS_HEADER.match(line):
            block = lines[i + 1:]
            while block and not block[0].strip():
                block = block[1:]
            for item in block:
                m = _CHECKBOX.match(item)
                if not m:
                    break
                if m.group(1) == " ":
                    return True
            return False
    return any(m and m.group(1) == " " for m in map(_CHECKBOX.match, lines))


def classify(body: str) -> Kind:
    """One of the three shapes claude[bot] posts on a PR thread."""
    text = body.strip()
    if (
        text.startswith("**Claude working")
        or text.startswith("### Review in progress")
        or "Claude Code is working" in text
        or "I'll analyze this" in text
    ):
        return Kind.PLACEHOLDER
    if _progress_unchecked(text):
        return Kind.PLACEHOLDER
    if text.startswith("**Claude finished"):
        return Kind.SUMMON
    return Kind.REVIEW


def named_heads(body: str) -> list[str]:
    """Every sha a summon pass names as a head. The header wording drifts
    ("review of final head `x`", "Final pass — review of head `x`",
    "Review — head `x`" all seen on 2026-09-12), so anchor on the word "head"
    and the backticks only. Auto passes name none."""
    return _HEAD.findall(body)


def _names(head: str, shas: list[str]) -> bool:
    return any(head.startswith(sha) or sha.startswith(head) for sha in shas)


def summon_passes(head: str, comments: list[dict]) -> int:
    """Finished summon passes that name THIS head."""
    return sum(
        1
        for c in comments
        if c.get("user", {}).get("login") == BOT_LOGIN
        and classify(c.get("body", "")) is Kind.SUMMON
        and _names(head, named_heads(c.get("body", "")))
    )


def auto_pass_ok(head: str, review_runs: list[dict]) -> bool:
    """The review workflow's NEWEST run on this head finished green. An older
    green run does not vouch for a re-triggered one still in progress."""
    mine = [r for r in review_runs if r.get("headSha") == head]
    if not mine:
        return False
    newest = max(mine, key=lambda r: r.get("createdAt", ""))
    return newest.get("status") == "completed" and newest.get("conclusion") == "success"


def required_jobs(changed_files: list[str]) -> frozenset[str]:
    if any(p.startswith(MOBILE_PATH_PREFIXES) for p in changed_files):
        return ALWAYS_REQUIRED | {JOB_MOBILE}
    return ALWAYS_REQUIRED


@dataclass
class CIVerdict:
    state: str  # green | red | pending
    detail: str = ""
    advisory: str = ""  # non-required jobs that are red, reported never blocking


def ci_verdict(required: frozenset[str] | set[str], jobs: dict[str, str | None]) -> CIVerdict:
    failed = sorted(n for n in required if jobs.get(n) in RED)
    pending = sorted(n for n in required if jobs.get(n) not in GREEN and n not in failed)
    advisory = sorted(n for n, c in jobs.items() if n not in required and c in RED)
    adv = ", ".join(advisory)
    if failed:
        return CIVerdict("red", "failed: " + ", ".join(failed), adv)
    if pending:
        return CIVerdict("pending", "waiting: " + ", ".join(pending), adv)
    return CIVerdict("green", "", adv)


@dataclass
class Verdict:
    ready: bool
    ci: CIVerdict
    passes: int
    passes_needed: int
    summary: str
    reasons: list[str] = field(default_factory=list)


def verdict(
    head: str,
    changed_files: list[str],
    jobs: dict[str, str | None],
    comments: list[dict],
    auto_ok: bool,
    passes_needed: int,
) -> Verdict:
    ci = ci_verdict(required_jobs(changed_files), jobs)
    passes = summon_passes(head, comments) + (1 if auto_ok else 0)
    reasons: list[str] = []
    if ci.state != "green":
        reasons.append(f"CI {ci.state} ({ci.detail})")
    if passes < passes_needed:
        reasons.append(f"passes {passes}/{passes_needed} on {head[:8]}")
    ready = not reasons
    bits = [f"head {head[:8]}", f"CI {ci.state}" + (f" ({ci.detail})" if ci.detail else "")]
    if ci.advisory:
        bits.append(f"advisory red: {ci.advisory}")
    bits.append(f"passes {passes}/{passes_needed}")
    summary = " · ".join(bits) + (" → READY" if ready else "")
    return Verdict(ready, ci, passes, passes_needed, summary, reasons)


# ---------------------------------------------------------------- gh wiring --


def _gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def _gh_json(*args: str):
    return json.loads(_gh(*args))


def snapshot(repo: str, pr: int) -> tuple[str, str, list[str], dict[str, str | None], list[dict], bool, int]:
    view = _gh_json("pr", "view", str(pr), "--repo", repo, "--json", "state,headRefOid")
    head = view["headRefOid"]
    # REST + --paginate: `gh pr view --json files` caps at 100 files, and a
    # dropped mobile-shell path would silently demote the mobile job to advisory.
    files = [f["filename"] for page in _gh_json("api", "--paginate", "--slurp", f"repos/{repo}/pulls/{pr}/files") for f in page]
    jobs: dict[str, str | None] = {}
    runs = _gh_json("run", "list", "--repo", repo, "--workflow", "ci.yml", "--limit", "40",
                    "--json", "headSha,databaseId,status,conclusion,createdAt")
    mine = [r for r in runs if r["headSha"] == head]
    if mine:
        newest = max(mine, key=lambda r: r["createdAt"])
        for j in _gh_json("api", f"repos/{repo}/actions/runs/{newest['databaseId']}/jobs")["jobs"]:
            jobs[j["name"]] = j.get("conclusion")
    review_runs = _gh_json("run", "list", "--repo", repo, "--workflow", "claude-code-review-mac.yml",
                           "--limit", "40", "--json", "headSha,status,conclusion,createdAt")
    comments = _gh_json("api", "--paginate", "--slurp", f"repos/{repo}/issues/{pr}/comments")
    comments = [c for page in comments for c in page]
    inline = _gh_json("api", "--paginate", "--slurp", f"repos/{repo}/pulls/{pr}/comments")
    inline_count = sum(len(page) for page in inline)
    return view["state"], head, files, jobs, comments, auto_pass_ok(head, review_runs), inline_count


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("pr", type=int)
    ap.add_argument("--passes", type=int, default=2, help="review passes required on the head (0 = trivial head)")
    ap.add_argument("--once", action="store_true", help="report once, no polling")
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--timeout", type=int, default=5400)
    ap.add_argument("--repo", default=None, help="owner/name (default: the current repo)")
    args = ap.parse_args(argv)
    repo = args.repo or _gh_json("repo", "view", "--json", "nameWithOwner")["nameWithOwner"]

    deadline = time.monotonic() + args.timeout
    while True:
        try:
            state, head, files, jobs, comments, auto_ok, inline = snapshot(repo, args.pr)
        except subprocess.CalledProcessError as err:
            # A gh blip (rate limit, 5xx) must not read as "CI red": exit 4 once,
            # or wait out the interval and look again while polling.
            print(f"gh failed: {err.stderr.strip()[:200]}", flush=True)
            if args.once or time.monotonic() >= deadline:
                return 4
            time.sleep(args.interval)
            continue
        if state != "OPEN":
            print(f"PR #{args.pr} is {state}", flush=True)
            return 3
        v = verdict(head, files, jobs, comments, auto_ok, args.passes)
        stamp = time.strftime("%H:%M:%S")
        print(f"{stamp} #{args.pr} {v.summary} · inline comments {inline}", flush=True)
        if v.ready:
            if inline:
                print(f"read the {inline} inline comment(s) before landing: gh api repos/{repo}/pulls/{args.pr}/comments", flush=True)
            return 0
        if v.ci.state == "red":
            print("required CI is red — fix, push, re-watch", flush=True)
            return 1
        if args.once:
            return 2
        if time.monotonic() >= deadline:
            print("timed out", flush=True)
            return 2
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
