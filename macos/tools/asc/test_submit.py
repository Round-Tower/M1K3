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
