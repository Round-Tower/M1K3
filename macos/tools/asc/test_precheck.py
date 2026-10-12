"""Pins for the pure half of precheck.py (no key, no network)."""
from __future__ import annotations

import precheck


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


def test_check_localization_requires_whats_new_after_the_first_version() -> None:
    # 2026-10-12: Mac 1.1.0 read PASS with What's New empty in all ten locales; Apple refuses that at send.
    ok = {"locale": "de-DE", "keywords": "assistant", "promotionalText": "p",
          "supportUrl": "https://m1k3.app/support", "description": "d"}
    assert precheck.check_localization("MAC_OS", {**ok, "whatsNew": " "}, needs_whats_new=True) == [
        ("FAIL", "de-DE: empty What's New (required after a platform's first version)")]
    assert precheck.check_localization("MAC_OS", {**ok, "whatsNew": "w" * 4001}, needs_whats_new=True) == [
        ("FAIL", "de-DE: What's New 4001/4000")]
    assert precheck.check_localization("MAC_OS", {**ok, "whatsNew": "NEW IN 1.1"}, needs_whats_new=True) == []
    # The cap reads the raw text: exactly 4000 passes, 4000 plus a trailing newline does not.
    assert precheck.check_localization("MAC_OS", {**ok, "whatsNew": "w" * 4000}, needs_whats_new=True) == []
    assert precheck.check_localization("MAC_OS", {**ok, "whatsNew": "w" * 4000 + "\n"}, needs_whats_new=True) == [
        ("FAIL", "de-DE: What's New 4001/4000")]
    # A platform's first version has no What's New field to fill (fastlane skips it too).
    assert precheck.check_localization("IOS", ok, needs_whats_new=False) == []


def test_whats_new_rule_reads_a_failed_count_as_a_note() -> None:
    assert precheck.whats_new_rule(lambda: 2) == (True, None)
    assert precheck.whats_new_rule(lambda: 1) == (False, None)

    def boom() -> int:
        raise RuntimeError("GET /v1/apps/x/appStoreVersions: 503")

    assert precheck.whats_new_rule(boom) == (
        False, ("NOTE", "version count unreadable (GET /v1/apps/x/appStoreVersions: 503); What's New unchecked"))
