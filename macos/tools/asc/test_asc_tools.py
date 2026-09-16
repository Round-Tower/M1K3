"""Pins for the pure halves of the ASC tools (no key, no network)."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

import asc
import events
import keywords
import precheck
import review_notes


# --- asc.py -----------------------------------------------------------------


def test_credentials_prefers_the_fastlane_json(tmp_path: Path) -> None:
    (tmp_path / "asc_api_key.json").write_text(json.dumps({"key_id": "K1", "issuer_id": "I1", "key": "PEM"}))
    (tmp_path / "AuthKey_K2.p8").write_text("PEM2")
    assert asc.credentials(tmp_path, {"ASC_KEY_ID": "K2", "ASC_KEY_ISSUER_ID": "I2"}) == ("K1", "I1", "PEM")


def test_credentials_falls_back_to_the_env_pair(tmp_path: Path) -> None:
    (tmp_path / "AuthKey_K2.p8").write_text("PEM2")
    assert asc.credentials(tmp_path, {"ASC_KEY_ID": "K2", "ASC_KEY_ISSUER_ID": "I2"}) == ("K2", "I2", "PEM2")


def test_jwt_claims_shape() -> None:
    assert asc.jwt_claims("iss", 1000) == {"iss": "iss", "iat": 1000, "exp": 1900, "aud": "appstoreconnect-v1"}
    assert asc.jwt_claims("iss", 1000)["exp"] - 1000 <= 1200  # ASC rejects longer tokens


# --- keywords.py ------------------------------------------------------------


@pytest.mark.parametrize("text,hits", [
    ("assistant,GPT,chatbot", ["GPT"]),
    ("chatgpt alternative,private", ["ChatGPT"]),  # the whole mark, once
    ("agi,AGI", ["AGI"]),
    ("assistant,LLM,MLX,private", []),
    ("", []),
    (None, []),
    ("magical,gemination", []),  # inside a word is not the mark
])
def test_trademark_hits(text, hits) -> None:
    assert keywords.trademark_hits(text) == hits


def test_field_report_flags_trademarks_and_caps() -> None:
    lines = keywords.field_report("IOS", "en-US", "keywords", "a,GPT," + "x" * 100, 100)
    assert any("TRADEMARK" in l and "'GPT'" in l for l in lines)
    assert any("OVER-CAP" in l and "/100" in l for l in lines)
    assert keywords.field_report("MAC_OS", "de-DE", "subtitle", "Punk-Intelligenz, auf Gerät", 30) == []


# --- events.py --------------------------------------------------------------


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
    spec = _spec(); spec["copy"]["extra"] = "ignored"
    attrs = events.localization_payload(spec, "E1")["data"]["attributes"]
    assert set(attrs) == {"locale", "name", "shortDescription", "longDescription"}


# --- precheck.py ------------------------------------------------------------


def test_check_build() -> None:
    assert precheck.check_build({}, None) == ("FAIL", "no build attached")
    assert precheck.check_build({}, {"attributes": {"processingState": "VALID", "version": "362"}}) == ("PASS", "build 362 VALID")
    assert precheck.check_build({}, {"attributes": {"processingState": "PROCESSING", "version": "363"}})[0] == "FAIL"


def test_check_screenshots_requires_each_display_type() -> None:
    sets = [{"attributes": {"screenshotDisplayType": "APP_IPHONE_67"}, "_count": 8}]
    rows = precheck.check_screenshots("IOS", sets)
    assert ("PASS", "APP_IPHONE_67: 8 screenshot(s)") in rows
    assert ("FAIL", "APP_IPAD_PRO_3GEN_129: 0 screenshot(s)") in rows


def test_availability_and_price_read_the_404_tell() -> None:
    assert precheck.check_availability({"_error": 404})[0] == "FAIL"
    assert precheck.check_availability({"data": {"attributes": {"availableInNewTerritories": True}}})[0] == "PASS"
    assert precheck.check_prices({"_error": 404})[0] == "FAIL"
    assert precheck.check_prices({"data": [{"id": "p"}]}) == ("PASS", "price schedule: 1 manual price(s)")


def test_check_localization_catches_trademarks_promo_cap_support_url() -> None:
    rows = precheck.check_localization("VISION_OS", {
        "locale": "en-US", "keywords": "assistant,GPT", "promotionalText": "p" * 171,
        "supportUrl": None, "description": "d"})
    statuses = [r[0] for r in rows]
    assert statuses.count("FAIL") == 3
    assert precheck.check_localization("MAC_OS", {
        "locale": "en-US", "keywords": "assistant", "promotionalText": "p", "supportUrl": "https://m1k3.app/support",
        "description": "d"}) == []


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


# --------------------------------------------------------------------------- #
# review_notes.py — App Review Information notes (the network.server rejection, 2026-09-16)
# --------------------------------------------------------------------------- #


def test_review_notes_problems_wants_both_inbound_listeners_named() -> None:
    # the 09-15 notes: outbound "in full", no listener named → the automated
    # entitlement check found network.server with "no matching functionality"
    stale = "NETWORK USAGE — IN FULL\nOutbound network use is limited to the model download."
    assert review_notes.problems(stale) == [
        "notes never mention the MCP server (com.apple.security.network.server)",
        "notes never mention Brain at Home (com.apple.security.network.server)",
    ]
    good = "MCP server on 127.0.0.1:4242 … Brain at Home serves paired devices on the LAN"
    assert review_notes.problems(good) == []


def test_review_notes_problems_reports_the_cap_and_emptiness() -> None:
    assert review_notes.problems("") == ["notes are empty"]
    over = "MCP server Brain at Home " + "x" * review_notes.NOTES_CAP
    assert review_notes.problems(over) == [f"notes over the {review_notes.NOTES_CAP}-char cap ({len(over)})"]


def test_review_notes_patch_payload_shape() -> None:
    payload = review_notes.patch_payload("detail-1", "hello")
    assert payload == {
        "data": {"type": "appStoreReviewDetails", "id": "detail-1", "attributes": {"notes": "hello"}}
    }


def test_the_tracked_review_notes_pass_their_own_check() -> None:
    text = (Path(__file__).resolve().parents[2] / "fastlane" / "review_notes.txt").read_text()
    assert review_notes.problems(text) == []
    # the two listeners the entitlement exists for, by the names the reviewer will see in Settings
    for phrase in ("MCP server", "Brain at Home", "127.0.0.1", "4242", "OFF by default", "network.server"):
        assert phrase in text, phrase


def test_precheck_review_notes_row_uses_the_shared_check() -> None:
    ok = {"data": {"attributes": {"notes": "MCP server … Brain at Home"}}}
    assert precheck.check_review_notes(ok) == ("PASS", "review notes name both inbound listeners")
    status, detail = precheck.check_review_notes({"data": {"attributes": {"notes": "outbound only"}}})
    assert status == "FAIL" and "MCP server" in detail and "Brain at Home" in detail


def test_precheck_review_notes_row_splits_never_set_from_read_failed() -> None:
    # the availability/price convention: a 404 is a real gap, anything else is a NOTE, never a FAIL
    assert precheck.check_review_notes({"_error": 404}) == ("FAIL", "no App Review Information on this version")
    assert precheck.check_review_notes({"_error": 401}) == ("NOTE", "review notes read failed: 401")
    assert precheck.check_review_notes({"_error": "transport"}) == ("NOTE", "review notes read failed: transport")
    assert precheck.check_review_notes({"data": {"attributes": {"notes": ""}}}) == ("FAIL", "notes are empty")
