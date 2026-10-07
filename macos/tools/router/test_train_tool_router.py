import numpy as np

import train_tool_router as t


def test_labels_mark_every_non_none_group_as_tool():
    items = [{"group": "web"}, {"group": "none"}, {"group": "device"}]
    assert t.labels(items).tolist() == [True, False, True]


def test_recall_threshold_keeps_the_requested_share_of_tool_asks():
    probabilities = np.linspace(0.01, 1.0, 100)
    is_tool = np.ones(100, dtype=bool)
    threshold = t.recall_threshold(probabilities, is_tool, recall=0.97)
    assert (probabilities >= threshold).sum() >= 97


def test_normalise_gives_unit_rows():
    rows = t.normalise(np.array([[3.0, 4.0], [0.0, 2.0]]))
    assert np.allclose(np.linalg.norm(rows, axis=1), 1.0)


def test_render_swift_emits_every_weight_and_the_constants():
    source = t.render_swift(np.arange(10, dtype=float), bias=-0.5, threshold=0.29, count=3, cv_note="n")
    assert "static let threshold: Double = 0.29" in source
    assert "static let bias: Double = -0.5" in source
    assert source.count(",") >= 10
    assert "GENERATED" in source


def test_group_labels_follow_groups_order_and_reject_unknown_groups():
    items = [{"group": "none"}, {"group": "web"}, {"group": "script"}]
    assert t.group_labels(items).tolist() == [0, t.GROUPS.index("web"), t.GROUPS.index("script")]
    try:
        t.group_labels([{"group": "weather"}])
    except ValueError as error:
        assert "weather" in str(error)
    else:
        raise AssertionError("an unknown group must fail, not become a new class")


def test_the_training_data_uses_only_known_groups():
    import json

    items = json.loads(t.DATA.read_text())["items"]
    assert {item["group"] for item in items} == set(t.GROUPS)


def test_dispatch_floor_is_the_lowest_one_that_reaches_the_precision():
    # Three tool picks at 0.9 (right), 0.6 (wrong), 0.5 (right): all three is 2/3,
    # down to 0.9 alone is 1/1, so the floor sits at 0.9.
    probabilities = np.array([[0.05, 0.9, 0.05], [0.1, 0.6, 0.3], [0.2, 0.5, 0.3]])
    truth = np.array([1, 2, 1])
    assert t.dispatch_floor(probabilities, truth, precision=0.95) == 0.9
    assert t.dispatch_floor(probabilities, truth, precision=0.6) == 0.5


def test_dispatch_floor_ignores_none_picks_and_never_speaks_when_unreachable():
    # A confident none never dispatches, so it can't lower the floor or count as right.
    probabilities = np.array([[0.99, 0.01], [0.3, 0.7]])
    assert t.dispatch_floor(probabilities, np.array([0, 0]), precision=0.95) > 1.0
    assert t.dispatch_floor(probabilities, np.array([0, 1]), precision=0.95) == 0.7


def test_render_group_swift_emits_one_row_per_group():
    weights = np.arange(2 * 10, dtype=float).reshape(2, 10)
    source = t.render_group_swift(["none", "web"], weights, np.array([0.5, -0.5]), 0.8, 3, "n")
    assert 'static let groups: [String] = ["none", "web"]' in source
    assert "static let floor: Double = 0.8" in source
    assert "static let biases: [Double] = [0.5, -0.5]" in source
    assert source.count("[\n            ") == 2
    assert "19" in source and "GENERATED" in source


def test_render_group_swift_untrained_has_no_groups():
    source = t.render_group_swift([], np.zeros((0, 0)), np.zeros(0), 1.0, 0, "Untrained.")
    assert "static let groups: [String] = []" in source
    assert "static let weights: [[Double]] = [\n    ]" in source
    assert "UNTRAINED" in source
