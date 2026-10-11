# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=1.26"]
# ///
"""Score prompts with the SHIPPED group head: does a turn reach its floor, and in which family?

    uv run tools/router/score_head.py "What time is it?" "Search my notes for the seal"   # from macos/
    printf '%s\\n' "prompt one" "prompt two" | uv run tools/router/score_head.py

It reads ToolGroupRouterWeights.swift (the committed weights, not a retrain) and scores each
prompt's NLEmbedding vector exactly as ToolGroupRouter.read does: L2-normalise, logits, softmax,
top group. Only the device / knowledge / activity families can dispatch, and device and the
read-only families add word rules on top (ToolGroupRouter.pick), so "clears" here means the head
would SPEAK, not which tool it names. The 2026-10-09 router arm's fixtures never cleared the floor
and nobody could see it; new head fixtures are checked with this first.

Signed: Kev + claude-opus-5-5, 2026-10-10, Confidence 0.85 (the reading mirrors the Swift and is
pinned against it by hand-computed cases; embeddings come from the trainer's own embed.swift).
Prior: none (new file).
"""
from __future__ import annotations

import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
WEIGHTS = HERE.parents[1] / "Sources" / "M1K3Chat" / "ToolGroupRouterWeights.swift"
DISPATCHING = {"device", "knowledge", "activity"}  # web, script and none never dispatch (ToolGroupRouter.pick)
_NUMBER = r"-?\d+(?:\.\d+)?(?:[eE]-?\d+)?"


@dataclass(frozen=True)
class Head:
    groups: list[str]
    floor: float
    biases: list[float]
    weights: list[list[float]]


def _numbers(text: str) -> list[float]:
    return [float(x) for x in re.findall(_NUMBER, text)]


def parse_weights(swift: str) -> Head:
    groups = re.findall(r'"([^"]+)"', re.search(r"static let groups: \[String\] = \[(.*?)\]", swift, re.DOTALL)[1])
    floor = float(re.search(rf"static let floor: Double = ({_NUMBER})", swift)[1])
    biases = _numbers(re.search(r"static let biases: \[Double\] = \[(.*?)\]", swift, re.DOTALL)[1])
    body = swift[swift.index("static let weights"):]
    body = body[body.index("= [") + 3:]
    rows = [_numbers(row) for row in re.findall(r"\[([^\[\]]*)\]", body)]
    return Head(groups, floor, biases, rows[: len(groups)])


def read(vector: list[float], head: Head) -> tuple[str, float] | None:
    """ToolGroupRouter.read: the top group and its softmax probability, or None (an abstention)."""
    if not head.groups or any(len(row) != len(vector) for row in head.weights):
        return None
    norm = math.sqrt(sum(x * x for x in vector))
    if not norm or not math.isfinite(norm):
        return None
    logits = [bias + sum(x / norm * w for x, w in zip(vector, row)) for row, bias in zip(head.weights, head.biases)]
    top = max(logits)
    index = logits.index(top)
    return head.groups[index], 1 / sum(math.exp(x - top) for x in logits)


def main(argv: list[str]) -> int:
    import train_tool_router  # numpy + the trainer's embed.swift; only the CLI needs them

    prompts = argv or [line.strip() for line in sys.stdin if line.strip()]
    head = parse_weights(WEIGHTS.read_text())
    for prompt, vector in zip(prompts, train_tool_router.embed(prompts)):
        reading = read(list(vector), head)
        if reading is None:
            print(f"   abstain (unscorable)        {prompt}")
            continue
        group, probability = reading
        speaks = group in DISPATCHING and probability >= head.floor
        print(f"{'✓' if speaks else ' '}  {group:<9} {probability:.3f} {'≥' if probability >= head.floor else '<'} "
              f"{head.floor:.3f}  {prompt}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
