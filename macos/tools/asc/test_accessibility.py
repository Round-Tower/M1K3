"""Pins for accessibility.py's pure half: the spec, the payloads, the plan and the pending gate."""
from __future__ import annotations

import json
from pathlib import Path

import accessibility as a11y
import pytest

HERE = Path(__file__).resolve().parent


def spec_of(**families: dict[str, str]) -> dict:
    """A full spec: every feature 'no' unless named."""
    return {fam: {f: {"status": statuses.get(f, "no"), "evidence": "e"} for f in a11y.FEATURES}
            for fam, statuses in families.items()}


def test_the_shipped_spec_loads_and_names_every_feature_per_family() -> None:
    spec = a11y.load_spec(HERE / "accessibility_labels.json")
    assert set(spec) == {"MAC", "IPHONE", "IPAD"}
    for family in spec.values():
        assert set(family) == set(a11y.FEATURES)


def test_a_spec_missing_a_feature_or_with_an_unknown_status_is_refused(tmp_path: Path) -> None:
    spec = spec_of(MAC={})
    del spec["MAC"]["voiceover"]
    (tmp_path / "s.json").write_text(json.dumps(spec))
    with pytest.raises(SystemExit, match="voiceover"):
        a11y.load_spec(tmp_path / "s.json")
    spec = spec_of(MAC={"voiceover": "maybe"})
    (tmp_path / "s.json").write_text(json.dumps(spec))
    with pytest.raises(SystemExit, match="maybe"):
        a11y.load_spec(tmp_path / "s.json")
    (tmp_path / "s.json").write_text(json.dumps(spec_of(WATCH={})))
    with pytest.raises(SystemExit, match="WATCH"):
        a11y.load_spec(tmp_path / "s.json")


def test_only_declare_becomes_true() -> None:
    attrs = a11y.attributes(spec_of(MAC={"voiceover": "declare", "voiceControl": "pending"})["MAC"])
    assert attrs["supportsVoiceover"] is True
    assert attrs["supportsVoiceControl"] is False
    assert attrs["supportsCaptions"] is False
    assert len(attrs) == len(a11y.FEATURES)


def test_create_payload_matches_the_openapi_shape() -> None:
    body = a11y.create_body("MAC", {"supportsVoiceover": True})
    assert body == {"data": {"type": "accessibilityDeclarations",
                             "attributes": {"deviceFamily": "MAC", "supportsVoiceover": True},
                             "relationships": {"app": {"data": {"type": "apps", "id": a11y.APP_ID}}}}}


def test_update_payload_can_publish() -> None:
    body = a11y.update_body("D1", {"supportsVoiceover": True}, publish=True)
    assert body == {"data": {"type": "accessibilityDeclarations", "id": "D1",
                             "attributes": {"supportsVoiceover": True, "publish": True}}}


def live(id_: str, family: str, state: str, **supports: bool) -> dict:
    attrs = {"deviceFamily": family, "state": state}
    attrs.update({a11y.ATTRIBUTE[f]: supports.get(f, False) for f in a11y.FEATURES})
    return {"id": id_, "attributes": attrs}


def test_plan_creates_when_nothing_is_live_and_updates_a_draft() -> None:
    spec = spec_of(MAC={"voiceover": "declare"}, IPHONE={"voiceover": "declare"})
    steps = a11y.plan(spec, [live("D9", "IPHONE", "DRAFT")], ["MAC", "IPHONE"])
    assert [(s.family, s.action, s.draft_id) for s in steps] == [("MAC", "create", None), ("IPHONE", "update", "D9")]


def test_plan_is_a_no_op_when_the_published_one_already_says_it() -> None:
    spec = spec_of(MAC={"voiceover": "declare"})
    steps = a11y.plan(spec, [live("P1", "MAC", "PUBLISHED", voiceover=True)], ["MAC"])
    assert steps[0].action == "same"
    # A REPLACED one is history, never the one compared or edited.
    steps = a11y.plan(spec, [live("R1", "MAC", "REPLACED", voiceover=True)], ["MAC"])
    assert steps[0].action == "create"


def test_pending_claims_are_listed_and_gate_confirm() -> None:
    spec = spec_of(MAC={"voiceover": "declare", "reducedMotion": "pending"})
    steps = a11y.plan(spec, [], ["MAC"])
    assert steps[0].pending == ["reducedMotion"]
    assert a11y.refusal(steps, allow_pending=None) is not None
    assert a11y.refusal(steps, allow_pending="walked, Reduce Motion left undeclared on purpose") is None
    clean = a11y.plan(spec_of(MAC={"voiceover": "declare"}), [], ["MAC"])
    assert a11y.refusal(clean, allow_pending=None) is None


def test_the_shipped_spec_cannot_be_confirmed_before_the_walk() -> None:
    # #834: declare only what the 1.5 TestFlight walk confirms. Until someone flips the
    # lines with the walk's evidence, --confirm refuses.
    spec = a11y.load_spec(HERE / "accessibility_labels.json")
    steps = a11y.plan(spec, [], list(spec))
    assert a11y.refusal(steps, allow_pending=None) is not None
