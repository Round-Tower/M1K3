#!/usr/bin/env python3
"""What changed since the bot last approved this PR, so a re-review can read only that.

The auto pass (claude-code-review-mac.yml) fires on every push, and the landing gate
needs a verdict on every head, so each push buys a review. Before this, each one was a
full re-review: #684 took 13 commits over 7 pushes and got 7 reviews of 1.2–2.4k chars,
all APPROVE, each re-checking the same untouched default path. The verdicts are the
gate's; the repetition is noise that buries the one finding that matters.

A delta review is only safe when the base was really approved and the delta really is
everything since, so every doubt means `mode=full` (the review runs as before):

* the NEWEST finished claude[bot] comment (by when it finished, a tie counting as doubt)
  must itself be a well-formed APPROVE naming a full 40-char sha other than this head —
  a later blocker, an unparseable verdict, prose with no verdict line or a short sha
  all mean full;
* no pass may have blocked that base (an auto CHANGES_REQUESTED beside a summon APPROVE);
* GitHub's compare must say `ahead`, with the base as the merge base, no merge commit
  in between, and fewer than 300 files (a full page may be truncated);
* every changed text file outside eval data must carry a patch (GitHub drops it for a
  huge file); eval data — `.json`/`.jsonl`/`.txt`/`.csv` under macos/docs/evals/ — is
  named with its counts, never inlined (#684's deltas were 0–158 lines of code beside
  9–16k of eval JSON);
* any API error or timeout.

Otherwise it writes the delta to a file and prints `mode=delta`; the review reads only
that and still closes with a verdict naming this head. It always exits 0. The workflow
runs master's copy of this file, never the PR's, so a PR can't narrow its own review.

    python3 review_delta.py <PR> --head <sha> [--repo owner/name] [--out PATH] >> "$GITHUB_OUTPUT"

The verdict and placeholder rules are pr_watch.py's own (review_verdict, classify), so
what counts as an approval here is what the gate counts. Pinned in test_review_delta.py.

Signed: Kev + claude-opus-5-5, 2026-10-25, Confidence 0.7, Prior: none (new file).
Context: Gemini's "signal vs noise" steer; a summary bot would add a comment, this
removes the repetition instead. The fail-closed rules are from the pre-push review.
Open: the delta prompt is unmeasured — the first few PRs say whether a delta review
misses what a full one would have caught (it may still read `gh pr diff` for context).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

from pr_watch import BOT_LOGIN, Kind, classify, review_verdict

# GitHub's compare lists at most 300 files; a full page may be truncated, so it is no delta.
COMPARE_FILE_CAP = 300
EVAL_DIR = "macos/docs/evals/"
EVAL_EXT = {"json", "jsonl", "txt", "csv"}
BINARY_EXT = {"png", "jpg", "jpeg", "gif", "heic", "ico", "icns", "pdf", "mp4", "mov", "m4a",
              "mp3", "wav", "caf", "zip", "onnx", "safetensors", "bin", "ttf", "otf", "car"}
GH_TIMEOUT_S = 60

# --------------------------------------------------------------------------- #
# Pure helpers (unit-tested)
# --------------------------------------------------------------------------- #


def _finished_at(c: dict) -> str:
    return c.get("updated_at") or c.get("created_at") or ""


def _ext(name: str) -> str:
    base = name.rsplit("/", 1)[-1]
    return base.rsplit(".", 1)[-1].lower() if "." in base else ""


def delta_base(head: str, comments: list[dict]) -> str | None:
    """The earlier head the bot's newest word approved, or None for a full review."""
    words = []  # (finished at, outcome, sha) for every finished bot comment
    for c in comments:
        if (c.get("user") or {}).get("login") != BOT_LOGIN:
            continue
        body = c.get("body") or ""
        if classify(body) is Kind.PLACEHOLDER:
            continue
        outcome, sha = review_verdict(body)
        words.append((_finished_at(c), outcome, sha))
    if not words:
        return None
    last = max(w[0] for w in words)
    newest = [w for w in words if w[0] == last]
    if len(newest) != 1:
        return None  # a tie at the newest moment is doubt
    _, outcome, sha = newest[0]
    if outcome != "APPROVE" or len(sha) != 40 or sha == head.lower():
        return None
    if any(o != "APPROVE" and s and sha.startswith(s) for _, o, s in words):
        return None  # some pass blocked this base
    return sha


def is_linear(compare: dict | None, base: str) -> bool:
    """The head builds straight on the base: ahead, no merge in between, the list whole."""
    if not compare or compare.get("status") != "ahead":
        return False
    if (compare.get("merge_base_commit") or {}).get("sha") != base:
        return False
    if any(len(c.get("parents") or []) > 1 for c in compare.get("commits") or []):
        return False  # a master merge would pull master's changes into "what changed"
    return 0 < len(compare.get("files") or []) < COMPARE_FILE_CAP


def is_eval_data(name: str) -> bool:
    return name.startswith(EVAL_DIR) and _ext(name) in EVAL_EXT


def delta_text(files: list[dict]) -> tuple[str, int, list[str]] | None:
    """(the delta as a diff, code/doc files in it, eval data by name), or None when a
    text file's patch is missing (GitHub drops it for a huge file) — then a delta review
    would approve what it never saw."""
    parts: list[str] = []
    evals: list[str] = []
    code = 0
    for f in files:
        name = f.get("filename", "")
        if is_eval_data(name):
            evals.append(f"{name} (+{f.get('additions', 0)} −{f.get('deletions', 0)})")
            continue
        code += 1
        patch = f.get("patch")
        if patch is not None:
            parts.append(f"diff --git a/{name} b/{name}\n--- a/{name}\n+++ b/{name}\n{patch}\n")
        elif _ext(name) in BINARY_EXT:
            parts.append(f"# {name}: binary, {f.get('status', 'changed')}\n")
        elif f.get("status") == "renamed" and not f.get("changes"):
            parts.append(f"# {name}: renamed from {f.get('previous_filename', '?')}, no content change\n")
        else:
            return None
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
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True,
                          timeout=GH_TIMEOUT_S).stdout


def _delta(pr: int, head: str, repo: str, out: str) -> str:
    pages = json.loads(_gh("api", "--paginate", "--slurp", f"repos/{repo}/issues/{pr}/comments"))
    base = delta_base(head, [c for page in pages for c in page])
    if base is None:
        return outputs(None, "", 0)
    compare = json.loads(_gh("api", f"repos/{repo}/compare/{base}...{head}"))
    if not is_linear(compare, base):
        return outputs(None, "", 0)
    delta = delta_text(compare["files"])
    if delta is None:
        return outputs(None, "", 0)
    text, code, _ = delta
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
