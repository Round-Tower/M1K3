"""Pins for the pure half of events.py (no key, no network)."""
from __future__ import annotations

import json
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


def test_the_waking_up_spec_is_within_every_cap() -> None:
    spec = json.loads((Path(__file__).resolve().parents[2] / "fastlane/events/waking-up/event.json").read_text())
    assert events.copy_problems(spec["copy"]) == []
    assert events.localization_problems(spec) == []
    assert set(spec["localizations"]) == {"en-US", "de-DE", "es-ES", "fr-FR", "ja", "ko", "pt-BR", "zh-Hans"}
