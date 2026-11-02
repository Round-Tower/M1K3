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

`--head search` (#713) scores the shipped search head instead (SearchRouterWeights.swift, read as
SearchRouter.probability does): `✓ local` marks a turn whose web read the head would veto, and an
untrained head abstains on every line. `--json` prints one record per prompt, for docs/evals.

    uv run tools/router/score_head.py --head search --json "tell me the history of Dublin" "what about Cork?"
    uv run tools/router/score_head.py --head gate --offers blind.json [--weights Old.swift]   # offer hit rates

Signed: Kev + claude-opus-5-5, 2026-10-10, Confidence 0.85 (the reading mirrors the Swift and is
pinned against it by hand-computed cases; embeddings come from the trainer's own embed.swift).
Prior: none (new file).
Review: Kev + claude-opus-5.5, 2026-10-26 — `--head search` and `--json` (#713): held-out lines are scored on
the SHIPPED search weights before any wiring or arm. Confidence 0.85.
Review: Kev + claude-opus-5.5, 2026-11-02 — `--head gate` reads ToolNeedRouterWeights.swift (or `--weights`, an
older copy) and `--offers` scores a blind follow-up set's offer texts (a port of ToolNeedRouter.offerText) per
expected class, so a gate retrain is scored before and after offline. Confidence 0.85 (matches the Swift p's on the
seven pinned offers).
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
WEIGHTS = HERE.parents[1] / "Sources" / "M1K3Chat" / "ToolGroupRouterWeights.swift"
SEARCH_WEIGHTS = HERE.parents[1] / "Sources" / "M1K3Chat" / "SearchRouterWeights.swift"
GATE_WEIGHTS = HERE.parents[1] / "Sources" / "M1K3Chat" / "ToolNeedRouterWeights.swift"
OFFER_TEXT_LIMIT = 300  # ToolNeedRouter.offerTextLimit
_QUOTES = set('"\u201c\u201d\u201e\u00ab\u00bb')
_NEWLINES = set("\n\r\v\f\x85\u2028\u2029")
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


@dataclass(frozen=True)
class Logistic:
    threshold: float
    bias: float
    weights: list[float]


def parse_logistic(swift: str) -> Logistic:
    """A one-layer logistic head (SearchRouterWeights): threshold, bias and the weight vector."""
    threshold = float(re.search(rf"static let threshold: Double = ({_NUMBER})", swift)[1])
    bias = float(re.search(rf"static let bias: Double = ({_NUMBER})", swift)[1])
    body = swift[swift.index("static let weights"):]
    body = body[body.index("= [") + 3:]
    return Logistic(threshold, bias, _numbers(body[: body.index("]")]))


def read_logistic(vector: list[float], head: Logistic) -> float | None:
    """SearchRouter.probability: P(the turn needs the web), or None (untrained, a shape mismatch, no direction)."""
    if not head.weights or len(vector) != len(head.weights):
        return None
    norm = math.sqrt(sum(x * x for x in vector))
    if not norm or not math.isfinite(norm):
        return None
    z = head.bias + sum(x / norm * w for x, w in zip(vector, head.weights))
    p = 1 / (1 + math.exp(-z))
    return p if math.isfinite(p) else None


def search_record(prompt: str, p: float | None, head: Logistic) -> dict:
    verdict = "abstain" if p is None else ("local" if p < head.threshold else "web")
    return {"prompt": prompt, "verdict": verdict, "p": p, "threshold": head.threshold}


def search_line(prompt: str, p: float | None, head: Logistic) -> str:
    if p is None:
        return f"   abstain (untrained or unscorable)  {prompt}"
    local = p < head.threshold
    return (f"{'✓' if local else ' '}  {'local' if local else 'web':<5} {p:.3f} {'<' if local else '≥'} "
            f"{head.threshold:.3f}  {prompt}")


def gate_verdict(p: float | None, head: Logistic) -> str:
    """ToolNeedRouter.verdict(probability:): tools at or above the threshold; unscorable fails open to tools."""
    return "tools" if p is None or p >= head.threshold else "chat"


def _segments(turn: str) -> list[str]:
    """StyleAskFence.segments: split at every line break, and after . ! ? that ends the text or meets whitespace."""
    out, current = [], ""
    for index, char in enumerate(turn):
        if char in _NEWLINES:
            out.append(current)
            current = ""
            continue
        current += char
        if char in ".!?" and (index + 1 == len(turn) or turn[index + 1].isspace()):
            out.append(current)
            current = ""
    out.append(current)
    return [x.strip(" \t") for x in out if x.strip(" \t")]


def offer_text(reply: str) -> str | None:
    """ToolNeedRouter.offerText for one assistant reply: its last two sentences with letters, quotes stripped,
    whitespace collapsed, the last OFFER_TEXT_LIMIT characters from a whole word. The Swift also cuts reasoning, a
    FOLLOWUPS trailer and a links-only sources tail first; the blind sets carry none of them."""
    sentences = [x for x in _segments(reply) if any(c.isalpha() for c in x)]
    joined = " ".join("".join(c for c in " ".join(sentences[-2:]) if c not in _QUOTES).split())
    if not joined:
        return None
    if len(joined) <= OFFER_TEXT_LIMIT:
        return joined
    start = len(joined) - OFFER_TEXT_LIMIT
    capped = joined[start:]
    if not joined[start - 1].isspace() and " " in capped:
        capped = capped[capped.index(" ") + 1:]
    return capped


def score_offers(rows: list[dict], head: Logistic, embed) -> dict:
    """Each blind row's offer through the gate, scored against the row's own expect ("search" and "tool" both mean
    the offer wants a tool): how many expect-chat offers read chat and expect-tool offers read tools."""
    offers = [(row, offer_text(row["assistant"])) for row in rows]
    offers = [(row, text) for row, text in offers if text]
    readings = [read_logistic(list(v), head) for v in embed([text for _, text in offers])]
    summary = {"threshold": head.threshold, "chat": {"right": 0, "total": 0}, "tool": {"right": 0, "total": 0}}
    for (row, _), p in zip(offers, readings):
        want = "chat" if row["expect"] == "chat" else "tool"
        summary[want]["total"] += 1
        summary[want]["right"] += gate_verdict(p, head) == ("chat" if want == "chat" else "tools")
    return summary


def main(argv: list[str]) -> int:
    import train_tool_router  # numpy + the trainer's embed.swift; only the CLI needs them

    ap = argparse.ArgumentParser(description="Score prompts with a shipped router head.")
    ap.add_argument("--head", choices=["group", "search", "gate"], default="group")
    ap.add_argument("--json", action="store_true", help="one JSON record per prompt (--head search), or the summary")
    ap.add_argument("--weights", type=Path, help="--head gate: score these weights instead of the shipped file")
    ap.add_argument("--offers", type=Path, help="--head gate: a blind follow-up set; score each reply's offer text")
    ap.add_argument("prompts", nargs="*")
    args = ap.parse_args(argv)
    if args.head == "gate":
        gate = parse_logistic((args.weights or GATE_WEIGHTS).read_text())
        if args.offers:
            summary = score_offers(json.loads(args.offers.read_text()), gate, train_tool_router.embed)
            if args.json:
                print(json.dumps(summary))
            else:
                for want, said in (("chat", "chat"), ("tool", "tools")):
                    right, total = summary[want]["right"], summary[want]["total"]
                    print(f"expect {want} -> {said}: {right}/{total} ({right / total:.0%})" if total else f"expect {want}: none")
            return 0
        prompts = args.prompts or [line.strip() for line in sys.stdin if line.strip()]
        for prompt, vector in zip(prompts, train_tool_router.embed(prompts)):
            p = read_logistic(list(vector), gate)
            print(f"{gate_verdict(p, gate):<5} {'none' if p is None else f'{p:.3f}'}  {prompt}")
        return 0
    prompts = args.prompts or [line.strip() for line in sys.stdin if line.strip()]
    if args.head == "search":
        search = parse_logistic(SEARCH_WEIGHTS.read_text())
        readings = [read_logistic(list(v), search) for v in train_tool_router.embed(prompts)]
        if args.json:
            print(json.dumps([search_record(q, p, search) for q, p in zip(prompts, readings)], indent=1))
        else:
            for q, p in zip(prompts, readings):
                print(search_line(q, p, search))
        return 0
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
