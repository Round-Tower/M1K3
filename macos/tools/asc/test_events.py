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
        "eventEnd": "2026-10-16T21:00:00Z",
        "copy": {"name": "Waking Up", "shortDescription": "short", "longDescription": "long"},
    }


def test_copy_problems_reports_each_cap_and_empties() -> None:
    assert events.copy_problems({"name": "x" * 31, "shortDescription": "ok", "longDescription": ""}) == [
        "name: 31/30", "longDescription: empty"]
    assert events.copy_problems({"name": "Waking Up", "shortDescription": "s", "longDescription": "l"}) == []


def test_event_payload_shape_and_optional_deep_link() -> None:
    p = events.event_payload(_spec(), ["USA", "IRL"])
    a = p["data"]["attributes"]
    assert p["data"]["relationships"]["app"]["data"]["id"] == asc.APP_ID
    assert a["territorySchedules"][0]["territories"] == ["USA", "IRL"]
    assert a["purchaseRequirement"] == "NO_COST_ASSOCIATED" and a["priority"] == "HIGH"
    assert "deepLink" not in a  # the app has no URL scheme; the field is optional
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
    lp = events.localization_patch("L1", {"name": "n", "shortDescription": "s", "longDescription": "l", "x": 1})
    assert lp["data"]["id"] == "L1" and set(lp["data"]["attributes"]) == {"name", "shortDescription", "longDescription"}


def test_localization_problems_prefixes_the_locale() -> None:
    spec = {"localizations": {"de-DE": {"name": "ok", "shortDescription": "s" * 51, "longDescription": "l"}}}
    assert events.localization_problems(spec) == ["de-DE: shortDescription: 51/50"]


EVENT_SPECS = sorted((Path(__file__).resolve().parents[2] / "fastlane/events").glob("*/event.json"))
LOCALES = {"en-US", "de-DE", "es-ES", "fr-FR", "ja", "ko", "pt-BR", "zh-Hans"}


def _when(stamp: str) -> datetime:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def test_both_shipped_specs_are_found() -> None:
    assert {p.parent.name for p in EVENT_SPECS} >= {"waking-up", "halloween"}


@pytest.mark.parametrize("path", EVENT_SPECS, ids=lambda p: p.parent.name)
def test_every_event_spec_is_within_apples_rules(path: Path) -> None:
    """Caps, the eight store locales, Apple's enums, and the schedule limits from
    developer.apple.com/help/app-store-connect/offer-in-app-events/offer-in-app-events:
    publish at most 14 days before the start; an event runs 15 minutes to 31 days."""
    spec = json.loads(path.read_text())
    assert events.copy_problems(spec["copy"]) == []
    assert events.localization_problems(spec) == []
    assert set(spec["localizations"]) == LOCALES
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
    for name in ("call", "paginate", "upload_screenshots"):
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
    """Install a FakeASC over call/paginate/upload_screenshots; returns (fake, spec path).
    The spec lists de-DE and fr-FR before en-US, so primary-first is the code's doing."""
    for name in (events.CARD_FILE, events.DETAILS_FILE):
        (tmp_path / name).write_bytes(b"\xff\xd8\xff\xd9")
    spec_path = tmp_path / "event.json"
    spec_path.write_text(json.dumps({**_spec(), "localizations": {"de-DE": DE, "fr-FR": FR, "en-US": _spec()["copy"]}}))

    def install(**kw) -> tuple[FakeASC, Path]:
        fake = FakeASC(**kw)
        monkeypatch.setattr(events, "call", fake.call)
        monkeypatch.setattr(events, "paginate", fake.paginate)
        monkeypatch.setattr(events, "upload_screenshots", fake.upload)
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


def test_upload_screenshots_bails_on_a_put_timeout_naming_the_locale_and_event(tmp_path, monkeypatch) -> None:
    """The byte PUT goes straight to `requests`; a timeout there bails like `call`'s errors.
    A fake `requests` module stands in, so the test needs neither the package nor a network."""
    (tmp_path / events.CARD_FILE).write_bytes(b"card")
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
        events.upload_screenshots("EV1", "de-DE", "L-de-DE", tmp_path)
    msg = str(exc.value)
    assert "upload bytes EVENT_CARD for de-DE of event EV1" in msg
    assert '"_error": "transport"' in msg and "read timed out" in msg
