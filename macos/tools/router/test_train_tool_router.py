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
