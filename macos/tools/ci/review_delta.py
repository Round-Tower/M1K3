#!/usr/bin/env python3
"""What changed since the bot last approved this PR, so a re-review can read only that.

The auto pass (claude-code-review-mac.yml) fires on every push, and the landing gate
needs a verdict on every head, so each push buys a review. Before this, each one was a
full re-review: #684 took 13 commits over 7 pushes and got 7 reviews of 1.2–2.4k chars,
all APPROVE, each re-checking the same untouched default path. The verdicts are the
gate's; the repetition is noise that buries the one finding that matters.

This finds the newest finished claude[bot] verdict on the PR. When it APPROVEs an
earlier head (full 40-char sha) that the current head builds on (GitHub's compare says
`ahead`), it writes that delta's diff to a file (eval artifacts named, not inlined) and prints
`mode=delta`; the review
then reads only the delta and still closes with a verdict naming this head. Anything
else — no earlier pass, a newer CHANGES_REQUESTED, a short sha, a force-push, an empty
delta, any API error — prints `mode=full` and the review runs as before. It never fails
the job: a missing delta costs a long review, not a missing one.

    python3 review_delta.py <PR> --head <sha> [--repo owner/name] [--out PATH] >> "$GITHUB_OUTPUT"

The verdict and placeholder rules are pr_watch.py's own (review_verdict, classify), so
what counts as an approval here is what the gate counts. Pinned in test_review_delta.py.

Signed: Kev + claude-opus-5-5, 2026-10-25, Confidence 0.7, Prior: none (new file).
Context: Gemini's "signal vs noise" steer; a summary bot would add a comment, this
removes the repetition instead.
Open: the delta prompt is unmeasured — the first few PRs say whether a delta review
misses what a full one would have caught (it still reads `gh pr diff` for context).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

from pr_watch import BOT_LOGIN, Kind, classify, review_verdict

# --------------------------------------------------------------------------- #
# Pure helpers (unit-tested)
# --------------------------------------------------------------------------- #


def _finished_at(c: dict) -> str:
    return c.get("updated_at") or c.get("created_at") or ""


def delta_base(head: str, comments: list[dict]) -> str | None:
    """The earlier head the bot's newest verdict approved, or None for a full review."""
    verdicts = []
    for c in comments:
        if (c.get("user") or {}).get("login") != BOT_LOGIN:
            continue
        body = c.get("body") or ""
        if classify(body) is Kind.PLACEHOLDER:
            continue
        outcome, sha = review_verdict(body)
        if outcome in ("APPROVE", "CHANGES_REQUESTED"):
            verdicts.append((_finished_at(c), outcome, sha))
    if not verdicts:
        return None
    _, outcome, sha = max(verdicts, key=lambda v: v[0])
    if outcome != "APPROVE" or len(sha) != 40 or sha == head.lower():
        return None
    return sha


# GitHub's compare lists at most 300 files; a full page may be truncated, so it is no delta.
COMPARE_FILE_CAP = 300
EVALS = "/docs/evals/"


def is_linear(compare: dict | None) -> bool:
    """The head builds on the base (no force-push), something changed, and the list is whole."""
    files = (compare or {}).get("files") or []
    return bool(compare) and compare.get("status") == "ahead" and 0 < len(files) < COMPARE_FILE_CAP


def delta_text(files: list[dict]) -> tuple[str, int, list[str]]:
    """(the delta as a diff, code/doc files in it, eval artifacts by name). Eval
    artifacts are data: #684's deltas were 0-158 lines of code beside 9-16k of eval
    JSON, so they are named with their counts, never inlined."""
    parts: list[str] = []
    evals: list[str] = []
    code = 0
    for f in files:
        name = f.get("filename", "")
        if EVALS in f"/{name}":
            evals.append(f"{name} (+{f.get('additions', 0)} \u2212{f.get('deletions', 0)})")
            continue
        code += 1
        patch = f.get("patch")
        if patch is None:
            parts.append(f"# {name}: no patch (binary or too large) \u2014 read it from the tree\n")
        else:
            parts.append(f"diff --git a/{name} b/{name}\n--- a/{name}\n+++ b/{name}\n{patch}\n")
    if evals:
        parts.append("\n# Eval artifacts (data, not reviewed line by line):\n"
                     + "".join(f"#   {e}\n" for e in evals))
    return "".join(parts), code, evals


def outputs(base: str | None, diff_path: str, files: int) -> str:
    if base is None:
        return "mode=full\n"
    return f"mode=delta\nbase={base}\ndiff={diff_path}\nfiles={files}\n"


# --------------------------------------------------------------------------- #
# I/O (verify-by-run)
# --------------------------------------------------------------------------- #


def _gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def _delta(pr: int, head: str, repo: str, out: str) -> str:
    comments = json.loads(_gh("api", "--paginate", "--slurp", f"repos/{repo}/issues/{pr}/comments"))
    comments = [c for page in comments for c in page]
    base = delta_base(head, comments)
    if base is None:
        return outputs(None, "", 0)
    compare = json.loads(_gh("api", f"repos/{repo}/compare/{base}...{head}"))
    if not is_linear(compare):
        return outputs(None, "", 0)
    text, code, _ = delta_text(compare["files"])
    with open(out, "w") as f:
        f.write(text)
    return outputs(base, out, code)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("pr", type=int)
    ap.add_argument("--head", required=True)
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    ap.add_argument("--out", default=".review-delta.diff")
    args = ap.parse_args(argv[1:])
    try:
        sys.stdout.write(_delta(args.pr, args.head, args.repo, args.out))
    except Exception as e:  # noqa: BLE001 — any failure means a full review, never a failed job
        print(f"review_delta: full review ({type(e).__name__}: {e})", file=sys.stderr)
        sys.stdout.write(outputs(None, "", 0))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
