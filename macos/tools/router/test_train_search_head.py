"""Pins train_search_head.py: the search head's labels (a teacher must confirm a candidate unless a
hand check overrides it), the hold-outs (every chateval fixture, the voice-rig lines and the #680
lines stay out of training, near-copies too: #631), and the Swift it renders (the shape SearchRouter
reads, every line inside swiftlint's 120 columns). CI runs this with numpy only.

Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.85. Prior: none (new file).
"""
import json

import numpy as np
import train_search_head as t


def test_a_hand_check_wins_and_a_confident_agreeing_teacher_confirms():
    assert t.label({"search": True, "hand": False}) is False
    assert t.label({"search": True, "teacher": {"model": "m", "p": 0.93}}) is True
    assert t.label({"search": False, "teacher": {"model": "m", "p": 0.04}}) is False


def test_an_unsure_or_disagreeing_teacher_or_none_leaves_the_item_unconfirmed():
    assert t.label({"search": True}) is None
    assert t.label({"search": True, "teacher": None}) is None
    assert t.label({"search": True, "teacher": {"model": "m", "p": 0.6}}) is None
    assert t.label({"search": True, "teacher": {"model": "m", "p": 0.05}}) is None
    assert t.label({"search": False, "teacher": {"model": "m", "p": 0.97}}) is None


def test_training_labels_keep_confirmed_items_or_every_candidate_on_request():
    items = [
        {"prompt": "a", "search": True, "teacher": {"model": "m", "p": 0.9}},
        {"prompt": "b", "search": False},
        {"prompt": "c", "search": False, "hand": False},
    ]
    kept, y = t.training_labels(items)
    assert [item["prompt"] for item in kept] == ["a", "c"]
    assert y.tolist() == [True, False]
    kept, y = t.training_labels(items, candidates=True)
    assert [item["prompt"] for item in kept] == ["a", "b", "c"]
    assert y.tolist() == [True, False, False]


def test_near_copies_fold_case_and_punctuation_and_catch_a_swapped_word():
    assert t.near_copy("Tell me the history of Dublin.", "tell me the history of dublin")
    assert t.near_copy("What time is it?", "What time is it in Tokyo?")  # a short line: a looser bar
    assert not t.near_copy("What caused the fall of the Roman Republic?", "tell me the history of Dublin")
    assert not t.near_copy("", "what about Cork?")


def test_fixture_prompts_are_read_from_the_swift_including_joined_literals():
    swift = '''
        .init(id: "a", kind: .toolUse, prompt: "What's the newest Claude model?", expectation: .init())
        .init(
            id: "b", kind: .toolUse,
            prompt: "Find my note about the Cork trip, then search the web for the train times "
                + "from Dublin to Cork.",
            expectation: .init()
        )
    '''
    assert t.parse_fixture_prompts(swift) == [
        "What's the newest Claude model?",
        "Find my note about the Cork trip, then search the web for the train times from Dublin to Cork.",
    ]


def test_the_committed_fixtures_parse_and_include_the_issue_680_fixtures():
    prompts = t.fixture_prompts()
    assert len(prompts) > 100
    assert "Tell me the history of Dublin." in prompts
    assert "Who won the All-Ireland hurling final this year?" in prompts


def test_the_rig_and_issue_680_lines_are_held_out():
    lines = t.held_out_lines()
    assert "tell me the history of Dublin" in lines and "what about Cork?" in lines
    assert "What time is it?" in lines and "Why that one?" in lines
    assert not [line for line in lines if line.startswith("#")]


def test_no_training_prompt_is_a_held_out_line_or_a_near_copy_of_one():
    items = json.loads(t.DATA.read_text())["items"]
    held_out = t.held_out_lines() + t.fixture_prompts()
    assert t.held_out_violations([item["prompt"] for item in items], held_out) == []


def test_the_data_is_labelled_sourced_and_unique():
    data = json.loads(t.DATA.read_text())
    provenance = data["provenance"].lower()
    assert "teacher" in provenance and "held out" in provenance and "#680" in provenance
    items = data["items"]
    assert len(items) >= 400
    assert all(isinstance(item["search"], bool) for item in items)
    assert {item["source"] for item in items} <= {"router-data", "generated"}
    assert sum(item["search"] for item in items) >= 100
    folded = [t.fold(item["prompt"]) for item in items]
    assert len(set(folded)) == len(folded)


def test_render_swift_emits_the_shape_search_router_reads_within_120_columns():
    source = t.render_swift(np.arange(512, dtype=float) / 1e3, bias=-0.5, threshold=0.29, count=3, cv_note="n")
    assert "enum SearchRouterWeights {" in source and "GENERATED" in source
    assert "static let threshold: Double = 0.29" in source
    assert "static let bias: Double = -0.5" in source
    body = source[source.index("static let weights"):]
    assert body.count(",") == 512
    assert max(len(line) for line in source.splitlines()) <= 120


def test_the_untrained_stub_has_no_weights_and_says_so():
    source = t.render_untrained()
    assert "static let weights: [Double] = []" in source
    assert "UNTRAINED" in source
    assert max(len(line) for line in source.splitlines()) <= 120


def test_candidate_labels_are_stamped_in_the_header():
    source = t.render_swift(np.zeros(512), bias=0, threshold=0.5, count=3, cv_note="n", candidates=True)
    assert "candidate labels" in source


def test_the_shipped_weights_are_this_renderer_s_output():
    shipped = t.OUT.read_text()
    assert shipped.startswith(t.HEADER)
    assert t.render_untrained().startswith(t.HEADER)
    assert "enum SearchRouterWeights {" in shipped


def test_no_heavy_dependency_is_imported_at_module_level():
    source = t.HERE.joinpath("train_search_head.py").read_text()
    top = source[: source.index("def ")]
    assert "sklearn" not in top and "mlx" not in top
