"""Pins for the pure half of events.py (no key, no network)."""
from __future__ import annotations

import json
from datetime import datetime, timedelta
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
    """The app wears the look Oct 24 – Nov 1 (local calendar); the event card says the same."""
    spec = json.loads((Path(__file__).resolve().parents[2] / "fastlane/events/halloween/event.json").read_text())
    assert (spec["referenceName"], spec["badge"], spec["purpose"], spec["priority"]) == (
        "halloween-2026", "SPECIAL_EVENT", "APPROPRIATE_FOR_ALL_USERS", "NORMAL")
    assert _when(spec["eventStart"]).date().isoformat() == "2026-10-24"
    assert _when(spec["eventEnd"]).date().isoformat() == "2026-11-01"
    assert spec["copy"]["name"] == "Halloween in the Lair"


def test_localization_table_puts_the_primary_first_and_falls_back_to_copy() -> None:
    de = {"name": "n", "shortDescription": "s", "longDescription": "l"}
    spec = {**_spec(), "localizations": {"de-DE": de, "en-US": _spec()["copy"]}}
    assert list(events.localization_table(spec)) == ["en-US", "de-DE"]
    assert events.localization_table(_spec()) == {"en-US": _spec()["copy"]}
    assert events.localization_table({**_spec(), "localizations": {"de-DE": de}}) == {"en-US": _spec()["copy"], "de-DE": de}


def test_create_dry_run_builds_every_localization_and_sends_nothing(tmp_path, capsys, monkeypatch) -> None:
    def no_network(*_a, **_k):
        raise AssertionError("a dry run must not call App Store Connect")
    monkeypatch.setattr(events, "call", no_network)
    monkeypatch.setattr(events, "paginate", no_network)
    for name in (events.CARD_FILE, events.DETAILS_FILE):
        (tmp_path / name).write_bytes(b"\xff\xd8\xff\xd9")
    spec_path = Path(__file__).resolve().parents[2] / "fastlane/events/halloween/event.json"
    assert events.create(spec_path, tmp_path, dry_run=True) == 0
    out = capsys.readouterr().out
    for locale in LOCALES:
        assert f'"locale": "{locale}"' in out, locale
    assert out.index('"locale": "en-US"') < out.index('"locale": "de-DE"')   # the primary goes first
    assert out.rstrip().endswith("dry run: nothing sent")


def test_create_refuses_a_spec_whose_locale_breaks_a_cap(tmp_path) -> None:
    spec = {**_spec(), "localizations": {"de-DE": {"name": "x" * 31, "shortDescription": "s", "longDescription": "l"}}}
    path = tmp_path / "event.json"
    path.write_text(json.dumps(spec))
    with pytest.raises(SystemExit, match="de-DE: name: 31/30"):
        events.create(path, tmp_path, dry_run=True)
