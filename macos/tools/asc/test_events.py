"""Pins for events.py: the pure half, and the live loop against a recorded fake (no key,
no network)."""
from __future__ import annotations

import json
import sys
import types
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

import asc
import events


def _spec() -> dict:
    return {
        "referenceName": "waking-up-2026-09", "badge": "PREMIERE", "purpose": "ATTRACT_NEW_USERS",
        "publishStart": "2026-09-17T09:00:00Z", "eventStart": "2026-09-18T09:00:00Z",
        "eventEnd": "2026-10-16T21:00:00Z", "deepLink": "m1k3://event/waking-up",
        "copy": {"name": "Waking Up", "shortDescription": "short", "longDescription": "long"},
    }


def test_copy_problems_reports_each_cap_and_empties() -> None:
    assert events.copy_problems({"name": "x" * 31, "shortDescription": "ok", "longDescription": ""}) == [
        "name: 31/30", "longDescription: empty"]
    assert events.copy_problems({"name": "Waking Up", "shortDescription": "s", "longDescription": "l"}) == []


def test_event_payload_shape_and_deep_link() -> None:
    p = events.event_payload(_spec(), ["USA", "IRL"])
    a = p["data"]["attributes"]
    assert p["data"]["relationships"]["app"]["data"]["id"] == asc.APP_ID
    assert a["territorySchedules"][0]["territories"] == ["USA", "IRL"]
    assert a["purchaseRequirement"] == "NO_COST_ASSOCIATED" and a["priority"] == "HIGH"
    assert a["deepLink"] == "m1k3://event/waking-up"
    bare = {k: v for k, v in _spec().items() if k != "deepLink"}
    assert "deepLink" not in events.event_payload(bare, ["USA"])["data"]["attributes"]  # the builder stays literal
    with pytest.raises(ValueError):
        events.event_payload({**_spec(), "badge": "PARTY"}, ["USA"])


def test_localization_payload_carries_only_the_three_copy_fields() -> None:
    spec = _spec()
    spec["copy"]["extra"] = "ignored"
    attrs = events.localization_payload(spec, "E1")["data"]["attributes"]
    assert set(attrs) == {"locale", "name", "shortDescription", "longDescription"}


def test_attributes_patch_and_localization_patch_shapes() -> None:
    patch = events.attributes_patch(_spec(), "E1", ["USA"])
    assert patch["data"]["id"] == "E1" and "relationships" not in patch["data"]
    assert patch["data"]["attributes"]["badge"] == "PREMIERE"
    assert patch["data"]["attributes"]["deepLink"] == "m1k3://event/waking-up"   # how `update` sets a live draft's link
    lp = events.localization_patch("L1", {"name": "n", "shortDescription": "s", "longDescription": "l", "x": 1})
    assert lp["data"]["id"] == "L1" and set(lp["data"]["attributes"]) == {"name", "shortDescription", "longDescription"}


def test_localization_problems_prefixes_the_locale() -> None:
    spec = {"localizations": {"de-DE": {"name": "ok", "shortDescription": "s" * 51, "longDescription": "l"}}}
    assert events.localization_problems(spec) == ["de-DE: shortDescription: 51/50"]


EVENT_SPECS = sorted((Path(__file__).resolve().parents[2] / "fastlane/events").glob("*/event.json"))
# Every store locale: an event covers each one the iPhone listing has.
LOCALES = {p.name for p in (Path(__file__).resolve().parents[2] / "fastlane/metadata_ios").iterdir() if p.is_dir()}


def _when(stamp: str) -> datetime:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def test_both_shipped_specs_are_found() -> None:
    assert {p.parent.name for p in EVENT_SPECS} >= {"waking-up", "halloween"}


@pytest.mark.parametrize("path", EVENT_SPECS, ids=lambda p: p.parent.name)
def test_every_event_spec_is_within_apples_rules(path: Path) -> None:
    """Caps, every store locale, Apple's enums, and the schedule limits from
    developer.apple.com/help/app-store-connect/offer-in-app-events/offer-in-app-events:
    publish at most 14 days before the start; an event runs 15 minutes to 31 days."""
    spec = json.loads(path.read_text())
    assert events.copy_problems(spec["copy"]) == []
    assert events.localization_problems(spec) == []
    # Waking Up never shipped (its draft, never submitted, runs out on 16 Oct) and predates the
    # store's en-GB, es-MX and ru (2026-10-22); an event that ships covers every store locale.
    expected = LOCALES - {"en-GB", "es-MX", "ru"} if path.parent.name == "waking-up" else LOCALES
    assert set(spec["localizations"]) == expected
    assert spec["localizations"][spec.get("locale", "en-US")] == spec["copy"]   # one primary copy, not two
    events.event_payload(spec, ["USA"])                                            # badge + purpose in the enums
    assert spec.get("priority", "HIGH") in ("HIGH", "NORMAL")
    start, end, publish = (_when(spec[k]) for k in ("eventStart", "eventEnd", "publishStart"))
    assert timedelta(0) <= start - publish <= timedelta(days=14)
    assert timedelta(minutes=15) <= end - start <= timedelta(days=31)


def test_the_halloween_event_runs_the_apps_window() -> None:
    """The app wears the look Oct 24 00:00 – Nov 1 23:59:59 on each device's local calendar
    (SeasonalLook.active). The card goes live at local Oct 24 00:00 in UTC−10 (Hawaii) and
    ends at local Nov 2 00:00 in UTC+13 (NZ daylight time), so from UTC−10 to UTC+13 it is
    never live where the look isn't."""
    spec = json.loads((Path(__file__).resolve().parents[2] / "fastlane/events/halloween/event.json").read_text())
    assert (spec["referenceName"], spec["badge"], spec["purpose"], spec["priority"]) == (
        "halloween-2026", "SPECIAL_EVENT", "APPROPRIATE_FOR_ALL_USERS", "NORMAL")
    hawaii, new_zealand = timezone(timedelta(hours=-10)), timezone(timedelta(hours=13))
    assert _when(spec["eventStart"]) == datetime(2026, 10, 24, tzinfo=hawaii)
    assert _when(spec["eventEnd"]) == datetime(2026, 11, 2, tzinfo=new_zealand)
    assert _when(spec["publishStart"]) == datetime(2026, 10, 17, 9, tzinfo=timezone.utc)
    assert spec["copy"]["name"] == "Halloween in the Lair"
    # Open on the card lands in the app through the scheme the iOS target registers
    # (tools/ci/check_store_targets.py pins the registration).
    assert spec["deepLink"] == "m1k3://event/halloween"
    assert set(spec["localizations"]) == LOCALES


def test_localization_table_puts_the_primary_first_and_falls_back_to_copy() -> None:
    de = {"name": "n", "shortDescription": "s", "longDescription": "l"}
    spec = {**_spec(), "localizations": {"de-DE": de, "en-US": _spec()["copy"]}}
    assert list(events.localization_table(spec)) == ["en-US", "de-DE"]
    assert events.localization_table(_spec()) == {"en-US": _spec()["copy"]}
    assert events.localization_table({**_spec(), "localizations": {"de-DE": de}}) == {"en-US": _spec()["copy"], "de-DE": de}


def test_localization_table_needs_no_copy_block_when_the_table_holds_the_primary() -> None:
    de = {"name": "n", "shortDescription": "s", "longDescription": "l"}
    bare = {k: v for k, v in _spec().items() if k != "copy"}
    assert events.localization_table({**bare, "localizations": {"de-DE": de, "en-US": de}}) == {"en-US": de, "de-DE": de}
    with pytest.raises(ValueError, match="no copy for the primary locale en-US"):
        events.localization_table({**bare, "localizations": {"de-DE": de}})


@pytest.mark.parametrize("event_id", [None, "EV7"], ids=["fresh", "resume"])
def test_create_dry_run_builds_every_localization_and_sends_nothing(event_id, tmp_path, capsys, monkeypatch) -> None:
    def no_network(*_a, **_k):
        raise AssertionError("a dry run must not call App Store Connect")
    for name in ("call", "paginate", "upload_media", "probe"):
        monkeypatch.setattr(events, name, no_network)
    for name in (events.CARD_FILE, events.DETAILS_FILE):
        (tmp_path / name).write_bytes(b"\xff\xd8\xff\xd9")
    spec_path = Path(__file__).resolve().parents[2] / "fastlane/events/halloween/event.json"
    assert events.create(spec_path, tmp_path, dry_run=True, event_id=event_id) == 0
    out = capsys.readouterr().out
    for locale in LOCALES:
        assert f'"locale": "{locale}"' in out, locale
    assert out.index('"locale": "en-US"') < out.index('"locale": "de-DE"')   # the primary goes first
    assert out.rstrip().endswith("dry run: nothing sent")
    if event_id:   # a resume says it would list, and never builds a second event
        assert f"would GET /v1/appEvents/{event_id}/localizations" in out
        assert '"referenceName"' not in out
        assert out.count(f'"id": "{event_id}"') == len(LOCALES)


@pytest.mark.parametrize("link,ok", [
    ("m1k3://event/halloween", True),
    ("https://m1k3.app/halloween", True),
    (None, False),
    ("", False),
    ("   ", False),
    ("halloween", False),
    ("m1k3://", False),
    ("://event", False),
    (42, False),
])
def test_deep_link_problems_wants_a_url(link, ok) -> None:
    spec = {**_spec(), "deepLink": link} if link is not None else {k: v for k, v in _spec().items() if k != "deepLink"}
    problems = events.deep_link_problems(spec)
    assert (problems == []) is ok, problems
    if not ok:
        assert "deepLink" in problems[0]


def test_create_refuses_a_spec_without_a_deep_link_before_sending(tmp_path, monkeypatch) -> None:
    # App Store Connect won't add an event for review without one (2026-10-14): the
    # Halloween draft had to be patched after the fact. Refuse before any request.
    def no_network(*_a, **_k):
        raise AssertionError("a refused spec must not reach App Store Connect")
    for name in ("call", "paginate", "upload_media", "probe"):
        monkeypatch.setattr(events, name, no_network)
    path = tmp_path / "event.json"
    path.write_text(json.dumps({k: v for k, v in _spec().items() if k != "deepLink"}))
    for dry_run in (True, False):
        with pytest.raises(SystemExit, match="no deepLink"):
            events.create(path, tmp_path, dry_run=dry_run)


def test_update_refuses_a_spec_without_a_deep_link_before_sending(tmp_path, monkeypatch) -> None:
    def no_network(*_a, **_k):
        raise AssertionError("a refused spec must not reach App Store Connect")
    for name in ("call", "paginate"):
        monkeypatch.setattr(events, name, no_network)
    path = tmp_path / "event.json"
    path.write_text(json.dumps({**_spec(), "deepLink": "halloween"}))
    for dry_run in (True, False):
        with pytest.raises(SystemExit, match="deepLink 'halloween' is not a URL"):
            events.update("EV1", path, dry_run=dry_run)


def test_create_refuses_a_spec_whose_locale_breaks_a_cap(tmp_path) -> None:
    spec = {**_spec(), "localizations": {"de-DE": {"name": "x" * 31, "shortDescription": "s", "longDescription": "l"}}}
    path = tmp_path / "event.json"
    path.write_text(json.dumps(spec))
    with pytest.raises(SystemExit, match="de-DE: name: 31/30"):
        events.create(path, tmp_path, dry_run=True)


# --------------------------------------------------------------------------- #
# The live loop, against a recorded fake (no key, no network)
# --------------------------------------------------------------------------- #

FR = {"name": "Halloween dans le repaire", "shortDescription": "s", "longDescription": "l"}
DE = {"name": "Halloween im Versteck", "shortDescription": "s", "longDescription": "l"}


class FakeASC:
    """Stands in for App Store Connect: records every request in order, answers each POST
    with an id, fails the localization POST for `fail_locale`, and lists `existing` as the
    event's localizations."""

    def __init__(self, fail_locale: str | None = None, existing: tuple[str, ...] = ()) -> None:
        self.fail_locale, self.existing = fail_locale, existing
        self.sent: list[tuple[str, str, dict | None]] = []
        self.uploads: list[tuple[str, str, str]] = []

    def call(self, method: str, path: str, **kw) -> dict:
        body = kw.get("json")
        self.sent.append((method, path, body))
        if (method, path) == ("POST", "/v1/appEvents"):
            return {"data": {"id": "EV1", "attributes": {"eventState": "DRAFT"}}}
        if (method, path) == ("POST", "/v1/appEventLocalizations"):
            locale = body["data"]["attributes"]["locale"]
            if locale == self.fail_locale:
                return {"_error": 409, "_body": "ENTITY_ERROR"}
            return {"data": {"id": "L-" + locale}}
        if method == "GET":
            return {"data": {"attributes": {"eventState": "DRAFT"}}}
        if method == "PATCH" and path.startswith("/v1/appEvents/"):
            return {"data": {"attributes": body["data"]["attributes"]}}
        if method == "PATCH" and path.startswith("/v1/appEventLocalizations/"):
            return {"data": {"attributes": body["data"]["attributes"]}}
        raise AssertionError(f"unexpected {method} {path}")

    def paginate(self, path: str):
        self.sent.append(("LIST", path, None))
        if path.startswith("/v1/territories"):
            return iter([{"id": "USA"}, {"id": "IRL"}])
        if path.startswith("/v1/appEvents/") and "/localizations" in path:
            return iter([{"id": "L-" + loc, "attributes": {"locale": loc}} for loc in self.existing])
        raise AssertionError(f"unexpected list {path}")

    def upload(self, event_id: str, locale: str, loc_id: str, _art_dir: Path) -> None:
        self.uploads.append((event_id, locale, loc_id))

    def event_posts(self) -> int:
        return sum((m, p) == ("POST", "/v1/appEvents") for m, p, _ in self.sent)

    def localization_posts(self) -> list[tuple[str, str]]:
        """(locale, event id) per localization POST, in order."""
        return [(b["data"]["attributes"]["locale"], b["data"]["relationships"]["appEvent"]["data"]["id"])
                for m, p, b in self.sent if (m, p) == ("POST", "/v1/appEventLocalizations")]


@pytest.fixture
def live(tmp_path, monkeypatch):
    """Install a FakeASC over call/paginate/upload_media; returns (fake, spec path).
    The spec lists de-DE and fr-FR before en-US, so primary-first is the code's doing."""
    for name in (events.CARD_FILE, events.DETAILS_FILE):
        (tmp_path / name).write_bytes(b"\xff\xd8\xff\xd9")
    spec_path = tmp_path / "event.json"
    spec_path.write_text(json.dumps({**_spec(), "localizations": {"de-DE": DE, "fr-FR": FR, "en-US": _spec()["copy"]}}))

    def install(**kw) -> tuple[FakeASC, Path]:
        fake = FakeASC(**kw)
        monkeypatch.setattr(events, "call", fake.call)
        monkeypatch.setattr(events, "paginate", fake.paginate)
        monkeypatch.setattr(events, "upload_media", fake.upload)
        return fake, spec_path
    return install


def test_create_posts_the_event_then_the_primary_locale_first(tmp_path, live) -> None:
    fake, spec_path = live()
    assert events.create(spec_path, tmp_path, dry_run=False) == 0
    posts = [p for m, p, _ in fake.sent if m == "POST"]
    assert posts[:2] == ["/v1/appEvents", "/v1/appEventLocalizations"]
    assert fake.localization_posts()[0] == ("en-US", "EV1")


def test_create_posts_one_localization_per_locale_each_carrying_the_event_id(tmp_path, live) -> None:
    fake, spec_path = live()
    events.create(spec_path, tmp_path, dry_run=False)
    assert fake.event_posts() == 1
    assert fake.localization_posts() == [("en-US", "EV1"), ("de-DE", "EV1"), ("fr-FR", "EV1")]
    assert fake.uploads == [("EV1", "en-US", "L-en-US"), ("EV1", "de-DE", "L-de-DE"), ("EV1", "fr-FR", "L-fr-FR")]


def test_a_failing_locale_stops_the_loop_and_names_the_draft_and_its_resume(tmp_path, live) -> None:
    fake, spec_path = live(fail_locale="fr-FR")
    with pytest.raises(SystemExit) as exc:
        events.create(spec_path, tmp_path, dry_run=False)
    msg = str(exc.value)
    assert [loc for loc, _ in fake.localization_posts()] == ["en-US", "de-DE", "fr-FR"]   # fr-FR is the one refused
    assert [loc for _, loc, _ in fake.uploads] == ["en-US", "de-DE"]                       # N-1 created, art and all
    assert "create localization fr-FR of event EV1" in msg
    assert "event EV1 exists as a DRAFT" in msg and "delete it in App Store Connect" in msg
    assert f"events.py create --spec {spec_path} --art-dir {tmp_path} --event EV1" in msg
    assert ("GET", "/v1/appEvents/EV1", None) not in fake.sent                             # the loop stopped there


def test_create_resume_skips_existing_locales_and_creates_only_the_missing(tmp_path, live, capsys) -> None:
    fake, spec_path = live(existing=("en-US", "de-DE"))
    assert events.create(spec_path, tmp_path, dry_run=False, event_id="EV7") == 0
    assert fake.event_posts() == 0
    assert not any(p.startswith("/v1/territories") for _, p, _ in fake.sent)   # no event to build, no territories
    assert ("LIST", "/v1/appEvents/EV7/localizations?limit=50", None) in fake.sent
    assert fake.localization_posts() == [("fr-FR", "EV7")]
    assert fake.uploads == [("EV7", "fr-FR", "L-fr-FR")]
    out = capsys.readouterr().out
    assert "en-US: exists (L-en-US), skipped; its art is NOT checked" in out
    assert "de-DE: exists (L-de-DE), skipped" in out


def test_a_failure_that_is_not_a_bail_still_names_the_draft(tmp_path, live, capsys, monkeypatch) -> None:
    _, spec_path = live()

    def listing_down(path: str):
        raise RuntimeError(f"GET {path} -> 500")
    monkeypatch.setattr(events, "paginate", listing_down)
    with pytest.raises(RuntimeError, match="500"):
        events.create(spec_path, tmp_path, dry_run=False, event_id="EV7")
    assert "event EV7 exists as a DRAFT" in capsys.readouterr().err


def test_upload_media_bails_on_a_put_timeout_naming_the_locale_and_event(tmp_path, monkeypatch) -> None:
    """The byte PUT goes straight to `requests`; a timeout there bails like `call`'s errors.
    A fake `requests` module stands in, so the test needs neither the package nor a network."""
    (tmp_path / events.CARD_FILE).write_bytes(b"card")
    (tmp_path / events.DETAILS_FILE).write_bytes(b"details")
    reserved = {"data": {"id": "S1", "attributes": {"uploadOperations": [
        {"method": "PUT", "url": "https://upload.example/1", "offset": 0, "length": 4, "requestHeaders": []}]}}}
    monkeypatch.setattr(events, "call", lambda *_a, **_k: reserved)
    fake_requests = types.ModuleType("requests")
    fake_requests.RequestException = type("RequestException", (Exception,), {})

    def timed_out(*_a, **_k):
        raise fake_requests.RequestException("read timed out (300 s)")
    fake_requests.request = timed_out
    monkeypatch.setitem(sys.modules, "requests", fake_requests)
    with pytest.raises(SystemExit) as exc:
        events.upload_media("EV1", "de-DE", "L-de-DE", tmp_path)
    msg = str(exc.value)
    assert "upload bytes EVENT_CARD for de-DE of event EV1" in msg
    assert '"_error": "transport"' in msg and "read timed out" in msg


# --------------------------------------------------------------------------- #
# Event video: one media per slot, a video when there is one (Apple: "Consider
# using video"), spec-checked before a byte is sent
# --------------------------------------------------------------------------- #


def _probe(w: int = 1920, h: int = 1080, fps: str = "30/1", size: int = 24_000_000,
           audio: list[dict] | None = None) -> dict:
    """An ffprobe -show_streams -show_format JSON, trimmed to the fields the check reads."""
    streams = [{"codec_type": "video", "codec_name": "h264", "width": w, "height": h, "r_frame_rate": fps}]
    streams += [{"codec_type": "audio", **a} for a in audio or []]
    return {"streams": streams, "format": {"size": str(size), "duration": "20.500000"}}


STEREO_AAC = {"codec_name": "aac", "channels": 2, "sample_rate": "48000"}


def test_event_media_takes_a_video_per_slot_and_falls_back_to_the_still() -> None:
    names = {events.CARD_VIDEO, events.CARD_FILE, events.DETAILS_FILE, "event-card-1920x1080-guides.png"}
    assert events.event_media(names) == [
        (events.CARD_VIDEO, "EVENT_CARD", "video"),
        (events.DETAILS_FILE, "EVENT_DETAILS_PAGE", "image"),
    ]
    assert [kind for *_, kind in events.event_media({events.CARD_FILE, events.DETAILS_FILE})] == ["image", "image"]


def test_event_media_names_a_slot_with_nothing_to_upload() -> None:
    with pytest.raises(SystemExit, match=f"EVENT_DETAILS_PAGE: no {events.DETAILS_VIDEO} or {events.DETAILS_FILE}"):
        events.event_media({events.CARD_VIDEO})


@pytest.mark.parametrize(("w", "h", "fps", "slot"), [
    (1920, 1080, "30/1", "EVENT_CARD"), (3840, 2160, "60/1", "EVENT_CARD"),
    (1080, 1920, "30/1", "EVENT_DETAILS_PAGE"), (2160, 3840, "60/1", "EVENT_DETAILS_PAGE"),
])
def test_video_problems_passes_apples_table(w, h, fps, slot) -> None:
    """developer.apple.com/help/app-store-connect/reference/in-app-event-media-and-audio-specifications:
    card 16:9 and details 9:16, from 1920x1080 / 1080x1920 up to 4K, 30 or 60 fps, 500 MB."""
    assert events.video_problems(_probe(w, h, fps), slot) == []


def test_video_problems_names_every_break() -> None:
    small = events.video_problems(_probe(1280, 720, "25/1", 600_000_000), "EVENT_CARD")
    assert any("1280x720" in p for p in small)
    assert any("25 fps" in p for p in small)
    assert any("500 MB" in p for p in small)
    assert any("9:16" in p for p in events.video_problems(_probe(1920, 1080), "EVENT_DETAILS_PAGE"))
    assert any("16:9" in p for p in events.video_problems(_probe(2000, 1080), "EVENT_CARD"))
    assert any("29.97 fps" in p for p in events.video_problems(_probe(fps="30000/1001"), "EVENT_CARD"))
    no_video = {"streams": [], "format": {"size": "10"}}
    assert events.video_problems(no_video, "EVENT_CARD") == ["0 video streams, expected 1"]


def test_video_problems_takes_silence_or_stereo_only() -> None:
    assert events.video_problems(_probe(audio=[STEREO_AAC]), "EVENT_CARD") == []
    assert events.video_problems(_probe(audio=[{**STEREO_AAC, "channels": 1}] * 2), "EVENT_CARD") == []  # L + R tracks
    mono = events.video_problems(_probe(audio=[{**STEREO_AAC, "channels": 1}]), "EVENT_CARD")
    assert mono == ["audio channels [1]: one stereo track, or two mono tracks (L, R)"]
    slow = events.video_problems(_probe(audio=[{**STEREO_AAC, "sample_rate": "22050"}]), "EVENT_CARD")
    assert slow == ["audio at 22050 Hz, expected 44.1 or 48 kHz"]
    pcm = {"codec_name": "pcm_s16le", "channels": 2, "sample_rate": "48000"}
    assert events.video_problems(_probe(audio=[pcm]), "EVENT_CARD") == ["audio codec pcm_s16le: EVENT_CARD takes AAC"]
    assert events.video_problems(_probe(1080, 1920, audio=[pcm]), "EVENT_DETAILS_PAGE") == []


def test_reserve_payload_targets_the_resource_for_the_kind() -> None:
    shot = events.reserve_payload("image", events.CARD_FILE, 10, "EVENT_CARD", "L1")
    clip = events.reserve_payload("video", events.CARD_VIDEO, 20, "EVENT_CARD", "L1")
    assert (shot["data"]["type"], clip["data"]["type"]) == ("appEventScreenshots", "appEventVideoClips")
    assert clip["data"]["attributes"] == {"fileName": events.CARD_VIDEO, "fileSize": 20, "appEventAssetType": "EVENT_CARD"}
    for body in (shot, clip):
        assert body["data"]["relationships"]["appEventLocalization"]["data"] == {"type": "appEventLocalizations", "id": "L1"}
    # No previewFrameTimeCode: Apple publishes no format for it, so the poster frame is Apple's
    # default, editable in App Store Connect.


def test_create_refuses_a_video_that_breaks_the_spec_before_sending(tmp_path, monkeypatch) -> None:
    def no_network(*_a, **_k):
        raise AssertionError("a bad video must stop the run before App Store Connect")
    for name in ("call", "paginate", "upload_media"):
        monkeypatch.setattr(events, name, no_network)
    monkeypatch.setattr(events, "probe", lambda path: _probe(1280, 720) if path.name == events.CARD_VIDEO else _probe(1080, 1920))
    for name in (events.CARD_VIDEO, events.DETAILS_VIDEO):
        (tmp_path / name).write_bytes(b"\x00")
    spec_path = Path(__file__).resolve().parents[2] / "fastlane/events/halloween/event.json"
    with pytest.raises(SystemExit, match=f"{events.CARD_VIDEO}: 1280x720"):
        events.create(spec_path, tmp_path, dry_run=False)


def test_create_dry_run_names_the_videos_it_would_upload(tmp_path, capsys, monkeypatch) -> None:
    def no_network(*_a, **_k):
        raise AssertionError("a dry run must not call App Store Connect")
    for name in ("call", "paginate", "upload_media"):
        monkeypatch.setattr(events, name, no_network)
    monkeypatch.setattr(events, "probe", lambda path: _probe(1920, 1080) if "card" in path.name else _probe(1080, 1920))
    for name in (events.CARD_VIDEO, events.DETAILS_VIDEO, events.CARD_FILE, events.DETAILS_FILE):
        (tmp_path / name).write_bytes(b"\x00")
    spec_path = Path(__file__).resolve().parents[2] / "fastlane/events/halloween/event.json"
    assert events.create(spec_path, tmp_path, dry_run=True) == 0
    out = capsys.readouterr().out
    assert f"{events.CARD_VIDEO} (EVENT_CARD video)" in out
    assert f"{events.DETAILS_VIDEO} (EVENT_DETAILS_PAGE video)" in out
    assert "1920x1080 30 fps 20.5 s" in out          # the checked spec, said out loud


def test_video_problems_reads_the_average_rate_too() -> None:
    """r_frame_rate is ffmpeg's guess at the base rate; a variable-rate file shows in avg_frame_rate."""
    vfr = _probe()
    vfr["streams"][0]["avg_frame_rate"] = "2400/97"
    assert events.video_problems(vfr, "EVENT_CARD") == ["average 24.74 fps, expected 30 or 60"]


def test_checked_media_refuses_a_missing_or_file_art_dir(tmp_path) -> None:
    with pytest.raises(SystemExit, match="art dir not found: .*nowhere"):
        events.checked_media(tmp_path / "nowhere")
    (tmp_path / "a-file").write_text("x")
    with pytest.raises(SystemExit, match="art dir not found"):
        events.checked_media(tmp_path / "a-file")


def test_checked_media_ignores_a_broken_symlink_and_names_the_dir(tmp_path) -> None:
    """A dangling event-card-1920x1080.jpg used to pass pre-flight, then die mid-run after the
    DRAFT existed. Only real files count, and the refusal says which directory it read."""
    (tmp_path / events.CARD_FILE).symlink_to(tmp_path / "gone.jpg")
    (tmp_path / events.DETAILS_FILE).write_bytes(b"\xff\xd8\xff\xd9")
    with pytest.raises(SystemExit, match=f"EVENT_CARD: no {events.CARD_VIDEO} or {events.CARD_FILE} in {tmp_path}"):
        events.checked_media(tmp_path)


def test_checked_media_reads_the_size_off_the_file_not_ffprobe(tmp_path, monkeypatch) -> None:
    """ffprobe's format.size may be absent; the bytes that go up are the file's."""
    (tmp_path / events.CARD_VIDEO).write_bytes(b"\x00" * 64)
    (tmp_path / events.DETAILS_FILE).write_bytes(b"\xff\xd8\xff\xd9")
    monkeypatch.setattr(events, "MAX_MEDIA_BYTES", 32)
    info = _probe()
    del info["format"]["size"]
    monkeypatch.setattr(events, "probe", lambda _p: info)
    with pytest.raises(SystemExit, match="64 bytes, over 500 MB"):
        events.checked_media(tmp_path)


class RecordingASC:
    """The reserve → PUT → commit dance for one video slot and one still slot."""

    def __init__(self, commit_state: str = "UPLOAD_COMPLETE") -> None:
        self.commit_state = commit_state
        self.sent: list[tuple[str, str, dict | None]] = []

    def call(self, method: str, path: str, **kw) -> dict:
        body = kw.get("json")
        self.sent.append((method, path, body))
        if method == "POST":
            kind = body["data"]["type"]
            return {"data": {"id": f"{kind}-1", "attributes": {"uploadOperations": [
                {"method": "PUT", "url": "https://upload.example/1", "offset": 0, "length": 3, "requestHeaders": []}]}}}
        if path.startswith("/v1/appEventVideoClips/"):
            return {"data": {"attributes": {"videoDeliveryState": {"state": self.commit_state}}}}
        return {"data": {"attributes": {"assetDeliveryState": {"state": "COMPLETE"}}}}


def test_upload_media_sends_video_to_the_clip_resource_and_reads_its_state(tmp_path, monkeypatch, capsys) -> None:
    (tmp_path / events.CARD_VIDEO).write_bytes(b"mp4")
    (tmp_path / events.DETAILS_FILE).write_bytes(b"jpg")
    fake = RecordingASC()
    monkeypatch.setattr(events, "call", fake.call)
    monkeypatch.setattr(events, "put_bytes", lambda _op, _blob: None)
    events.upload_media("EV1", "en-US", "L1", tmp_path)
    assert [(m, p) for m, p, _ in fake.sent] == [
        ("POST", "/v1/appEventVideoClips"), ("PATCH", "/v1/appEventVideoClips/appEventVideoClips-1"),
        ("POST", "/v1/appEventScreenshots"), ("PATCH", "/v1/appEventScreenshots/appEventScreenshots-1")]
    commit = fake.sent[1][2]["data"]
    assert (commit["type"], commit["attributes"]) == ("appEventVideoClips", {"uploaded": True})
    out = capsys.readouterr().out
    assert "en-US EVENT_CARD: video uploaded (3 bytes) -> UPLOAD_COMPLETE" in out
    assert "en-US EVENT_DETAILS_PAGE: image uploaded (3 bytes) -> COMPLETE" in out


def test_upload_media_bails_when_a_clip_commit_reports_failed(tmp_path, monkeypatch) -> None:
    (tmp_path / events.CARD_VIDEO).write_bytes(b"mp4")
    (tmp_path / events.DETAILS_FILE).write_bytes(b"jpg")
    monkeypatch.setattr(events, "call", RecordingASC(commit_state="FAILED").call)
    monkeypatch.setattr(events, "put_bytes", lambda _op, _blob: None)
    with pytest.raises(SystemExit, match="commit EVENT_CARD for en-US of event EV1"):
        events.upload_media("EV1", "en-US", "L1", tmp_path)


def test_probe_refuses_without_ffprobe_and_on_a_failed_read(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(events.shutil, "which", lambda _name: None)
    with pytest.raises(SystemExit, match="ffprobe not found"):
        events.probe(tmp_path / "x.mp4")
    monkeypatch.setattr(events.shutil, "which", lambda _name: "/usr/bin/ffprobe")
    failed = types.SimpleNamespace(returncode=1, stdout="", stderr="x.mp4: Invalid data found")
    monkeypatch.setattr(events.subprocess, "run", lambda *_a, **_k: failed)
    with pytest.raises(SystemExit, match="ffprobe x.mp4: x.mp4: Invalid data found"):
        events.probe(tmp_path / "x.mp4")


def test_create_says_clips_process_after_upload(tmp_path, live, capsys, monkeypatch) -> None:
    """Video processing is asynchronous: a clip that fails after the commit only shows in ASC."""
    fake, spec_path = live()
    (tmp_path / events.CARD_VIDEO).write_bytes(b"\x00")
    monkeypatch.setattr(events, "probe", lambda _p: _probe())
    assert events.create(spec_path, tmp_path, dry_run=False) == 0
    assert "video clips process after upload" in capsys.readouterr().out


def test_update_sets_the_deep_link_and_creates_a_missing_locale_without_media(live, capsys) -> None:
    """The live draft's catch-up order rests on this: `update` PATCHes the event (deep link and
    all) and every existing locale, but a locale it lacks is POSTed with NO media, so the
    README runs `create --event` (missing locales, video and all) first."""
    fake, spec_path = live(existing=("en-US", "de-DE"))
    assert events.update("EV7", spec_path, dry_run=False) == 0
    event_patches = [b for m, path, b in fake.sent if (m, path) == ("PATCH", "/v1/appEvents/EV7")]
    assert len(event_patches) == 1
    assert event_patches[0]["data"]["attributes"]["deepLink"] == "m1k3://event/waking-up"
    patched = {path for m, path, _ in fake.sent if m == "PATCH" and "/appEventLocalizations/" in path}
    assert patched == {"/v1/appEventLocalizations/L-en-US", "/v1/appEventLocalizations/L-de-DE"}
    assert fake.localization_posts() == [("fr-FR", "EV7")]
    assert fake.uploads == []
    assert "fr-FR: created (no art yet" in capsys.readouterr().out
