"""Pins for the "truth in copy" pass: site/privacy.html and the store descriptions name EVERY download.

The in-app copy is made from NetworkCrossings.swift (tested in Swift); the site and the store text are
hand-written, so this keeps them honest against that same file: every host a download touches appears
on the privacy page, the Kokoro line no longer says ONNX, and the short answer matches its JSON-LD twin.

Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8 (text tripwires over copy). Prior: none (new file).
Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — C2/C3/C4: no page says "nothing to download" unqualified; en-GB mirrors en-US. Confidence 0.8.
Review: Kev + claude-opus-5.5, 2026-10-27 — #708: the page names "Send this exchange", its recipient and its
purpose, while NetworkCrossings carries `.fieldReport` (Kev chose Shape A, the bug-report voice). Confidence 0.8.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PRIVACY = (ROOT / "site" / "privacy.html").read_text()
CROSSINGS = (ROOT / "macos" / "Sources" / "M1K3Inference" / "NetworkCrossings.swift").read_text()
MAC_DESC = (ROOT / "macos" / "fastlane" / "metadata_mac" / "en-US" / "description.txt").read_text()
IOS_DESC = (ROOT / "macos" / "fastlane" / "metadata_ios" / "en-US" / "description.txt").read_text()


def _jsonld_answers() -> dict[str, str]:
    out: dict[str, str] = {}
    for block in re.findall(r'<script type="application/ld\+json">\s*(.*?)</script>', PRIVACY, re.S):
        data = json.loads(block)
        for q in data.get("mainEntity", []):
            out[q["name"]] = q["acceptedAnswer"]["text"]
    return out


def _visible(text: str) -> str:
    return re.sub(r"<[^>]+>", "", text)


def test_every_download_host_in_the_crossings_list_is_named_on_the_privacy_page():
    hosts = sorted(set(re.findall(r'"([a-z0-9.-]+\.(?:co|com))"', CROSSINGS)))
    # Set containment, not `"host" in <str>`: CodeQL reads a substring test on a hostname as URL
    # sanitisation (#570 inline). These are copy checks, not sanitisers.
    assert {"huggingface.co", "github.com"} <= set(hosts)
    page = PRIVACY.lower()
    for host in hosts:
        assert host in page or {"huggingface.co": "hugging face", "github.com": "github"}[host] in page, host


def test_the_privacy_page_names_every_kind_of_download():
    page = _visible(PRIVACY)
    for needle in ("semantic memory", "WhisperKit", "M1K3 Voice", "voice-styles", "630 MB", "without Apple Intelligence"):
        assert needle in page, needle
    answers = _jsonld_answers()
    both = answers["Is M1K3 really private?"] + answers["Does M1K3 ever connect to the internet?"]
    for needle in ("semantic memory", "M1K3 Voice", "GitHub", "630 MB"):
        assert needle in both, needle


def test_kokoro_is_mlx_not_onnx():
    assert "ONNX" not in PRIVACY
    assert "Kokoro neural TTS (MLX-Swift on Metal)" in PRIVACY


def test_the_short_answer_and_its_json_ld_twin_share_the_downloads_clause_byte_for_byte():
    clause = "one-time model downloads when you ask for them (brains, semantic memory, sharper speech recognition and the M1K3 Voice, from Hugging Face, plus one voice-styles file from GitHub), web search,"
    short = _visible(re.search(r'<div class="answer">(.*?)</div>', PRIVACY, re.S).group(1))
    assert clause in short
    assert clause in _jsonld_answers()["Is M1K3 really private?"]


def test_no_stale_hugging_face_only_or_nothing_to_download_claims():
    page = _visible(PRIVACY)
    assert "only when you opt into the Lil or Big brain" not in page
    assert "Hugging Face only" not in page and "huggingface.co only" not in page
    # The offline FAQ no longer says the default Mini needs "nothing to download" unconditionally.
    assert "The default Mini brain works with nothing to download;" not in page


def test_store_descriptions_name_brains_voice_and_speech_downloads():
    assert "downloading models when you ask (brains, speech and voice)" in MAC_DESC
    assert "downloading a brain when you ask" not in MAC_DESC
    assert "downloading models when you choose them (brains and my voice)" in IOS_DESC
    assert "downloading a brain when you choose one" not in IOS_DESC
    assert "Beyond the models you ask me to download" in MAC_DESC
    assert "apart from the models you ask me to download" in IOS_DESC


def test_the_entitlements_comment_no_longer_claims_weights_are_the_only_reason():
    ent = (ROOT / "macos" / "M1K3App" / "M1K3.entitlements").read_text()
    assert "the ONLY reason" not in ent
    assert "voices-v1.0.bin" in ent and re.search(r"\bgithub\.com\b", ent)


def test_no_page_claims_nothing_to_download_without_the_apple_intelligence_qualifier():
    """Mini needs Apple Intelligence to be instant; on a Mac without it, a ~630 MB brain downloads (C2/C3)."""
    claim = re.compile(r"(nothing to download|no download)", re.I)
    pages = sorted((ROOT / "site").glob("*.html")) + sorted((ROOT / "site").glob("*.txt"))
    pages = [p for p in pages if p.name != "llms-full.txt"]  # generated from the pages below
    for page in pages:
        text = page.read_text()
        for m in claim.finditer(text):
            window = text[max(0, m.start() - 400): m.end() + 200]
            assert re.search(r"Apple Intelligence|without it|on others", window), f"{page.name}: {m.group(0)!r} is unqualified"
    for desc in (ROOT / "macos" / "fastlane").glob("metadata_*/en-*/description.txt"):
        text = desc.read_text()
        assert "instant, no download" not in text, desc


def test_en_gb_descriptions_mirror_the_en_us_privacy_and_mini_lines():
    for platform in ("mac", "ios"):
        us = (ROOT / "macos" / "fastlane" / f"metadata_{platform}" / "en-US" / "description.txt").read_text()
        gb = (ROOT / "macos" / "fastlane" / f"metadata_{platform}" / "en-GB" / "description.txt").read_text()
        for line in us.splitlines():
            if any(k in line for k in ("Beyond the models", "apart from the models", "I use the network", "Three brain tiers")):
                assert line in gb, f"{platform}: en-GB lacks: {line[:60]}"


def test_the_privacy_page_names_the_field_report_its_recipient_and_its_purpose():
    # #708: the one thing Round Tower can ever receive from the app, sent by the user's own mail app after they
    # see the exact text. The in-app list carries it as `.fieldReport`; the page must say the same, and the
    # policy's Email item must not claim a narrower use than the sheet does.
    assert "case fieldReport" in CROSSINGS
    page = _visible(PRIVACY)
    assert "Send this exchange to Round Tower" in page
    assert "your own mail app sends it to hello@round-tower.ie" in page
    assert "the only thing we can ever receive is an exchange you choose to email us" in page
    assert "We use them only to reply and do not add you to any list." not in page
