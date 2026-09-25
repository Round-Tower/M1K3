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
* The auto pass (claude-code-review-mac.yml, fires on `synchronize` — path-gated
  to Swift, the manifest, project.yml, macos/tools/ and the workflows; a
  docs-only head gets none and needs a summon) counts when the review
  workflow's run FOR THIS HEAD completed green AND posted its comment — the
  finished bot comment that links THAT run's id (the action's tracking
  comment), else the first inside the run's window that links no other run:
  a summon fired in the same breath as the push lands its placeholder inside
  the window, ahead of the run's own comment (#409). The action skips itself — green in ~13 s, no comment —
  whenever the workflow file on the PR differs from master's (#408): that is
  no pass. The comment it does post is summon-shaped and may name the head
  ("Claude finished … Reviewed head `x`", #404); it is counted once.
* Placeholders ("**Claude working…**", an unchecked `- [ ]` checklist, the
  older "I'll analyze this and get back to you") never count.
* The mobile job (iOS + visionOS shells, ~19 min) is ADVISORY unless the diff
  touches the mobile shell, a Mac-shell file the MobileShell compiles, the
  project spec, the package manifest, or ci.yml.
  Package-only changes do not wait for it; a break there is fixed forward, with
  Xcode Cloud as the backstop. Master has no required status checks (checked
  2026-09-12) — every gate is ours. Since 2026-09-24 ci.yml itself skips the
  App-shell and mobile xcodebuild jobs on a PR whose diff misses their paths
  (pushes to master/develop build everything); a skipped job reads green here.
* `--passes 0` is the trivial-head rule: a comment-only fold or a clean master
  merge whose substantive head already had two passes merges on green CI.

    python3 pr_watch.py <PR> [--passes 2] [--once] [--interval 60] [--timeout 5400]

Exit 0 = landable now; 1 = a required job failed; 2 = not ready (--once) or
timed out; 3 = the PR is not open; 4 = gh itself failed. Read-only: never
merges, never comments. tools/ci/land.sh wraps it.

Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85 (every comment
shape is pinned from bodies read off PR #293; the job names are the ci.yml
strings; the gh wiring is verify-by-run against a live PR). Prior: Unknown

Review: Kev + claude-fable-5.1, 2026-09-15 — `named_heads` also reads "head (sha)"
unbackticked (#347's second and third passes read 0/2 on a twice-reviewed head).
Review: Kev + claude-opus-5, 2026-09-14 — `named_heads` also reads a backticked
sha in the pass's own title (the first markdown header line): #318's summon
wrote "### Review of `75c23b64`" with no word "head", and the watch read 0/2 on
a reviewed head. Title only, so a finding header quoting an older commit is not
credited (review 2 on #318). Dedup keeps document order. Confidence now 0.85.
Review: Kev + claude-fable-5.1, 2026-09-24 — MOBILE_PATH_PREFIXES gains the
package manifest (Package.swift / Package.resolved) to mirror ci.yml's new
`mobile` filter: a dependency bump is exactly where the iOS shell breaks. The
watch needs no change for the now path-gated App-shell job — GREEN already
holds "skipped". Summon 1 on #408 then caught the mirror being incomplete: the
Mac-shell files the MobileShell template compiles (AvatarView, ReadingText,
Phosphor…, project.yml lines 87–118 and 373–374) are now prefixes too, pinned
against project.yml by test; UITests/ left the list — it is a test target no
CI job compiles, so it bought a 19-min wait for nothing. Summon 2: M1K3.icon
joins the prefixes — the iOS target runs actool on the shared document with its
own idiom set, so "App-shell compiles it too" was not a reason. The widened
review trigger then exposed two counting bugs: (1) a validation-skipped run
(13 s, no comment — the action refuses a workflow file that differs from
master's) read as an auto pass; (2) the auto pass's own comment is
summon-shaped and names the head, so one review could count as 2/2. An auto
pass is now the run plus the comment it posted, counted once
(auto_pass_comment; verdict's auto_comment). Confidence now 0.85 — both
shapes are pinned from #408's and #404's real threads.
Review: Kev + claude-fable-5.1, 2026-09-25 — auto_pass_comment attributes by
run id first (#409, summon 2 on #408): a summon fired in the same breath as the
push posts its placeholder inside the auto run's window and ahead of the run's
own comment, so it was returned as the auto pass, the run's `gh pr comment`
review counted zero, and a substantive PR would have waited for a third review.
The action's tracking comment links `actions/runs/<id>` (read off #400/#401/
#404); snapshot now fetches databaseId; the window fallback skips a comment
that links another run. Confidence now 0.9.
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
# Paths the mobile job compiles that the always-required App-shell job does not
# vouch for. project.yml defines every target; the package manifest moves the
# dependencies the shell links; ci.yml changes the jobs themselves — each makes
# the full matrix required. The M1K3App/ entries are the files the MobileShell
# template pulls out of the Mac shell (project.yml `MobileShell.sources` and the
# M1K3iOS target) — test_pr_watch pins this list against project.yml. M1K3.icon
# is here because the iOS target compiles the same document with its own idiom
# set, so App-shell green does not vouch for it. Not here: UITests/ (test
# targets; no CI job compiles them).
MOBILE_PATH_PREFIXES = (
    "macos/M1K3iOSApp/",
    "macos/M1K3visionOS/",
    "macos/M1K3.icon/",
    "macos/M1K3App/AvatarView.swift",
    "macos/M1K3App/AvatarEmotion+SwiftUI.swift",
    "macos/M1K3App/PixelFont.swift",
    "macos/M1K3App/ReadingMode.swift",
    "macos/M1K3App/ReadingText.swift",
    "macos/M1K3App/SpeechHighlight.swift",
    "macos/M1K3App/KaraokeReadingText.swift",
    "macos/M1K3App/CompanionAvatarView.swift",
    "macos/M1K3App/CodeBlockView.swift",
    "macos/M1K3App/PhosphorMaterial.swift",
    "macos/M1K3App/Phosphor.metal",
    "macos/M1K3App/PrivacyInfo.xcprivacy",
    "macos/M1K3App/Resources/Fonts/",
    "macos/project.yml",
    "macos/Package.swift",
    "macos/Package.resolved",
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
# "…pass on final head (3922a21d)" — the sha in parentheses, unbackticked (#347, 2026-09-15).
_HEAD_PAREN = re.compile(r"\bhead \(([0-9a-f]{7,40})\)")
# "Reviewing head f10c752c" — bare hex after "head", no delimiter (#334, 2026-09-14).
_HEAD_BARE = re.compile(r"\bhead ([0-9a-f]{7,40})\b")
_HEADER_LINE = re.compile(r"^#{2,4} ")
_SHA = re.compile(r"`([0-9a-f]{7,40})`")
# The action's tracking-comment anchor. If the action ever renames "View job",
# the identity match silently falls back to the window heuristic and #409 comes
# back — re-pin from a live thread, as classify's wording list has needed
# (#334, #347, #404).
_RUN_LINK = re.compile(r"\[View job\]\([^)]*?/actions/runs/(\d+)")


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
    """Every sha a summon pass names as a head, in document order. The header
    wording drifts ("review of final head `x`", "Final pass — review of head
    `x`", "Review — head `x`" all seen on 2026-09-12; "Review of `x`" with no
    word "head" on #318, 2026-09-14), so a sha counts when it follows the word
    "head" anywhere — backticked, or in parentheses as on #347 (2026-09-15:
    "second full pass on final head (3922a21d)") — or sits backticked in the
    pass's own title — the FIRST markdown header line. A later "####" finding header quoting an older commit,
    and a sha in body prose, name nothing. An auto pass's comment may name the
    head too (#404, 2026-09-24) — verdict() counts that review once."""
    shas: list[str] = []
    title_read = False
    for line in body.splitlines():
        found = _HEAD.findall(line) + _HEAD_PAREN.findall(line) + _HEAD_BARE.findall(line)
        if not title_read and _HEADER_LINE.match(line):
            title_read = True
            found += _SHA.findall(line)
        for sha in found:
            if sha not in shas:
                shas.append(sha)
    return shas


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


def linked_run_id(body: str) -> str | None:
    """The workflow run a bot comment links — the action's own
    "[View job](…/actions/runs/N)" anchor on every summon and auto run's tracking
    comment. Anchored to that markdown shape, so a review that cites some run's
    URL in its prose links nothing. None for a comment a run posted through
    `gh pr comment` (the mac review's findings)."""
    mt = _RUN_LINK.search(body)
    return mt.group(1) if mt else None


def _newest_green_review_run(head: str, review_runs: list[dict]) -> dict | None:
    """The review workflow's NEWEST run on this head, if it finished green. An
    older green run does not vouch for a re-triggered one still in progress."""
    mine = [r for r in review_runs if r.get("headSha") == head]
    if not mine:
        return None
    newest = max(mine, key=lambda r: r.get("createdAt", ""))
    if newest.get("status") == "completed" and newest.get("conclusion") == "success":
        return newest
    return None


def auto_pass_comment(head: str, review_runs: list[dict], comments: list[dict]) -> dict | None:
    """The comment the newest green review run on this head posted. By identity
    first: the finished claude[bot] comment that links THIS run's id (the
    action's tracking comment). Then by time: the first finished bot comment
    created inside the run's window that links no OTHER run — a summon fired in
    the same breath as the push posts its placeholder seconds later, inside the
    window and ahead of the run's own comment, and was read as the auto pass
    while the run's real `gh pr comment` review counted zero (#409). None when
    the run posted nothing: the action skips itself, green in ~13 s, whenever
    the workflow file on the PR differs from master's (#408), and a run that
    reviewed nothing is not a pass. ISO-8601 Z timestamps compare as strings."""
    run = _newest_green_review_run(head, review_runs)
    if run is None:
        return None
    finished = [
        c for c in comments
        if c.get("user", {}).get("login") == BOT_LOGIN and classify(c.get("body", "")) is not Kind.PLACEHOLDER
    ]
    run_id = str(run.get("databaseId") or "")
    if run_id:
        for c in finished:
            if linked_run_id(c.get("body", "")) == run_id:
                return c
    start, end = run.get("createdAt", ""), run.get("updatedAt", "")
    for c in finished:
        linked = linked_run_id(c.get("body", ""))
        if run_id and linked is not None and linked != run_id:
            continue  # another run's comment (a concurrent summon), not this one's
        created = c.get("created_at", "")
        if start <= created <= (end or created):
            return c
    return None


def auto_pass_ok(head: str, review_runs: list[dict], comments: list[dict] | None = None) -> bool:
    """Green newest run on this head — and, when the thread is given, the
    comment it posted (see auto_pass_comment). The watch always passes the
    thread; the two-argument form is the 2026-09-12 rule kept for its pins."""
    if comments is None:
        return _newest_green_review_run(head, review_runs) is not None
    return auto_pass_comment(head, review_runs, comments) is not None


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
    auto_comment: dict | None = None,
) -> Verdict:
    ci = ci_verdict(required_jobs(changed_files), jobs)
    # The auto pass's own comment can be summon-shaped AND name the head
    # ("Claude finished … ### Reviewed head `x`", #404) — then summon_passes has
    # already counted it. One review is one pass.
    auto_extra = 1 if auto_ok else 0
    if auto_ok and auto_comment is not None:
        body = auto_comment.get("body", "")
        if classify(body) is Kind.SUMMON and _names(head, named_heads(body)):
            auto_extra = 0
    passes = summon_passes(head, comments) + auto_extra
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


def snapshot(repo: str, pr: int) -> tuple[str, str, list[str], dict[str, str | None], list[dict], dict | None, int]:
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
                           "--limit", "40", "--json", "headSha,databaseId,status,conclusion,createdAt,updatedAt")
    comments = _gh_json("api", "--paginate", "--slurp", f"repos/{repo}/issues/{pr}/comments")
    comments = [c for page in comments for c in page]
    inline = _gh_json("api", "--paginate", "--slurp", f"repos/{repo}/pulls/{pr}/comments")
    inline_count = sum(len(page) for page in inline)
    return view["state"], head, files, jobs, comments, auto_pass_comment(head, review_runs, comments), inline_count


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
            state, head, files, jobs, comments, auto_comment, inline = snapshot(repo, args.pr)
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
        v = verdict(head, files, jobs, comments, auto_comment is not None, args.passes, auto_comment=auto_comment)
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
