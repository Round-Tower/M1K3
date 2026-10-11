"""Pins score_head.py: it reads the shipped group-head weights out of ToolGroupRouterWeights.swift
and scores a sentence vector exactly as ToolGroupRouter.read does (L2-normalise, logits, softmax,
top group). The 2026-10-09 router arm's fixtures never reached the head's floor, and nobody could
tell without re-implementing the head by hand; this is that check, kept.

Signed: Kev + claude-opus-5-5, 2026-10-10, Confidence 0.9. Prior: none (new file).
"""
import math

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
