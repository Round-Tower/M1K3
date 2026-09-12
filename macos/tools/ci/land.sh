#!/usr/bin/env bash
# Land a PR the whole way: gate on pr_watch, squash-merge BY HEAD SHA, verify
# the merge landed, delete the remote branch, and say how to drop the worktree.
#
#   tools/ci/land.sh <PR> [pr_watch flags: --passes N ...]
#
# Why a script: the sequence was retyped per PR (and the merge call is
# sometimes classifier-blocked for an agent — then Kev runs THIS, not a paste).
# Verification is independent of exit codes: state+mergedAt are read back.
#
# Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85 (each step is the
# one used by hand on #287–#293; the worktree hint is printed, never executed,
# because the script usually runs from inside that worktree). Prior: Unknown
set -euo pipefail

pr="${1:?usage: land.sh <PR> [pr_watch flags]}"; shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

echo "== gate: pr_watch --once"
python3 "$here/pr_watch.py" "$pr" --repo "$repo" --once "$@"

head="$(gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid)"
branch="$(gh pr view "$pr" --repo "$repo" --json headRefName -q .headRefName)"
title="$(gh pr view "$pr" --repo "$repo" --json title -q .title)"

echo "== merge: squash #$pr at $head"
gh api -X PUT "repos/$repo/pulls/$pr/merge" \
  -f merge_method=squash -f sha="$head" -f commit_title="$title (#$pr)" >/dev/null

state="$(gh pr view "$pr" --repo "$repo" --json state,mergedAt,mergeCommit \
  -q '"\(.state) \(.mergedAt) \(.mergeCommit.oid)"')"
case "$state" in
  MERGED*) echo "== landed: $state" ;;
  *) echo "!! merge did not land: $state" >&2; exit 1 ;;
esac

echo "== delete remote branch $branch"
gh api -X DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null || echo "   (already gone)"

top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
main="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"
if [[ -n "$top" && "$top" != "$main" ]]; then
  echo "== this is a linked worktree; from the main tree run:"
  echo "   rm -rf '$top' && git -C '$main' worktree prune && git -C '$main' branch -D '$branch'"
fi
echo "== next: git -C '$main' pull --ff-only origin master · check the Xcode Cloud run list in ~2 min"
