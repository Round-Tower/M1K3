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
* Passes are inferred from the diff unless `--passes N` says otherwise: 2 when
  any changed file is a risk surface (RISK_SURFACE_PATTERNS, read off the
  2026-10-04 audit of #287–#480), else 1. An explicit N always wins. The rule
  lives in ../../../CLAUDE.md.
* A docs-only head gets no auto pass (the review workflow is path-gated), so
  one pass there means a summon; without one the watch waits to its timeout.
* `--passes 0` is the trivial-head rule: a comment-only fold or a clean master
  merge whose head already had its passes merges on green CI.
* A pass lands nothing unless it says so. Every review prompt (claude-code-review*.yml,
  claude.yml) asks for a closing `VERDICT: APPROVE @ <sha>` or
  `VERDICT: CHANGES_REQUESTED @ <sha>` line. The newest pass on the head — the newest
  N when N passes are owed — must APPROVE naming this head; a missing, malformed or
  CHANGES_REQUESTED verdict, or one naming another sha, refuses. Under `--passes 0`
  a head with nothing posted reads no verdict, but a pass on it still must approve.
* Only an AUTO_LAND_AUTHORS PR whose head branch lives in this repo lands. M1K3 is
  public: a contributor's or a bot's PR, or anything from a fork, is merged by hand.

    python3 pr_watch.py <PR> [--passes N] [--once] [--interval 60] [--timeout 5400]

Exit 0 = landable now; 1 = a required job failed; 2 = not ready (--once) or
timed out; 3 = the PR is not open; 4 = gh itself failed; 5 = fewer passes than
the diff needs, with no --why. Read-only: never
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
Review: Kev + claude-fable-5.1, 2026-09-30 — a finished summon that names NO sha counts
when it started after the head's first CI run (#455 read 0/1; #452's "head (`sha`)" shape
also read 1/2 — both now count). Three PRs landed on `--passes 0` in one day over this.
Review: Kev + claude-opus-5-5, 2026-09-29 — named_heads reads a bare sha in the title
(#437's summons wrote "### Reviewing f2dcbc56" and read 1/2 on a thrice-reviewed head, #304).
A digit is required so an all-hex word is not a sha. Confidence 0.85.
Review: Kev + claude-opus-5-5, 2026-09-26 — classify's any-box fallback skips
``` fences: #416's finished auto review quoted the PR body's unchecked merge
gate in a fence, was read as a progress list, and the watch reported 1/2 on a
head with two passes. Replayed against #416's thread: SUMMON + REVIEW.
Confidence 0.9.
Review: Kev + claude-opus-5-5, 2026-10-04 — `--passes` defaults to 1, not 2:
a second pass on every substantive PR doubled its push-wait-fold rounds, and dev
here slowed with it. Two is now the opt-in for risk surfaces (../../../CLAUDE.md).
`parse_args` split out of `main` so the test pins the default. Confidence 0.75 —
how often pass 2 caught what pass 1 missed is unmeasured.
Review: Kev + claude-opus-5-5, 2026-10-04 (2) — measured now (132 merged PRs;
see the root CLAUDE.md review). `--passes` is inferred: 2 for a risk surface
(paths, `migration_files()` read off the tree, RISK_PATCH over the diff;
renames judged by both names), else 1. Tests and prose are exempt. Going below
the inference needs `--why` (exit 5). Shaped by a challenger pass: the GRDB
migrations sit in *Store.swift, invisible to any name pattern. Confidence 0.8 —
path heuristics drift; the migration list can't, it is read fresh each run.
Review: Kev + claude-opus-5-5, 2026-10-08 — `--why` is owed only for a RISK diff landing below its
inference, as the root CLAUDE.md's trivial-head rule already said ("bare `--passes 0` otherwise"). The
code refused any downgrade, and printed `risk surface ()` (an empty list) on docs-only #513 and on #511's
test-only head. Confidence 0.9 — pinned in test_pr_watch.py.
Review: Kev + claude-opus-5.5, 2026-10-10 — a pass counted by author, shape and head alone, so one
that said "BLOCKING: …" still counted and land.sh merged; with hands-off landing nobody reads it
first. The gate now reads the review's closing VERDICT line (review_verdict): the owed pass(es) on
the head must APPROVE naming it, failing closed on missing / malformed / CHANGES_REQUESTED / another
sha. "Newest" is when a pass finished (updated_at: a summon's tracking comment is created at run
start, #547). Two owed passes must both approve — the risk-surface pair runs concurrently, and
newest-only would let run order decide whether a blocker lands. Confidence now 0.8 — the parser is
pinned on shapes read off #543/#547; whether the bots emit the line reliably is unmeasured.
Review: Kev + claude-opus-5.5, 2026-10-10 (2) — M1K3 is public, so a green, approved PR from an
outside contributor, a bot or a fork could have landed hands-off. Ready now also needs the author in
AUTO_LAND_AUTHORS (a constant: widening it is a reviewed change, not an env var an agent can set to
unblock itself) and the head repo equal to the base repo; snapshot reads author + headRepository,
and an unknown one refuses. Confidence now 0.85 — pinned in test_pr_watch.py, the gh wiring included.
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
    "macos/M1K3App/RememberPhotoButton.swift",
    "macos/M1K3App/PhosphorMaterial.swift",
    "macos/M1K3App/Phosphor.metal",
    "macos/M1K3App/PrivacyInfo.xcprivacy",
    "macos/M1K3App/Resources/Fonts/",
    "macos/project.yml",
    "macos/Package.swift",
    "macos/Package.resolved",
    ".github/workflows/ci.yml",
)


# Where a second pass earns its keep. The 2026-10-04 audit of #287–#480 found
# 33 real bugs a final pass caught that earlier passes missed; outside these
# surfaces every one but two came after a fold (which gets its own auto pass).
# Paths catch most of it; GRDB migrations live inside *Store.swift files, so
# those are caught by the tree (`migration_files`) and the patch (RISK_PATCH).
RISK_SURFACE_PATTERNS = tuple(re.compile(p) for p in (
    r"^macos/Sources/M1K3AgentTools/",                       # agent script execution
    r"^macos/(Sources|M1K3App|M1K3CLI)/.*MCP[^/]*\.swift$",  # MCP host files in the app
    r"^macos/Sources/M1K3MCP(Kit)?/",                         # the MCP server, whole
    r"^macos/Sources/M1K3CLICore/",                           # CLI token + call sequencing
    r"(AccessToken|TokenStore|TokenVault|Loopback)[^/]*\.swift$",
    r"PairedBrainStore\.swift$",                              # BrainLink pairing key
    r"Keychain[^/]*\.swift$",
    r"\.entitlements$",
    r"\.xcprivacy$",
    r"Info\.plist$",
    r"^macos/Package\.(swift|resolved)$",                    # dependencies
    r"^macos/Sources/M1K3Calls/.*Key[^/]*\.swift$",          # call-recording crypto
    r"Crypto[^/]*\.swift$",
    r"(PrivateCloud|Consent)[^/]*\.swift$",                  # what leaves the device
    r"[Mm]igrat[^/]*\.swift$",
    r"^\.github/",                                            # workflows, actions, the lot
    r"^macos/tools/asc/",                                     # App Store submission
    r"(^|/)Gemfile(\.lock)?$",
    r"\.xcconfig$",
    r"^macos/fastlane/",
    r"^macos/project\.yml$",
    r"^macos/ci_scripts/",
    r"^macos/tools/ci/",                                      # the landing gate itself
))
# Never a risk surface on their own: tests and prose. Prose that steers agents
# or reporters (CLAUDE.md, SECURITY.md, .claude/ prompts) is not exempt.
RISK_EXEMPT = re.compile(r"^macos/Tests/|/test_[^/]*\.py$|\.md$")
RISK_PROSE = re.compile(r"(^|/)(CLAUDE|SECURITY)\.md$|^\.claude/")
# The auto review pass's paths (claude-code-review-mac.yml); outside them a
# head gets no pass unless someone summons one.
AUTO_PASS_PATTERNS = tuple(re.compile(p) for p in (
    r"^macos/.*\.swift$", r"^macos/.*Package\.(swift|resolved)$", r"^macos/.*project\.yml$",
    r"^macos/tools/", r"^\.github/workflows/",
))
MIN_WHY = 10  # a reason, not a token
# A changed line that touches a migration, the keychain or an entitlement.
RISK_PATCH = re.compile(r"registerMigration|DatabaseMigrator|SecItem|kSecAttr|com\.apple\.security")


def migration_files(root: str | None = None) -> set[str]:
    """Every file in the tree that registers a GRDB migration, read fresh."""
    out = subprocess.run(["git", "grep", "-l", "-E", "registerMigration|DatabaseMigrator", "--", "macos/Sources"],
                         cwd=root or _repo_root(), capture_output=True, text=True, check=False)
    return set(out.stdout.split())


def _repo_root() -> str:
    here = __file__.rsplit("/", 1)[0] or "."
    return subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=here, check=False,
                          capture_output=True, text=True).stdout.strip() or "."


def changed_paths(files: list[dict]) -> list[str]:
    """The PR's files, renames judged by both names."""
    paths: list[str] = []
    for f in files:
        paths.append(f["filename"])
        if f.get("previous_filename"):
            paths.append(f["previous_filename"])
    return paths


def risk_surfaces(files: list[str], patches: dict[str, str | None] | None = None,
                  migration_files: set[str] | frozenset[str] = frozenset()) -> list[str]:
    """The changed files that buy a second review pass.

    Fails closed: a .swift file whose patch GitHub omitted (too large) counts,
    since its content can't be checked. RISK_PATCH also fires on removed and
    context lines; that's deliberate, a conservative read.
    """
    patches = patches or {}

    def risky(f: str) -> bool:
        if RISK_EXEMPT.search(f) and not RISK_PROSE.search(f):
            return False
        if RISK_PROSE.search(f) or any(p.search(f) for p in RISK_SURFACE_PATTERNS) or f in migration_files:
            return True
        if f in patches and patches[f] is None:
            return f.endswith(".swift")
        return bool(RISK_PATCH.search(patches.get(f) or ""))

    return [f for f in files if risky(f)]


def auto_pass_expected(files: list[str]) -> bool:
    """Whether the auto review fires on this diff; if not, one pass is a summon."""
    return any(p.search(f) for p in AUTO_PASS_PATTERNS for f in files)


def required_passes(explicit: int | None, files: list[str], **risk: object) -> int:
    """An explicit --passes wins; otherwise 2 for a risk surface, else 1."""
    if explicit is not None:
        return explicit
    return 2 if risk_surfaces(files, **risk) else 1  # type: ignore[arg-type]


def downgrade_refused(explicit: int | None, files: list[str], why: str | None, **risk: object) -> bool:
    """Landing a RISK diff on fewer passes than inferred needs a stated reason.

    A diff with no risk surface may go down to a bare `--passes 0` (the trivial-head rule); refusing it
    printed "risk surface ()" — an empty list — on docs-only PRs (#511, #513).
    """
    if not risk_surfaces(files, **risk):  # type: ignore[arg-type]
        return False
    reasoned = bool(why) and len(why.strip()) >= MIN_WHY
    return explicit is not None and explicit < required_passes(None, files, **risk) and not reasoned

BOT_LOGIN = "claude[bot]"
# Whose PRs land hands-off: the author must be here AND the head branch must live
# in this repo, not a fork. M1K3 is public, so an outside contributor's green,
# approved PR is merged by hand, never by land.sh; bots (dependabot) are not here
# either. A constant, not an env var: widening it is a reviewed change, not a flag
# an agent can set to unblock itself. Lowercase — logins compare without case.
AUTO_LAND_AUTHORS = frozenset({"kpmmmurphy"})
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
_HEAD_PAREN = re.compile(r"\bhead \(`?([0-9a-f]{7,40})`?\)")  # and "head (`95586c16`)" (#452, 2026-09-29)
# "Reviewing head f10c752c" — bare hex after "head", no delimiter (#334, 2026-09-14).
_HEAD_BARE = re.compile(r"\bhead ([0-9a-f]{7,40})\b")
_HEADER_LINE = re.compile(r"^#{2,4} ")
_SHA = re.compile(r"`([0-9a-f]{7,40})`")
# "### Reviewing f2dcbc56" — a bare sha in the title, no backticks, no "head" (#437, 2026-09-27).
# A digit is required: hex letters alone spell words ("defaced", "effaced").
_TITLE_BARE_SHA = re.compile(r"\b(?=[0-9a-f]*[0-9])([0-9a-f]{7,40})\b")
# The action's tracking-comment anchor. If the action ever renames "View job",
# the identity match silently falls back to the window heuristic and #409 comes
# back — re-pin from a live thread, as classify's wording list has needed
# (#334, #347, #404).
_RUN_LINK = re.compile(r"\[View job\]\([^)]*?/actions/runs/(\d+)")
# The closing line every review prompt asks for (claude-code-review*.yml, claude.yml):
# "VERDICT: APPROVE @ <sha>" or "VERDICT: CHANGES_REQUESTED @ <sha>". Markdown dressing
# (bold, backticks) is tolerated; anything else on the line makes it unparseable.
_VERDICT_LINE = re.compile(r"^[\s*_`]*VERDICT:")
_VERDICT = re.compile(r"^[\s*_`]*VERDICT:\s*(APPROVE|CHANGES_REQUESTED)\s*@\s*`?([0-9a-fA-F]{7,40})`?[\s*_`.]*$")


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
    return any(m and m.group(1) == " " for m in map(_CHECKBOX.match, _outside_fences(lines)))


def _outside_fences(lines: list[str]) -> list[str]:
    """The lines not inside a ``` fence. A finished review may QUOTE a checklist
    (#416: the PR body's own unchecked merge gate, fenced) — that is not the
    bot's progress list."""
    kept: list[str] = []
    fenced = False
    for line in lines:
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if not fenced:
            kept.append(line)
    return kept


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
    "second full pass on final head (3922a21d)") — or sits in the pass's own
    title — the FIRST markdown header line — backticked, or bare with a digit
    ("### Reviewing f2dcbc56", #437). A later "####" finding header quoting an older commit,
    and a sha in body prose, name nothing. An auto pass's comment may name the
    head too (#404, 2026-09-24) — verdict() counts that review once."""
    shas: list[str] = []
    title_read = False
    for line in body.splitlines():
        found = _HEAD.findall(line) + _HEAD_PAREN.findall(line) + _HEAD_BARE.findall(line)
        if not title_read and _HEADER_LINE.match(line):
            title_read = True
            found += _SHA.findall(line) + _TITLE_BARE_SHA.findall(line)
        for sha in found:
            if sha not in shas:
                shas.append(sha)
    return shas


def _names(head: str, shas: list[str]) -> bool:
    return any(head.startswith(sha) or sha.startswith(head) for sha in shas)


def summon_passes(head: str, comments: list[dict], head_seen_at: str | None = None) -> int:
    """Finished summon passes that reviewed THIS head: those that name it, plus —
    when the watch knows when the head arrived (`head_seen_at`, the creation time
    of its first CI run) — those that name no sha at all and started after it. A
    summon reviews whatever head is current when its run starts, and the action
    creates its tracking comment at that start, so the time settles what the
    wording didn't (#455's "### Review of #455 (docs-only)" read 0/1, 2026-09-30).
    A pass naming only another sha never counts, whenever it ran."""
    return sum(1 for c in comments if counts_as_summon_pass(head, c, head_seen_at))


def counts_as_summon_pass(head: str, comment: dict, head_seen_at: str | None) -> bool:
    """summon_passes' per-comment rule, shared with verdict so the auto pass's own
    comment is never credited twice. Timestamps are GitHub's ISO-8601 `Z` strings
    on both sides, so they compare as strings."""
    if comment.get("user", {}).get("login") != BOT_LOGIN:
        return False
    body = comment.get("body", "")
    if classify(body) is not Kind.SUMMON:
        return False
    shas = named_heads(body)
    if _names(head, shas):
        return True
    return not shas and bool(head_seen_at) and comment.get("created_at", "") >= head_seen_at


def review_verdict(body: str) -> tuple[str, str]:
    """What a pass concluded: ("APPROVE" | "CHANGES_REQUESTED", sha), or
    ("missing", "") / ("unparseable", ""). The LAST "VERDICT:" line outside ```
    fences is the verdict — the action appends " · branch `x`" after a summon's
    body and the bot often signs off below it, so it need not be the last line.
    A malformed closing verdict is not rescued by a well-formed earlier one, and
    prose ("**Verdict: looks good to land.**", #543) is no verdict at all."""
    lines = [ln for ln in _outside_fences(body.splitlines()) if _VERDICT_LINE.match(ln)]
    if not lines:
        return ("missing", "")
    mt = _VERDICT.match(lines[-1])
    if not mt:
        return ("unparseable", "")
    return (mt.group(1), mt.group(2).lower())


def verdict_refusal(head: str, comment: dict | None) -> str | None:
    """Why this pass does not approve THIS head, or None when it does."""
    outcome, sha = review_verdict((comment or {}).get("body", ""))
    if outcome in ("missing", "unparseable"):
        return f"verdict: {outcome} on {head[:8]}"
    if not _names(head, [sha]):
        return f"verdict: {outcome} names {sha[:8]}, not {head[:8]}"
    if outcome != "APPROVE":
        return f"verdict: {outcome} on {head[:8]}"
    return None


def _finished_at(comment: dict | None) -> str:
    """When a pass said its last word: a summon's tracking comment is created
    when its run starts and updated with the review when it ends."""
    c = comment or {}
    return c.get("updated_at") or c.get("created_at") or ""


def passes_on_head(head: str, comments: list[dict], auto_ok: bool, auto_comment: dict | None = None,
                   head_seen_at: str | None = None) -> list[dict | None]:
    """Every pass that counts for this head, oldest word first — the summons,
    plus the auto pass unless its comment is already one of them (#404, #457:
    one review is one pass). An auto pass whose comment is unknown (the
    two-argument auto_ok form) is None and sorts newest: it can't approve."""
    found: list[dict | None] = [c for c in comments if counts_as_summon_pass(head, c, head_seen_at)]
    if auto_ok and auto_comment is not None and not counts_as_summon_pass(head, auto_comment, head_seen_at):
        found.append(auto_comment)
    order = sorted(range(len(found)), key=lambda i: (_finished_at(found[i]), i))
    ordered = [found[i] for i in order]
    if auto_ok and auto_comment is None:
        ordered.append(None)
    return ordered


def review_refusals(head: str, on_head: list[dict | None], passes_needed: int) -> list[str]:
    """The passes owed must approve this head. That is the newest pass — the
    newest `passes_needed` of them when more are owed: two passes on a risk
    surface run concurrently (push, then summon at once), and a blocker from
    either must not land or not by which run finished first. An older verdict
    is overridden by enough newer ones. With nothing owed (--passes 0) and
    nothing posted on the head, there is no verdict to read."""
    owed = on_head[-passes_needed:] if passes_needed > 0 else on_head[-1:]
    refusals = [r for r in (verdict_refusal(head, c) for c in reversed(owed)) if r]
    return list(dict.fromkeys(refusals))


def origin_refusals(author: str | None, head_repo: str | None, base_repo: str | None) -> list[str]:
    """Why this PR may not land hands-off whatever its CI and reviews say. Fails
    closed: an unknown author or head repo (a deleted fork has none) refuses."""
    reasons: list[str] = []
    if not author:
        reasons.append("author: unknown")
    elif author.lower() not in AUTO_LAND_AUTHORS:
        reasons.append(f"author: {author} is not on the auto-land list")
    if not head_repo or not base_repo:
        reasons.append("head repo: unknown")
    elif head_repo.lower() != base_repo.lower():
        reasons.append(f"fork: head is {head_repo}, not {base_repo}")
    return reasons


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
    head_seen_at: str | None = None,
    author: str | None = None,
    head_repo: str | None = None,
    base_repo: str | None = None,
) -> Verdict:
    ci = ci_verdict(required_jobs(changed_files), jobs)
    # The auto pass's own comment can be summon-shaped ("Claude finished …", #404)
    # and so already counted as a summon — by name, or (#457) by time. One
    # review is one pass.
    on_head = passes_on_head(head, comments, auto_ok, auto_comment, head_seen_at)
    passes = len(on_head)
    review = review_refusals(head, on_head, passes_needed)
    origin = origin_refusals(author, head_repo, base_repo)
    reasons: list[str] = []
    if ci.state != "green":
        reasons.append(f"CI {ci.state} ({ci.detail})")
    if passes < passes_needed:
        reasons.append(f"passes {passes}/{passes_needed} on {head[:8]}")
    reasons += review + origin
    ready = not reasons
    bits = [f"head {head[:8]}", f"CI {ci.state}" + (f" ({ci.detail})" if ci.detail else "")]
    if ci.advisory:
        bits.append(f"advisory red: {ci.advisory}")
    bits.append(f"passes {passes}/{passes_needed}")
    if review:
        bits += review
    elif on_head:
        bits.append("verdict APPROVE")
    bits += origin
    summary = " · ".join(bits) + (" → READY" if ready else "")
    return Verdict(ready, ci, passes, passes_needed, summary, reasons)


# ---------------------------------------------------------------- gh wiring --


def _gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def _gh_json(*args: str):
    return json.loads(_gh(*args))


def snapshot(repo: str, pr: int) -> tuple[str, str, list[str], dict[str, str | None], list[dict], dict | None, int,
                                          str | None, dict[str, str], str | None, str | None]:
    view = _gh_json("pr", "view", str(pr), "--repo", repo, "--json", "state,headRefOid,author,headRepository")
    head = view["headRefOid"]
    # Who opened it and where its head lives: a deleted fork's headRepository is null.
    author = (view.get("author") or {}).get("login")
    head_repo = (view.get("headRepository") or {}).get("nameWithOwner")
    # REST + --paginate: `gh pr view --json files` caps at 100 files, and a
    # dropped mobile-shell path would silently demote the mobile job to advisory.
    raw = [f for page in _gh_json("api", "--paginate", "--slurp", f"repos/{repo}/pulls/{pr}/files") for f in page]
    files = changed_paths(raw)
    patches = {f["filename"]: f.get("patch") for f in raw}  # None = GitHub omitted it
    jobs: dict[str, str | None] = {}
    runs = _gh_json("run", "list", "--repo", repo, "--workflow", "ci.yml", "--limit", "40",
                    "--json", "headSha,databaseId,status,conclusion,createdAt")
    mine = [r for r in runs if r["headSha"] == head]
    # When the head arrived: its first CI run (ci.yml fires on every push, a
    # docs-only one included — the compilable-changes detector still runs). The
    # 40-run window can only make this LATER (fewer summons count): fails safe.
    head_seen_at = min((r["createdAt"] for r in mine), default=None)
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
    return (view["state"], head, files, jobs, comments, auto_pass_comment(head, review_runs, comments),
            inline_count, head_seen_at, patches, author, head_repo)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("pr", type=int)
    ap.add_argument("--passes", type=int, default=None,
                    help="review passes required on the head (default: 2 for a risk surface, else 1; 0 = trivial head)")
    ap.add_argument("--once", action="store_true", help="report once, no polling")
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--timeout", type=int, default=5400)
    ap.add_argument("--repo", default=None, help="owner/name (default: the current repo)")
    ap.add_argument("--why", default=None, help="the reason for landing a risk surface on fewer passes than inferred")
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    repo = args.repo or _gh_json("repo", "view", "--json", "nameWithOwner")["nameWithOwner"]

    deadline = time.monotonic() + args.timeout
    warned = False
    hinted = False
    migrations = migration_files()
    if not migrations:
        print("warning: found no GRDB migrations in this checkout (git grep failed?) — "
              "migration edits will only be caught by the patch", flush=True)
    while True:
        try:
            (state, head, files, jobs, comments, auto_comment, inline, head_seen_at, patches,
             author, head_repo) = snapshot(repo, args.pr)
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
        risk = {"patches": patches, "migration_files": migrations}
        risky = risk_surfaces(files, **risk)
        if downgrade_refused(args.passes, files, args.why, **risk):
            print(f"risk surface ({', '.join(risky[:3])}) needs 2 passes; --passes {args.passes} "
                  f"needs --why \"<reason, {MIN_WHY}+ chars>\"", flush=True)
            return 5
        needed = required_passes(args.passes, files, **risk)
        if needed and not auto_pass_expected(files) and not hinted:
            print("note: nothing in this diff triggers the auto pass — summon one (@claude on the PR)", flush=True)
            hinted = True
        if risky and needed < 2 and not warned:
            print(f"note: risk surface ({', '.join(risky[:3])}) landing on --passes {needed}: {args.why}", flush=True)
            warned = True
        v = verdict(head, files, jobs, comments, auto_comment is not None, needed,
                    auto_comment=auto_comment, head_seen_at=head_seen_at,
                    author=author, head_repo=head_repo, base_repo=repo)
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
