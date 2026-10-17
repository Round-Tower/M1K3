#!/usr/bin/env python3
"""voice_rig_summary.py — one row per voice turn from a voice_rig.zsh app.log.

  python3 macos/tools/eval/voice_rig_summary.py <out>/app.log

A turn runs from its `voice endpoint:` line to its `voice turn:` summary. Between them the
responder names the route (`tool router:` verdict, `tool dispatch:` outcome), the brain logs
what it read past the persona seed (`ttft … stream …: prompt=Ntok prefill=Mms`, the LAST one
in the turn: the answer's generation), and the voice loop logs first audio. Anything worth a
second look rides as a note: a name repair, a seed that diverged or was refused.

Signed: Kev + claude-opus-5-5, 2026-10-16, Confidence 0.8 (pinned in test_voice_rig_summary.py
on lines from the first rig run). Prior: none (new file).
Review: same day — history / rest columns off the responder's `prompt anatomy:` line.
Review: Kev + claude-opus-5-5, 2026-10-16 (pre-push review fold) — a tools verdict with no dispatch line is the
agent loop: label it "agent", not "?" (the anatomy line is plain-route only, so its columns stay "—").
Review: Kev + claude-opus-5-5, 2026-10-17 — the history column shows traced earlier lines (`8t+4e`, #626).
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field

STREAM = re.compile(r"\[app\.m1k3:ttft\] (?:stream|generate) \[[^\]]+\]: prompt=(\d+)tok prefill=(\d+)ms")
FIRST_AUDIO = re.compile(r"voice turn: .*first audio (\d+)ms")
VERDICT = re.compile(r"tool router: (\w+) p=")
DISPATCH = re.compile(r"tool dispatch: (\S+)")
REPAIR = re.compile(r"name repair: .* \((\d\.\d+)\)")
ANATOMY = re.compile(r"prompt anatomy: \d+c · history (\d+)c in (\d+) turns · rest (\d+)c(?: · earlier (\d+))?")
SEED_TROUBLE = re.compile(r"persona seed .*(?:not a prefix|not an exact)|seed reuse refused")


@dataclass
class Turn:
    route: str = "?"
    prompt_tokens: int | None = None
    prefill_ms: int | None = None
    first_audio_ms: int | None = None
    history_chars: int | None = None
    history_turns: int | None = None
    rest_chars: int | None = None
    earlier_lines: int = 0
    notes: list[str] = field(default_factory=list)


def turns(lines: list[str]) -> list[Turn]:
    """Completed turns only: one whose `voice turn:` line never landed is dropped."""
    done: list[Turn] = []
    current: Turn | None = None
    verdict = None
    for line in lines:
        if "voice endpoint:" in line:
            current, verdict = Turn(), None
            continue
        if current is None:
            continue
        if m := VERDICT.search(line):
            verdict = m.group(1)
            current.route = f"plain ({verdict})" if verdict == "chat" else "agent"
        elif m := DISPATCH.search(line):
            tool = m.group(1)
            current.route = f"plain ({verdict} verdict)" if tool == "none" else tool.rstrip(",")
        elif m := STREAM.search(line):
            current.prompt_tokens, current.prefill_ms = int(m.group(1)), int(m.group(2))
        elif m := ANATOMY.search(line):
            current.history_chars, current.history_turns, current.rest_chars = map(int, m.groups()[:3])
            current.earlier_lines = int(m.group(4) or 0)
        elif m := REPAIR.search(line):
            current.notes.append(f"name repair {m.group(1)}")
        elif SEED_TROUBLE.search(line):
            current.notes.append("seed diverged")
        elif m := FIRST_AUDIO.search(line):
            current.first_audio_ms = int(m.group(1))
            done.append(current)
            current = None
    return done


def _s(ms: int | None) -> str:
    return "—" if ms is None else f"{ms / 1000:.1f} s"


def table(rows: list[Turn]) -> str:
    out = [f"{'#':>2}  {'route':<22} {'prompt':>7} {'history':>12} {'rest':>6} {'prefill':>8} {'1st audio':>9}  notes",
           "-" * 86]
    for i, r in enumerate(rows, 1):
        prompt = "—" if r.prompt_tokens is None else f"{r.prompt_tokens}"
        hist = "—" if r.history_chars is None else f"{r.history_chars}c/{r.history_turns}t"
        hist += f"+{r.earlier_lines}e" if r.earlier_lines else ""
        rest = "—" if r.rest_chars is None else f"{r.rest_chars}c"
        out.append(f"{i:>2}  {r.route:<22} {prompt:>7} {hist:>12} {rest:>6} {_s(r.prefill_ms):>8} {_s(r.first_audio_ms):>9}  "
                   + ", ".join(r.notes))
    return "\n".join(out)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    with open(argv[1], errors="replace") as f:
        print(table(turns(f.read().splitlines())))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
