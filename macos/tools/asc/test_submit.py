"""Pins for the pure half of submit.py (no key, no network) — the review-submission
state machine the launch day drove by hand and the 2026-09-16 resubmit needed again."""
from __future__ import annotations

import asc
import submit


def _sub(id_, platform, state, date="2026-09-15T17:37:27.106Z"):
    return {"id": id_, "attributes": {"platform": platform, "state": state, "submittedDate": date}}


def _item(version_id):
    return {"id": "i-" + version_id, "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}


SUBS = [
    _sub("ios-queued", "IOS", "WAITING_FOR_REVIEW"),
    _sub("mac-open", "MAC_OS", "UNRESOLVED_ISSUES"),
    _sub("ios-done", "IOS", "COMPLETE", "2026-09-15T17:11:04.007Z"),
    _sub("mac-done", "MAC_OS", "COMPLETE", "2026-09-15T17:10:48.103Z"),
]


def test_submission_for_picks_the_live_one_per_platform() -> None:
    assert submit.submission_for(SUBS, "MAC_OS")["id"] == "mac-open"
    assert submit.submission_for(SUBS, "IOS")["id"] == "ios-queued"
    assert submit.submission_for(SUBS, "VISION_OS") is None
    # terminal states never count, even when they are the newest (CANCELING is transitional — see below)
    assert submit.submission_for([_sub("a", "MAC_OS", "COMPLETE"), _sub("b", "MAC_OS", "COMPLETE", "2026-09-16T00:00:00Z")], "MAC_OS") is None


def test_next_steps_from_every_state() -> None:
    v = "ver-1"
    assert submit.next_steps(None, "MAC_OS", v, []) == ["create a MAC_OS submission", "add version ver-1", "submit"]
    open_ = _sub("s", "MAC_OS", "UNRESOLVED_ISSUES")
    assert submit.next_steps(open_, "MAC_OS", v, []) == ["add version ver-1", "submit"]
    assert submit.next_steps(open_, "MAC_OS", v, [_item(v)]) == ["submit"]
    ready = _sub("s", "MAC_OS", "READY_FOR_REVIEW")
    assert submit.next_steps(ready, "MAC_OS", v, [_item(v)]) == ["submit"]
    for state in ("WAITING_FOR_REVIEW", "IN_REVIEW"):
        assert submit.next_steps(_sub("s", "MAC_OS", state), "MAC_OS", v, [_item(v)]) == [f"already {state} — nothing to do"]


def test_canceling_waits_instead_of_spawning_a_second_submission() -> None:
    canceling = _sub("s", "MAC_OS", "CANCELING")
    assert submit.submission_for([canceling], "MAC_OS")["id"] == "s"
    assert submit.next_steps(canceling, "MAC_OS", "ver-1", []) == ["CANCELING — wait for COMPLETE, then submit again"]
    assert not submit.cancel_allowed(canceling)


def test_has_item_survives_a_null_relationship() -> None:
    null_item = {"id": "i", "relationships": {"appStoreVersion": {"data": None}}}
    assert not submit.has_item([null_item], "ver-1")


def test_cancel_is_for_live_submissions_only() -> None:
    assert submit.cancel_allowed(_sub("s", "IOS", "WAITING_FOR_REVIEW"))
    assert submit.cancel_allowed(_sub("s", "IOS", "UNRESOLVED_ISSUES"))
    assert not submit.cancel_allowed(_sub("s", "IOS", "COMPLETE"))
    assert not submit.cancel_allowed(None)


def test_payload_shapes_match_the_launch_day_calls() -> None:
    create = submit.create_payload("MAC_OS")
    assert create == {"data": {"type": "reviewSubmissions", "attributes": {"platform": "MAC_OS"},
                               "relationships": {"app": {"data": {"type": "apps", "id": asc.APP_ID}}}}}
    item = submit.item_payload("sub-1", "ver-1")
    assert item["data"]["type"] == "reviewSubmissionItems"
    assert item["data"]["relationships"] == {
        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": "sub-1"}},
        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": "ver-1"}},
    }
    assert submit.submit_payload("sub-1") == {"data": {"type": "reviewSubmissions", "id": "sub-1", "attributes": {"submitted": True}}}
    assert submit.cancel_payload("sub-1") == {"data": {"type": "reviewSubmissions", "id": "sub-1", "attributes": {"canceled": True}}}


def test_has_item_reads_the_version_relationship() -> None:
    assert submit.has_item([_item("ver-1")], "ver-1")
    assert not submit.has_item([_item("ver-2")], "ver-1")
    assert not submit.has_item([], "ver-1")


# --- attach / ALL / the verify gate (2026-10-05 release: all three were scratchpad code) ---

def _build(state="VALID", expired=False, encryption=False, version="453"):
    return {"id": "b-" + version, "attributes": {"version": version, "processingState": state,
                                                 "expired": expired, "usesNonExemptEncryption": encryption}}


def test_all_means_the_platforms_that_ship():
    assert submit.expand_platforms("ALL") == ("MAC_OS", "IOS")
    assert submit.expand_platforms("IOS") == ("IOS",)


def test_attach_refuses_a_version_in_review():
    problems = submit.attach_problems("WAITING_FOR_REVIEW", _build(), current="446")
    assert any("cancel" in p for p in problems)


def test_attach_accepts_an_editable_version_and_a_valid_build():
    for state in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"):
        assert submit.attach_problems(state, _build(), current="446") == []


def test_attach_refuses_a_bad_build():
    assert submit.attach_problems("DEVELOPER_REJECTED", None, current="446")
    assert submit.attach_problems("DEVELOPER_REJECTED", _build(state="PROCESSING"), current="446")
    assert submit.attach_problems("DEVELOPER_REJECTED", _build(expired=True), current="446")
    assert submit.attach_problems("DEVELOPER_REJECTED", _build(encryption=None), current="446")


def test_attaching_the_build_already_there_is_nothing_to_do():
    assert submit.already_attached(_build(), current="453")
    assert not submit.already_attached(_build(), current="446")
    assert not submit.already_attached(None, current="453")


def test_attach_payload_names_the_build():
    assert submit.attach_payload("b-453") == {"data": {"type": "builds", "id": "b-453"}}


def test_editable_is_the_state_cancel_waits_for():
    assert submit.is_editable("DEVELOPER_REJECTED")
    assert not submit.is_editable("WAITING_FOR_REVIEW")


def test_submit_is_gated_on_a_verified_build(tmp_path):
    # The 2026-10-05 release: both cancels ran before the build was checked.
    assert submit.gate_problems("453", stamp_dir=tmp_path, why=None)
    (tmp_path / "verified-453.json").write_text('{"build": "453"}')
    assert submit.gate_problems("453", stamp_dir=tmp_path, why=None) == []
    assert submit.gate_problems("454", stamp_dir=tmp_path, why=None)  # a stamp is per build


def test_the_gate_takes_a_reason_not_a_token(tmp_path):
    assert submit.gate_problems("453", stamp_dir=tmp_path, why="x")
    assert submit.gate_problems("453", stamp_dir=tmp_path, why="        x         ")  # padding is not a reason
    assert submit.gate_problems("453", stamp_dir=tmp_path, why="metadata-only resubmit, no new build") == []


def test_no_build_attached_is_never_waved_through(tmp_path):
    problems = submit.gate_problems(None, stamp_dir=tmp_path, why="metadata-only resubmit, no new build")
    assert problems and "no build attached" in problems[0]


def test_submit_all_writes_nothing_unless_every_platform_passes():
    # Review on the release-tooling PR: Mac sent, iOS refused, is a split release.
    assert submit.blocked({"MAC_OS": [], "IOS": []}) == []
    assert submit.blocked({"MAC_OS": [], "IOS": ["build 452 has not been verified"]}) == ["IOS: build 452 has not been verified"]


# --- review on #490, round 2: a plan is checked whole before anything is sent ---

def test_a_canceling_platform_blocks_the_whole_release():
    # iOS CANCELING with Mac ready must send nothing for Mac (it used to send Mac, skip iOS, exit 0).
    assert submit.plan_problems(["CANCELING — wait for COMPLETE, then submit again"], "DEVELOPER_REJECTED", _build())


def test_an_already_queued_platform_is_a_no_op_not_a_blocker():
    assert submit.plan_problems(["already WAITING_FOR_REVIEW — nothing to do"], "WAITING_FOR_REVIEW", _build()) == []


def test_submit_checks_the_build_and_version_too():
    steps = ["create a MAC_OS submission", "add version v", "submit"]
    assert submit.plan_problems(steps, "PREPARE_FOR_SUBMISSION", _build()) == []
    assert submit.plan_problems(steps, "PREPARE_FOR_SUBMISSION", _build(expired=True))
    assert submit.plan_problems(steps, "PREPARE_FOR_SUBMISSION", _build(encryption=None))
    assert submit.plan_problems(steps, "PREPARE_FOR_SUBMISSION", None)


def test_a_stamp_must_name_its_build(tmp_path):
    (tmp_path / "verified-453.json").write_text("")  # a bare `touch` is not a check
    assert submit.gate_problems("453", stamp_dir=tmp_path)
    (tmp_path / "verified-453.json").write_text('{"build": "452"}')
    assert submit.gate_problems("453", stamp_dir=tmp_path)
    (tmp_path / "verified-453.json").write_text('{"build": "453"}')
    assert submit.gate_problems("453", stamp_dir=tmp_path) == []
