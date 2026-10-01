"""Pins for check_store_metadata.py's pure helpers."""
from pathlib import Path

from check_store_metadata import LIMITS, problems


def _locale(root: Path, locale: str, **files: str) -> Path:
    d = root / locale
    d.mkdir(parents=True)
    for fname, text in files.items():
        (d / f"{fname}.txt").write_text(text + "\n")
    return d


def test_within_limits_is_clean(tmp_path):
    _locale(tmp_path, "de-DE", name="M1K3 — Lokaler KI-Agent", keywords="a,b", support_url="https://m1k3.app")
    assert problems(tmp_path) == []


def test_counts_characters_not_bytes(tmp_path):
    # 30 CJK characters is 90 UTF-8 bytes — Apple counts characters.
    _locale(tmp_path, "ja", name="あ" * LIMITS["name"], support_url="https://m1k3.app")
    assert problems(tmp_path) == []


def test_trailing_newline_is_not_counted(tmp_path):
    _locale(tmp_path, "ko", keywords="k" * LIMITS["keywords"], support_url="https://m1k3.app")
    assert problems(tmp_path) == []


def test_over_limit_names_file_and_count(tmp_path):
    _locale(tmp_path, "fr-FR", subtitle="x" * 31, support_url="https://m1k3.app")
    [p] = problems(tmp_path)
    assert "fr-FR/subtitle.txt" in p and "31/30" in p


def test_missing_support_url_is_a_problem(tmp_path):
    _locale(tmp_path, "es-ES", name="M1K3")
    [p] = problems(tmp_path)
    assert "es-ES" in p and "support_url" in p


def test_non_locale_folders_are_ignored(tmp_path):
    (tmp_path / "review_information").mkdir()
    (tmp_path / "review_information" / "demo_user.txt").write_text("x" * 5000)
    assert problems(tmp_path) == []


# --- device claims: the iPhone storefront must not be sold the Mac ---------
from check_store_metadata import device_claims, shared_drift  # noqa: E402


def test_ios_description_claiming_the_mac_is_a_problem(tmp_path):
    _locale(tmp_path, "en-US", description="I run entirely on your Mac.", support_url="https://m1k3.app")
    [p] = device_claims(tmp_path, "IOS")
    assert "en-US/description.txt" in p and "Mac" in p


def test_brain_at_home_may_name_the_mac_on_ios(tmp_path):
    # The one honest Mac mention on an iPhone listing: borrowing the Mac's brain.
    _locale(tmp_path, "en-US", description="Brain at Home: use your Mac's big brain from the couch.",
            support_url="https://m1k3.app")
    assert device_claims(tmp_path, "IOS") == []


def test_mac_inside_cjk_text_is_still_caught(tmp_path):
    # Python's \b sees no boundary between 在 and M — the match must not rely on it.
    _locale(tmp_path, "zh-Hans", promotional_text="完全在Mac上运行", support_url="https://m1k3.app")
    assert len(device_claims(tmp_path, "IOS")) == 1


def test_words_that_merely_start_with_mac_are_fine(tmp_path):
    _locale(tmp_path, "en-US", description="Machine learning, no macros.", support_url="https://m1k3.app")
    assert device_claims(tmp_path, "IOS") == []


def test_shared_fields_name_no_device_on_any_platform(tmp_path):
    # Name + subtitle live on the app record, so every storefront reads them.
    _locale(tmp_path, "fr-FR", subtitle="Intelligence punk, sur Mac", support_url="https://m1k3.app")
    _locale(tmp_path, "de-DE", name="M1K3 für iPhone", support_url="https://m1k3.app")
    assert len(device_claims(tmp_path, "MAC_OS")) == 2


def test_the_mac_listing_may_name_the_mac(tmp_path):
    _locale(tmp_path, "en-US", description="Runs entirely on your Mac.", support_url="https://m1k3.app")
    assert device_claims(tmp_path, "MAC_OS") == []


# --- shared drift: one record, one name ------------------------------------

def test_identical_shared_fields_do_not_drift(tmp_path):
    mac, ios = tmp_path / "mac", tmp_path / "ios"
    for root in (mac, ios):
        _locale(root, "en-US", name="Local Offline AI - M1K3", subtitle="x", support_url="https://m1k3.app")
    assert shared_drift({"MAC_OS": mac, "IOS": ios}) == []


def test_differing_names_drift(tmp_path):
    # Whichever lane pushed last would win, and the other storefront flips too.
    mac, ios = tmp_path / "mac", tmp_path / "ios"
    _locale(mac, "en-US", name="M1K3 — Local AI Agent", support_url="https://m1k3.app")
    _locale(ios, "en-US", name="Local Offline AI - M1K3", support_url="https://m1k3.app")
    [p] = shared_drift({"MAC_OS": mac, "IOS": ios})
    assert "en-US" in p and "name" in p


def test_a_shared_field_present_on_one_platform_only_drifts(tmp_path):
    mac, ios = tmp_path / "mac", tmp_path / "ios"
    _locale(mac, "ja", subtitle="ローカル", support_url="https://m1k3.app")
    _locale(ios, "ja", support_url="https://m1k3.app")
    [p] = shared_drift({"MAC_OS": mac, "IOS": ios})
    assert "ja" in p and "subtitle" in p


def test_keywords_name_no_apple_device_on_any_platform(tmp_path):
    # Guideline 5.2.5: App Review flagged "Mac" in the fr/pt subtitles on 2026-09-23;
    # the keyword field is metadata under the same rule.
    _locale(tmp_path, "en-US", keywords="assistant,iPhone,LLM", support_url="https://m1k3.app")
    [p] = device_claims(tmp_path, "MAC_OS")
    assert "keywords.txt" in p and "iPhone" in p


def test_lowercase_device_names_in_keywords_are_caught(tmp_path):
    # Keywords are conventionally lowercase; a case-sensitive guard waved `iphone` through.
    _locale(tmp_path, "en-US", keywords="assistant,iphone,mac", support_url="https://m1k3.app")
    assert len(device_claims(tmp_path, "MAC_OS")) == 1


def test_plural_and_imac_are_mac_claims_on_ios(tmp_path):
    _locale(tmp_path, "en-US", description="Runs on Apple Silicon Macs.\nAnd on your iMac.",
            support_url="https://m1k3.app")
    assert len(device_claims(tmp_path, "IOS")) == 2


def test_a_locale_missing_from_one_platform_says_missing(tmp_path):
    mac, ios = tmp_path / "mac", tmp_path / "ios"
    _locale(mac, "en-GB", name="Local Offline AI Agent – M1K3", support_url="https://m1k3.app")
    (ios).mkdir()
    [p] = shared_drift({"MAC_OS": mac, "IOS": ios})
    assert "IOS=missing" in p


def test_a_mac_claim_before_brain_at_home_on_the_same_line_is_caught(tmp_path):
    # The exemption covers the Brain at Home clause, not the whole line.
    _locale(tmp_path, "en-US", description="Runs entirely on your Mac. Brain at Home: borrow your Mac's brain.",
            support_url="https://m1k3.app")
    assert len(device_claims(tmp_path, "IOS")) == 1


def test_review_notes_in_a_metadata_folder_are_a_problem(tmp_path):
    # 2026-10-01: `fastlane mac metadata` pushed a stale review_information/notes.txt
    # over the live notes (no MCP server, no Brain at Home — the 09-16 rejection).
    # The canonical notes are fastlane/review_notes.txt, applied by review_notes.py.
    (tmp_path / "review_information").mkdir()
    (tmp_path / "review_information" / "notes.txt").write_text("stale")
    [p] = problems(tmp_path)
    assert "review_information/notes.txt" in p


def test_main_checks_the_ios_folder_with_ios_rules(tmp_path, monkeypatch, capsys):
    # Pins the PLATFORM_DIRS wiring: a key typo would silently drop the iPhone check.
    import check_store_metadata as csm
    fastlane = tmp_path / "fastlane"
    _locale(fastlane / "metadata_mac", "en-US", name="M1K3", support_url="https://m1k3.app")
    _locale(fastlane / "metadata_ios", "en-US", name="M1K3", description="Runs on your Mac.",
            support_url="https://m1k3.app")
    monkeypatch.setattr(csm, "FASTLANE_DIR", fastlane)
    monkeypatch.setattr(csm.sys, "argv", ["check_store_metadata.py"])
    assert csm.main() == 1
    assert "metadata_ios/en-US/description.txt" in capsys.readouterr().out
