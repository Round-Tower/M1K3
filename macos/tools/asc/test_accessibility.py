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


def test_the_shipped_spec_declares_only_what_the_walk_confirmed() -> None:
    # #834: declare only what the 1.5 TestFlight walk confirms. Kev walked build 553 on
    # 2026-11-15; every declared claim names that walk, and nothing is left pending.
    spec = a11y.load_spec(HERE / "accessibility_labels.json")
    steps = a11y.plan(spec, [], list(spec))
    assert a11y.refusal(steps, allow_pending=None) is None
    for family in spec.values():
        for claim in family.values():
            if claim["status"] == "declare":
                assert "walked TestFlight build 553" in claim["evidence"]


class FakeASC:
    """Stands in for asc.call / paginate: records every request, answers a POST with an id."""

    def __init__(self, live: list[dict] | None = None) -> None:
        self.live = live or []
        self.calls: list[tuple[str, str, dict]] = []

    def call(self, method: str, path: str, **kw: object) -> dict:
        self.calls.append((method, path, kw.get("json")))  # type: ignore[arg-type]
        return {"data": {"id": "NEW1"}} if method == "POST" else {"data": {}}

    def paginate(self, path: str):  # noqa: ANN201
        yield from self.live


@pytest.fixture
def fake(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> FakeASC:
    asc_fake = FakeASC()
    monkeypatch.setattr(a11y, "call", asc_fake.call)
    monkeypatch.setattr(a11y, "paginate", asc_fake.paginate)
    spec = tmp_path / "spec.json"
    spec.write_text(json.dumps(spec_of(MAC={"voiceover": "declare"}, IPHONE={"voiceover": "pending"})))
    monkeypatch.setattr(a11y, "SPEC", spec)
    return asc_fake



def test_a_dry_run_writes_nothing(fake: FakeASC) -> None:
    assert a11y.set_labels(["MAC", "IPHONE"], publish=True, confirm=False, allow_pending=None) == 0
    assert fake.calls == []


def test_a_pending_claim_refuses_confirm_before_any_write(fake: FakeASC) -> None:
    assert a11y.set_labels(["MAC", "IPHONE"], publish=True, confirm=True, allow_pending=None) == 3
    assert fake.calls == []


def test_create_then_publish_sends_the_full_attributes_to_the_new_draft(fake: FakeASC) -> None:
    assert a11y.set_labels(["MAC"], publish=True, confirm=True, allow_pending=None) == 0
    methods = [(m, p) for m, p, _ in fake.calls]
    assert methods == [("POST", "/v1/accessibilityDeclarations"), ("PATCH", "/v1/accessibilityDeclarations/NEW1")]
    patch = fake.calls[1][2]["data"]
    assert patch["id"] == "NEW1"
    assert patch["attributes"]["publish"] is True
    assert patch["attributes"]["supportsVoiceover"] is True


def test_allow_pending_writes_with_a_reason(fake: FakeASC) -> None:
    assert a11y.set_labels(["IPHONE"], publish=False, confirm=True, allow_pending="walked; motion left out") == 0
    assert [m for m, _, _ in fake.calls] == ["POST"]


def test_an_empty_family_list_is_refused(fake: FakeASC) -> None:
    with pytest.raises(SystemExit, match="no device family"):
        a11y.set_labels([], publish=False, confirm=True, allow_pending=None)


def test_a_draft_beside_a_published_one_is_the_one_edited() -> None:
    spec = spec_of(MAC={"voiceover": "declare"})
    steps = a11y.plan(spec, [live("P1", "MAC", "PUBLISHED"), live("D1", "MAC", "DRAFT")], ["MAC"])
    assert (steps[0].action, steps[0].draft_id) == ("update", "D1")
