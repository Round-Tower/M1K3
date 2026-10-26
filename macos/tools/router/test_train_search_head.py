"""Pins train_search_head.py: the search head's labels (a teacher must confirm a candidate unless a
hand check overrides it), the hold-outs (every chateval fixture, the voice-rig lines and the #680
lines stay out of training, near-copies too: #631), and the Swift it renders (the shape SearchRouter
reads, every line inside swiftlint's 120 columns). CI runs this with numpy only.

Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.85. Prior: none (new file).
Review: Kev + claude-opus-5.5, 2026-10-26 (review fold) — main()'s refusals (a held-out line, too few confirmed
labels, a candidates look over the shipped weights) and --untrained; the teacher bars at their own values; one
lexical near-copy bar; the positional vision fixtures; the guard read from the Swift and the head's own population;
the shipped weights are the stub or a confirmed fit. Confidence 0.85.
"""
import json

import numpy as np
import pytest
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


def test_the_teacher_bars_hold_at_their_own_values():
    # 1 - 0.8 is 0.19999999999999996 in floats: a teacher's recorded 0.2 must still confirm a local candidate.
    assert t.label({"search": True, "teacher": {"model": "m", "p": 0.8}}) is True
    assert t.label({"search": False, "teacher": {"model": "m", "p": 0.2}}) is False
    assert t.label({"search": True, "teacher": {"model": "m", "p": 0.79}}) is None
    assert t.label({"search": False, "teacher": {"model": "m", "p": 0.21}}) is None


def test_a_confirmed_label_still_wins_over_its_candidate_in_a_candidates_look():
    _, y = t.training_labels([{"prompt": "a", "search": True, "hand": False}], candidates=True)
    assert y.tolist() == [False]


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
    assert t.near_copy("What time is it?", "What time is it in Tokyo?")
    # One bar at every length (the 10-26 review): a one-word swap on a six-word line and a paraphrase of a
    # world-knowledge fixture both passed the old 0.75.
    assert t.near_copy("Tell me the history of Galway", "tell me the history of dublin")
    assert t.near_copy("What's the capital of Australia?", "What is the capital city of Australia?")
    assert t.near_copy("Why did the Berlin Wall fall?", "In what year did the Berlin Wall fall?")
    assert not t.near_copy("What caused the fall of the Roman Republic?", "tell me the history of Dublin")
    assert not t.near_copy("", "what about Cork?")


def test_held_out_violations_name_each_pair():
    prompts = ["Tell me the history of Dublin", "Who painted the Mona Lisa?"]
    assert t.held_out_violations(prompts, ["tell me the history of dublin"]) == [
        ("Tell me the history of Dublin", "tell me the history of dublin")
    ]


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


def test_the_positional_vision_helper_is_read_too():
    swift = '''
        visionFixture(
            "vis-receipt-total", "receipt-cafe", "What's the total on this receipt?",
            any: ["23.40", "23,40"]
        ),
    '''
    assert t.parse_fixture_prompts(swift) == ["What's the total on this receipt?"]


def test_the_committed_fixtures_parse_and_include_the_issue_680_fixtures():
    prompts = t.fixture_prompts()
    assert len(prompts) > 100
    lost = "the held-out parser lost a fixture"
    assert "Tell me the history of Dublin." in prompts, lost
    assert "Who won the All-Ireland hurling final this year?" in prompts, lost
    assert "Is Bluetooth on or off in this screenshot?" in prompts, lost  # visionFixture, positional
    assert "Who holds the marathon world record?" in prompts, lost  # an unguarded web read


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


def test_the_shipped_weights_are_the_stub_or_a_teacher_confirmed_fit():
    shipped = t.OUT.read_text(encoding="utf-8")
    if "UNTRAINED" in shipped:
        assert shipped == t.render_untrained()
    else:
        assert "candidate labels" not in shipped, "a look on candidate labels was committed"
        assert "teacher-confirmed labels" in shipped
    items = json.loads(t.DATA.read_text(encoding="utf-8"))["items"]
    if not t.training_labels(items)[0]:
        # No label is confirmed yet: nothing may ship but the stub that never vetoes.
        assert "UNTRAINED" in shipped and "static let weights: [Double] = []" in shipped


def test_a_long_cv_note_wraps_inside_120_columns():
    source = t.render_swift(np.zeros(512), bias=0, threshold=0.5, count=3, cv_note="a cross-validation word " * 12)
    assert max(len(line) for line in source.splitlines()) <= 120


def _data(tmp_path, monkeypatch, prompts, **item):
    path = tmp_path / "data.json"
    items = [{"prompt": prompt, "search": False, "source": "generated", "category": "x", "teacher": None, **item}
             for prompt in prompts]
    path.write_text(json.dumps({"provenance": "a test", "items": items}), encoding="utf-8")
    monkeypatch.setattr(t, "DATA", path)


def test_untrained_writes_exactly_the_stub(tmp_path):
    out = tmp_path / "w.swift"
    assert t.main(["--untrained", "--out", str(out)]) == 0
    assert out.read_text(encoding="utf-8") == t.render_untrained()


def test_a_held_out_line_in_the_data_is_refused_before_anything_is_written(tmp_path, monkeypatch, capsys):
    _data(tmp_path, monkeypatch, ["Tell me the history of Dublin.", "qzxa vrbla mnopa"])
    out = tmp_path / "w.swift"
    assert t.main(["--labels", "candidates", "--out", str(out)]) == 2
    assert "held-out" in capsys.readouterr().err
    assert not out.exists()


def test_too_few_confirmed_labels_is_refused_with_the_teacher_pass_named(tmp_path, monkeypatch, capsys):
    _data(tmp_path, monkeypatch, [f"qzx{i} vrbl{i} mnop{i}" for i in range(5)])
    out = tmp_path / "w.swift"
    assert t.main(["--out", str(out)]) == 2
    assert "teacher pass" in capsys.readouterr().err
    assert not out.exists()


def test_a_candidates_look_is_never_written_over_the_shipped_weights(tmp_path, monkeypatch, capsys):
    shipped = tmp_path / "SearchRouterWeights.swift"
    shipped.write_text("the shipped weights", encoding="utf-8")
    monkeypatch.setattr(t, "OUT", shipped)
    assert t.main(["--labels", "candidates"]) == 2
    assert "--out" in capsys.readouterr().err
    assert shipped.read_text(encoding="utf-8") == "the shipped weights"


def test_the_web_guard_is_read_from_the_swift():
    cues, suffixes = t.web_guard()
    assert {"look up", "lookup", "wikipedia", "online"} <= set(cues)  # ToolDispatch.webAskCues
    assert {"this year", "latest", "today"} <= set(cues)  # ToolDispatch.nowCues
    assert {"weather", "news", "tomorrow", "now"} <= set(cues)  # ToolNeedRouter.nowCues' own
    assert {"com", "ie", "app", "gov", "ai", "info"} <= set(suffixes)  # openSuffixes + guardSuffixes


# Rows of ToolDispatchTests' SearchCorrectedTests: the python reading must agree with the Swift one.
@pytest.mark.parametrize(("question", "asks"), [
    ("Search the web for the latest news headlines about Apple Silicon today.", True),
    ("Please lookup the founding year of Cork.", True),
    ("What does Wikipedia say about Cork?", True),
    ("What is on nasa.gov about the rover?", True),
    ("Fetch the web site m1k3.app and give me your read on how we're aligning.", True),
    ("What does https://example.com/about say?", True),
    ("Who won the All-Ireland hurling final this year?", True),
    ("What's the weather in Cork tomorrow?", True),
    ("tell me the history of Dublin", False),
    ("what about Cork?", False),
    ("Who painted Guernica?", False),
    ("Why did the Titanic sink so fast?", False),
    ("Has the new iPhone come out?", False),
])
def test_asks_for_the_web_reads_as_the_swift_guard_does(question, asks):
    assert t.asks_for_the_web(question) is asks


def test_only_turns_that_reach_the_head_count_toward_its_threshold():
    prompts = ["tell me the history of Dublin", "Search the web for Cork news", "What's the weather in Cork?",
               "Has the new iPhone come out?"]
    assert t.reaches_the_head(prompts).tolist() == [True, False, False, True]


def test_the_cv_note_counts_only_what_reaches_the_head():
    cv = np.array([0.9, 0.2, 0.3, 0.8, 0.1])
    y = np.array([True, True, True, False, False])
    reach = np.array([True, True, False, True, True])
    note = t.cv_note(cv, y, reach, threshold=0.5)
    assert "2 of 3 must-search items reach the head" in note
    assert "1/2 of those kept" in note
    assert "1/2 local turns that reach it read local" in note


def test_folds_group_by_router_group_or_generated_category():
    assert t.fold_group({"source": "router-data", "group": "web"}) == "router-data:web"
    assert t.fold_group({"source": "generated", "category": "news"}) == "generated:news"
    items = json.loads(t.DATA.read_text(encoding="utf-8"))["items"]
    assert all(t.fold_group(item) for item in items)


def test_no_heavy_dependency_is_imported_at_module_level():
    source = t.HERE.joinpath("train_search_head.py").read_text()
    top = source[: source.index("def ")]
    assert "sklearn" not in top and "mlx" not in top
