"""Pins for the pure half of creative.py (no key, no network)."""
from __future__ import annotations

from pathlib import Path

import creative
import pytest


def test_kind_follows_the_extension() -> None:
    assert creative.kind_for(Path("m1k3-header-3840x1646.png")) == "image"
    assert creative.kind_for(Path("a.JPG")) == "image"
    assert creative.kind_for(Path("m1k3-header-3840x1646.mp4")) == "video"
    with pytest.raises(SystemExit, match="gif"):
        creative.kind_for(Path("a.gif"))


def test_reserve_payload_is_a_creative_asset_in_the_apps_library() -> None:
    p = creative.reserve_payload("image", "h.png", 966345, "6780230835", "Header — Phosphor Fox")
    assert p["data"]["type"] == "appAssetLibraryImages"
    assert p["data"]["attributes"] == {"fileName": "h.png", "fileSize": 966345, "category": "CREATIVE_ASSETS",
                                       "referenceName": "Header — Phosphor Fox"}
    assert p["data"]["relationships"]["assetLibrary"]["data"] == {"type": "appAssetLibraries", "id": "6780230835"}


def test_a_video_reservation_carries_its_poster_frame() -> None:
    p = creative.reserve_payload("video", "h.mp4", 10, "1", None, poster="00:00:01:00")
    assert p["data"]["type"] == "appAssetLibraryVideos"
    assert p["data"]["attributes"]["previewFrameTimeCode"] == "00:00:01:00"
    assert "referenceName" not in p["data"]["attributes"]


def test_commit_takes_uploaded_alone() -> None:
    """Asset-library commits refuse a sourceFileChecksum (Apple's docs say so)."""
    assert creative.commit_payload("video", "v1") == {
        "data": {"type": "appAssetLibraryVideos", "id": "v1", "attributes": {"uploaded": True}}}


def test_parts_slice_the_file_by_each_operation() -> None:
    ops = [{"offset": 0, "length": 3}, {"offset": 3, "length": 2}]
    assert [chunk for _, chunk in creative.parts(b"abcde", ops)] == [b"abc", b"de"]


def test_targets_parse_to_a_surface() -> None:
    assert creative.parse_target("version:abc") == ("version", "abc")
    assert creative.parse_target("cpp:94bb") == ("cpp", "94bb")
    assert creative.parse_target("ppo:t1") == ("ppo", "t1")
    with pytest.raises(SystemExit, match="version:ID"):
        creative.parse_target("event:1")


def test_placement_payload_links_one_asset_to_one_localization() -> None:
    p = creative.placement_payload("image", "img1", "header", "cpp", "loc1")
    assert p["data"]["attributes"] == {"placementType": "PRODUCT_PAGE_HEADER_ASSET", "placementGroup": "DEFAULT_PROFILE"}
    assert p["data"]["relationships"] == {
        "image": {"data": {"type": "appAssetLibraryImages", "id": "img1"}},
        "appCustomProductPageLocalization": {"data": {"type": "appCustomProductPageLocalizations", "id": "loc1"}},
    }
    v = creative.placement_payload("video", "vid1", "search", "version", "loc2")
    assert v["data"]["attributes"]["placementType"] == "APP_STORE_SEARCH_RESULTS_ASSET"
    assert set(v["data"]["relationships"]) == {"video", "appStoreVersionLocalization"}


def test_plan_places_once_per_locale_and_never_over_the_cap() -> None:
    locs = [("l1", "en-US"), ("l2", "en-GB"), ("l3", "es-MX")]
    existing = {"l2": ["PRODUCT_PAGE_HEADER_ASSET"], "l3": ["APP_STORE_SEARCH_RESULTS_ASSET"]}
    create, skip = creative.plan(locs, existing, "header", None)
    assert create == [("l1", "en-US"), ("l3", "es-MX")]
    assert skip == [("en-GB", "already has a header (max 1)")]


def test_plan_can_narrow_to_named_locales_and_names_the_missing() -> None:
    locs = [("l1", "en-US"), ("l2", "en-GB")]
    create, skip = creative.plan(locs, {}, "search", ["en-GB", "fr-FR"])
    assert create == [("l2", "en-GB")]
    assert skip == [("fr-FR", "no such localization on this surface")]


def test_an_asset_can_be_placed_only_once_processed_and_alive() -> None:
    assert creative.state_problem({"state": "PREPARE_FOR_SUBMISSION"}) is None
    assert creative.state_problem({"state": "APPROVED"}) is None
    assert "processing" in creative.state_problem({"state": "UPLOAD_COMPLETE"})
    assert "boom" in creative.state_problem({"state": "FAILED", "stateDetails": {"errors": [{"code": "boom"}]}})


def test_spec_fit_reads_the_catalogue_not_a_hard_coded_list() -> None:
    universal = {"specId": "u", "shortName": "i5244x2950a0",
                 "compatiblePlacementTypes": ["APP_STORE_SEARCH_RESULTS_ASSET", "PRODUCT_PAGE_HEADER_ASSET"]}
    header_only = {"specId": "h", "shortName": "i3840x1646a0", "compatiblePlacementTypes": ["PRODUCT_PAGE_HEADER_ASSET"]}
    specs = {s["specId"]: s for s in (universal, header_only)}
    assert creative.spec_problem("u", "search", specs) is None
    assert creative.spec_problem("h", "header", specs) is None
    assert "i3840x1646a0" in creative.spec_problem("h", "search", specs)
    assert "unknown" in creative.spec_problem("zzz", "header", specs)


def test_spec_fit_survives_a_spec_without_placement_types() -> None:
    assert "not PRODUCT_PAGE_HEADER_ASSET" in creative.spec_problem("x", "header", {"x": {"specId": "x", "shortName": "s"}})


def test_placement_type_names_come_from_the_surface_table() -> None:
    p = creative.placement_payload("image", "i", "header", "ppo", "t1")
    assert p["data"]["relationships"]["appStoreVersionExperimentTreatmentLocalization"]["data"]["type"] == \
        "appStoreVersionExperimentTreatmentLocalizations"


def test_locales_are_trimmed_and_deduplicated() -> None:
    assert creative.parse_locales("en-US, en-GB,en-US") == ["en-US", "en-GB"]
    assert creative.parse_locales(None) is None


def test_parent_must_be_an_editable_ios_surface() -> None:
    assert creative.parent_problem("version", {"platform": "IOS", "appVersionState": "PREPARE_FOR_SUBMISSION"}) is None
    assert "WAITING_FOR_REVIEW" in creative.parent_problem("version", {"platform": "IOS", "appVersionState": "WAITING_FOR_REVIEW"})
    assert "iPhone and iPad only" in creative.parent_problem("version", {"platform": "MAC_OS", "appVersionState": "PREPARE_FOR_SUBMISSION"})
    assert creative.parent_problem("cpp", {"state": "PREPARE_FOR_SUBMISSION"}) is None
    assert "APPROVED" in creative.parent_problem("cpp", {"state": "APPROVED"})
    assert creative.parent_problem("ppo", {"state": "PREPARE_FOR_SUBMISSION"}) is None
    assert "STARTED" in creative.parent_problem("ppo", {"state": "STARTED"})


# ── the networked half, with ASC stubbed ──

class FakeASC:
    """Answers `call` from a script of (method, path-prefix) → responses, in order."""

    def __init__(self, script):
        self.script, self.sent = script, []

    def __call__(self, method, path, **kw):
        self.sent.append((method, path, kw.get("json")))
        for i, (m, prefix, resp) in enumerate(self.script):
            if m == method and path.startswith(prefix):
                return self.script.pop(i)[2]
        raise AssertionError(f"unscripted {method} {path}")


def _asset(state, details=None):
    return {"data": {"id": "img1", "attributes": {"state": state, "stateDetails": details, "specId": "u"}}}


@pytest.fixture
def quiet(monkeypatch):
    monkeypatch.setattr(creative.time, "sleep", lambda s: None)
    monkeypatch.setattr(creative, "put_part", lambda op, chunk: None)
    monkeypatch.setattr(creative, "catalogue", lambda strict=True: {"u": {"specId": "u", "shortName": "i3840x1646a0",
                                                               "compatiblePlacementTypes": ["PRODUCT_PAGE_HEADER_ASSET"]}})


def _upload(tmp_path, monkeypatch, polls):
    f = tmp_path / "h.png"
    f.write_bytes(b"\x89PNG" + b"\0" * 20)
    reserve = {"data": {"id": "img1", "attributes": {"uploadOperations": [{"method": "PUT", "url": "u", "offset": 0, "length": 24}]}}}
    fake = FakeASC([("POST", "/v1/appAssetLibraryImages", reserve),
                    ("PATCH", "/v1/appAssetLibraryImages/img1", _asset("UPLOAD_COMPLETE"))]
                   + [("GET", "/v1/appAssetLibraryImages/img1", p) for p in polls])
    monkeypatch.setattr(creative, "call", fake)
    return creative.run_upload("6780230835", f, None, None, confirm=True)


def test_upload_rides_out_a_transient_error_while_polling(tmp_path, monkeypatch, quiet, capsys) -> None:
    code = _upload(tmp_path, monkeypatch, [{"_error": 503, "_body": "busy"}, _asset("PREPARE_FOR_SUBMISSION")])
    out = capsys.readouterr().out
    assert code == 0 and "img1" in out and "PREPARE_FOR_SUBMISSION" in out


def test_upload_names_apples_reason_when_processing_fails(tmp_path, monkeypatch, quiet, capsys) -> None:
    code = _upload(tmp_path, monkeypatch, [_asset("FAILED", {"errors": [{"code": "IMAGE_TOO_WIDE"}]})])
    assert code == 1 and "IMAGE_TOO_WIDE" in capsys.readouterr().out


def test_upload_says_when_it_stopped_waiting(tmp_path, monkeypatch, quiet, capsys) -> None:
    monkeypatch.setattr(creative, "POLLS", 2)
    code = _upload(tmp_path, monkeypatch, [_asset("UPLOAD_COMPLETE"), _asset("UPLOAD_COMPLETE")])
    out = capsys.readouterr().out
    assert code == 1 and "still processing" in out and "img1" in out


def _place(monkeypatch, parent, existing=(), confirm=False, locales=None):
    fake = FakeASC([("GET", "/v1/appAssetLibraryImages/img1", _asset("PREPARE_FOR_SUBMISSION")),
                    ("GET", "/v1/appStoreVersions/v1", {"data": {"attributes": parent}})]
                   + [("POST", "/v1/appAssetLibraryPlacements", {"data": {"id": f"p{i}", "attributes": {}}}) for i in range(3)])
    pages = {"/v1/appStoreVersions/v1/appStoreVersionLocalizations": [{"id": "l1", "attributes": {"locale": "en-US"}},
                                                                     {"id": "l2", "attributes": {"locale": "en-GB"}}],
             "/v1/appStoreVersionLocalizations/l1/placements": [{"attributes": {"placementType": t}} for t in existing],
             "/v1/appStoreVersionLocalizations/l2/placements": []}
    monkeypatch.setattr(creative, "call", fake)
    monkeypatch.setattr(creative, "paginate", lambda path: iter(pages[path.split("?")[0]]))
    return fake, creative.run_place("img1", "header", "version:v1", locales, confirm)


def test_place_refuses_a_version_apple_is_reviewing(monkeypatch, quiet) -> None:
    with pytest.raises(SystemExit, match="WAITING_FOR_REVIEW"):
        _place(monkeypatch, {"platform": "IOS", "appVersionState": "WAITING_FOR_REVIEW"})


def test_place_dry_run_prints_the_payload_and_sends_nothing(monkeypatch, quiet, capsys) -> None:
    fake, code = _place(monkeypatch, {"platform": "IOS", "appVersionState": "PREPARE_FOR_SUBMISSION"})
    out = capsys.readouterr().out
    assert code == 0 and '"placementType": "PRODUCT_PAGE_HEADER_ASSET"' in out
    assert not [s for s in fake.sent if s[0] == "POST"]


def test_place_creates_one_per_open_locale(monkeypatch, quiet) -> None:
    fake, code = _place(monkeypatch, {"platform": "IOS", "appVersionState": "PREPARE_FOR_SUBMISSION"},
                        existing=["PRODUCT_PAGE_HEADER_ASSET"], confirm=True)
    posts = [body for method, _, body in fake.sent if method == "POST"]
    assert code == 0 and len(posts) == 1
    assert posts[0]["data"]["relationships"]["appStoreVersionLocalization"]["data"]["id"] == "l2"


def test_place_fails_when_nothing_matched(monkeypatch, quiet) -> None:
    _, code = _place(monkeypatch, {"platform": "IOS", "appVersionState": "PREPARE_FOR_SUBMISSION"}, locales=["fr-FR"])
    assert code == 1


def test_find_asset_surfaces_a_real_error_instead_of_not_found(monkeypatch) -> None:
    monkeypatch.setattr(creative, "call", lambda m, p, **kw: {"_error": 401, "_body": "token expired"})
    with pytest.raises(SystemExit, match="401"):
        creative.find_asset("img1")


class _Resp:
    def __init__(self, status):
        self.status_code, self.text = status, f"status {status}"


def _sender(*statuses):
    calls = []

    def send(method, url, **kw):
        status = statuses[len(calls)]
        calls.append(status)
        if isinstance(status, Exception):
            raise status
        return _Resp(status)
    return send, calls


def test_put_part_retries_throttling_and_transport_errors(monkeypatch) -> None:
    sleeps = []
    monkeypatch.setattr(creative.time, "sleep", sleeps.append)
    send, calls = _sender(429, ConnectionError("reset"), 200)
    creative.put_part({"method": "PUT", "url": "u", "offset": 0}, b"x", send=send)
    assert calls[-1] == 200 and len(calls) == 3


def test_put_part_gives_up_at_once_on_a_client_error_and_never_sleeps_after_the_last_try(monkeypatch) -> None:
    sleeps = []
    monkeypatch.setattr(creative.time, "sleep", sleeps.append)
    send, calls = _sender(403)
    with pytest.raises(SystemExit, match="403"):
        creative.put_part({"method": "PUT", "url": "u", "offset": 0}, b"x", send=send)
    assert len(calls) == 1 and sleeps == []
    send, calls = _sender(503, 503, 503)
    with pytest.raises(SystemExit, match="503"):
        creative.put_part({"method": "PUT", "url": "u", "offset": 0}, b"x", send=send)
    assert len(calls) == 3 and len(sleeps) == 2


def test_upload_stops_waiting_when_asc_stops_answering(tmp_path, monkeypatch, quiet) -> None:
    with pytest.raises(SystemExit, match="img1.*stopped answering"):
        _upload(tmp_path, monkeypatch, [{"_error": 503, "_body": "x"}] * 5)


def test_find_asset_falls_through_to_videos_on_a_client_error(monkeypatch) -> None:
    answers = {"/v1/appAssetLibraryImages/v1": {"_error": 400, "_body": "wrong type"},
               "/v1/appAssetLibraryVideos/v1": {"data": {"attributes": {"state": "APPROVED"}}}}
    monkeypatch.setattr(creative, "call", lambda m, p, **kw: answers[p])
    assert creative.find_asset("v1") == ("video", {"state": "APPROVED"})


def test_ppo_parent_is_read_from_the_included_experiment_by_type(monkeypatch, capsys) -> None:
    exp = {"type": "appStoreVersionExperiments", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}
    other = {"type": "appStoreVersions", "attributes": {"state": "READY_FOR_SALE"}}
    monkeypatch.setattr(creative, "call", lambda m, p, **kw: {"data": {}, "included": [other, exp]})
    assert creative.parent_state("ppo", "t1") == {"state": "PREPARE_FOR_SUBMISSION"}
    monkeypatch.setattr(creative, "call", lambda m, p, **kw: {"data": {}, "included": [other]})
    assert creative.parent_state("ppo", "t1") is None and "warning" in capsys.readouterr().out


def test_place_summary_tells_partial_from_nothing(monkeypatch, quiet, capsys) -> None:
    _, code = _place(monkeypatch, {"platform": "IOS", "appVersionState": "PREPARE_FOR_SUBMISSION"},
                     confirm=True, locales=["en-GB", "fr-FR"])
    out = capsys.readouterr().out
    assert code == 1 and "placed 1" in out and "1 not on this surface" in out
