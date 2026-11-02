"""Pins score_head.py: it reads the shipped group-head weights out of ToolGroupRouterWeights.swift
and scores a sentence vector exactly as ToolGroupRouter.read does (L2-normalise, logits, softmax,
top group). The 2026-10-09 router arm's fixtures never reached the head's floor, and nobody could
tell without re-implementing the head by hand; this is that check, kept.

Signed: Kev + claude-opus-5-5, 2026-10-10, Confidence 0.9. Prior: none (new file).
Review: Kev + claude-opus-5.5, 2026-10-26 — `--head search` (#713): the logistic parse and reading mirror
SearchRouter.probability (untrained or mismatched abstains), and the CLI scores held-out lines as JSON.
Confidence 0.9.
Review: Kev + claude-opus-5.5, 2026-11-02 — `--head gate --offers`: the offerText port, the fail-open verdict, and a
blind set scored per expected class. Confidence 0.85.
"""
import json
import math

import numpy as np
import score_head as m

SWIFT = """
enum ToolGroupRouterWeights {
    static let groups: [String] = ["none", "device", "knowledge"]
    static let floor: Double = 0.75
    static let biases: [Double] = [0.5, -0.25, 1e-3]
    static let weights: [[Double]] = [
        [
            1.0, 0.0,
        ],
        [
            0.0, 2.5,
        ],
        [
            -1.0, -1.0,
        ],
    ]
}
"""


def test_reads_groups_floor_biases_and_weights_from_the_swift():
    head = m.parse_weights(SWIFT)
    assert head.groups == ["none", "device", "knowledge"]
    assert head.floor == 0.75
    assert head.biases == [0.5, -0.25, 0.001]
    assert head.weights == [[1.0, 0.0], [0.0, 2.5], [-1.0, -1.0]]


def test_scores_like_the_swift_reading_whatever_the_vector_scale():
    head = m.parse_weights(SWIFT)
    group, probability = m.read([0.0, 10.0], head)  # normalised to [0, 1]
    logits = [0.5, -0.25 + 2.5, 0.001 - 1.0]
    expected = 1 / sum(math.exp(x - max(logits)) for x in logits)
    assert group == "device"
    assert math.isclose(probability, expected)
    assert m.read([0.0, 1.0], head) == (group, probability)


def test_a_zero_vector_or_a_shape_mismatch_abstains():
    head = m.parse_weights(SWIFT)
    assert m.read([0.0, 0.0], head) is None
    assert m.read([1.0, 2.0, 3.0], head) is None


def test_the_shipped_weights_parse_into_a_consistent_head():
    head = m.parse_weights(m.WEIGHTS.read_text())
    assert len(head.weights) == len(head.groups) == len(head.biases)
    assert len({len(row) for row in head.weights}) == 1
    assert 0 < head.floor < 1


LOGISTIC = """
enum SearchRouterWeights {
    static let threshold: Double = 0.4
    static let bias: Double = -0.5
    static let weights: [Double] = [
        2.0, -1e-1,
    ]
}
"""


def test_reads_a_logistic_head_from_the_swift():
    head = m.parse_logistic(LOGISTIC)
    assert head == m.Logistic(threshold=0.4, bias=-0.5, weights=[2.0, -0.1])


def test_the_logistic_reading_is_search_router_s_whatever_the_vector_scale():
    head = m.parse_logistic(LOGISTIC)
    p = m.read_logistic([10.0, 0.0], head)  # normalised to [1, 0]
    assert math.isclose(p, 1 / (1 + math.exp(-(2.0 - 0.5))))
    assert m.read_logistic([1.0, 0.0], head) == p


def test_an_untrained_mismatched_or_zero_input_abstains():
    untrained = m.parse_logistic(LOGISTIC.replace("2.0, -1e-1,", ""))
    assert untrained.weights == []
    assert m.read_logistic([1.0, 0.0], untrained) is None
    head = m.parse_logistic(LOGISTIC)
    assert m.read_logistic([1.0, 0.0, 0.0], head) is None
    assert m.read_logistic([0.0, 0.0], head) is None


def test_a_search_reading_is_local_below_the_threshold_and_web_at_or_above():
    head = m.Logistic(threshold=0.4, bias=0.0, weights=[1.0])
    assert m.search_record("q", 0.39, head) == {"prompt": "q", "verdict": "local", "p": 0.39, "threshold": 0.4}
    assert m.search_record("q", 0.4, head)["verdict"] == "web"
    assert m.search_record("q", None, head)["verdict"] == "abstain"
    assert m.search_line("q", 0.39, head).startswith("✓  local")
    assert m.search_line("q", None, head).strip().startswith("abstain")


def test_the_shipped_search_weights_parse_into_the_stub_or_a_trained_head():
    head = m.parse_logistic(m.SEARCH_WEIGHTS.read_text())
    if head.weights:
        assert len(head.weights) == 512
        assert 0 < head.threshold < 1
    else:
        assert m.read_logistic([1.0] * 512, head) is None


def test_main_scores_search_lines_as_json(tmp_path, monkeypatch, capsys):
    import train_tool_router

    weights = tmp_path / "SearchRouterWeights.swift"
    weights.write_text(LOGISTIC)
    monkeypatch.setattr(m, "SEARCH_WEIGHTS", weights)
    monkeypatch.setattr(train_tool_router, "embed", lambda prompts: np.array([[1.0, 0.0], [0.0, 1.0]][: len(prompts)]))
    assert m.main(["--head", "search", "--json", "who won today?", "history of Rome"]) == 0
    records = json.loads(capsys.readouterr().out)
    assert [r["verdict"] for r in records] == ["web", "local"]
    assert records[1]["prompt"] == "history of Rome"


GATE = """
enum ToolNeedRouterWeights {
    static let threshold: Double = 0.3
    static let bias: Double = 0.0
    static let weights: [Double] = [
        3.0, -3.0,
    ]
}
"""


def test_the_offer_text_is_the_reply_s_last_two_sentences_like_tool_need_router():
    assert m.offer_text('Octopuses have three hearts. Odd, right? Want a "short" story about one?') == (
        "Odd, right? Want a short story about one?"
    )
    assert m.offer_text("Version 3.5 is out.\n\nWant me to check it?") == "Version 3.5 is out. Want me to check it?"
    assert m.offer_text("👍 …") is None
    capped = m.offer_text("word " * 100 + "Want a haiku?")
    assert len(capped) <= m.OFFER_TEXT_LIMIT
    assert capped.startswith("word") and capped.endswith("Want a haiku?")


def test_a_gate_reading_keeps_the_tools_at_or_above_the_threshold_and_fails_open():
    head = m.Logistic(threshold=0.3, bias=0.0, weights=[1.0])
    assert m.gate_verdict(0.3, head) == "tools"
    assert m.gate_verdict(0.29, head) == "chat"
    assert m.gate_verdict(None, head) == "tools"


def test_main_scores_a_blind_set_s_offers_per_expected_class(tmp_path, monkeypatch, capsys):
    import train_tool_router

    weights = tmp_path / "Gate.swift"
    weights.write_text(GATE)
    rows = [
        {"assistant": "Fun fact. Want a story?", "user": "yes", "expect": "chat"},
        {"assistant": "Want me to look it up?", "user": "sure", "expect": "search"},
        {"assistant": "Shall I set a timer?", "user": "go on", "expect": "tool"},
    ]
    blind = tmp_path / "blind.json"
    blind.write_text(json.dumps(rows))
    vectors = {"Fun fact. Want a story?": [0.0, 1.0], "Want me to look it up?": [1.0, 0.0], "Shall I set a timer?": [0.0, 1.0]}
    monkeypatch.setattr(train_tool_router, "embed", lambda prompts: np.array([vectors[p] for p in prompts]))
    assert m.main(["--head", "gate", "--weights", str(weights), "--offers", str(blind), "--json"]) == 0
    summary = json.loads(capsys.readouterr().out)
    assert summary["chat"] == {"right": 1, "total": 1}
    assert summary["tool"] == {"right": 1, "total": 2}
    assert summary["threshold"] == 0.3
