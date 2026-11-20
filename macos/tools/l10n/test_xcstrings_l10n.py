"""Tests for xcstrings_l10n.py — the pure helpers (serialise, key → source regex,
privacy hint, apply one translation). The file walk is verify-by-run."""
from __future__ import annotations

import json
import os
import re
import sys

import pytest

sys.path.insert(0, os.path.dirname(__file__))
import xcstrings_l10n as l10n

# --------------------------------------------------------------------------- #
# dumps: Xcode's own JSON shape, so a re-sync leaves no diff
# --------------------------------------------------------------------------- #

def test_dumps_matches_xcode_spacing_and_empty_objects():
    catalog = {"sourceLanguage": "en", "strings": {"Hi": {}, "Yo": {"comment": "c"}}, "version": "1.0"}
    text = l10n.dumps(catalog)
    assert text == (
        '{\n  "sourceLanguage" : "en",\n  "strings" : {\n    "Hi" : {\n\n    },\n'
        '    "Yo" : {\n      "comment" : "c"\n    }\n  },\n  "version" : "1.0"\n}\n'
    )


def test_dumps_keeps_non_ascii_unescaped():
    assert "Grüß" in l10n.dumps({"strings": {"Grüß": {}}})


def test_dumps_round_trips_a_real_shape():
    catalog = {"sourceLanguage": "en", "strings": {
        "%@ downloaded": {"comment": "Title", "localizations": {"en": {"stringUnit": {"state": "new", "value": "%@ downloaded"}}}}
    }, "version": "1.0"}
    assert json.loads(l10n.dumps(catalog)) == catalog


# --------------------------------------------------------------------------- #
# source_pattern: find the call site of a key in Swift source
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("key, line", [
    ("Done", 'Button("Done") { dismiss() }'),
    ("%@ is ready", 'String(localized: "\\(name) is ready")'),
    ("Loaded %lld of %lld", 'Text("Loaded \\(done) of \\(total)")'),
    ('"%@" isn\'t a link', 'message = "\\"\\(text)\\" isn\'t a link"'),
    ("50%% done", 'Text("50% done")'),
])
def test_source_pattern_finds_the_literal(key, line):
    assert re.search(l10n.source_pattern(key), line)


def test_source_pattern_does_not_match_a_longer_literal():
    assert not re.search(l10n.source_pattern("Done"), 'Text("Done editing")')


# --------------------------------------------------------------------------- #
# privacy_hint: the lines a native speaker must read (Kev, 2026-11-19, decision 3)
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("text", [
    "Web search is on.",
    "The audio never leaves your Mac.",
    "Private Cloud Compute answers this one.",
    "Your notes stay on this device.",
    "M1K3 sends the question to DuckDuckGo.",
])
def test_privacy_hint_flags_egress_copy(text):
    assert l10n.privacy_hint(text)


@pytest.mark.parametrize("text", ["Done", "Rename chat", "Lil is thinking…"])
def test_privacy_hint_leaves_plain_ui_alone(text):
    assert not l10n.privacy_hint(text)


# --------------------------------------------------------------------------- #
# apply_one: write a translation into an entry, refusing a bad one
# --------------------------------------------------------------------------- #

def test_apply_one_writes_a_translated_string_unit():
    entry: dict = {}
    l10n.apply_one(entry, "Rename chat", "de", {"value": "Chat umbenennen"}, review=False)
    assert entry["localizations"]["de"] == {"stringUnit": {"state": "translated", "value": "Chat umbenennen"}}


def test_apply_one_marks_privacy_copy_needs_review():
    entry: dict = {}
    l10n.apply_one(entry, "Web search is on.", "fr", {"value": "La recherche web est activée."}, review=True)
    assert entry["localizations"]["fr"]["stringUnit"]["state"] == "needs_review"


def test_apply_one_keeps_locales_sorted_and_english_untouched():
    entry = {"localizations": {"en": {"stringUnit": {"state": "new", "value": "%@ %@"}}}}
    l10n.apply_one(entry, "%@ %@", "pt-BR", {"value": "%1$@ %2$@"}, review=False)
    l10n.apply_one(entry, "%@ %@", "de", {"value": "%1$@ %2$@"}, review=False)
    assert list(entry["localizations"]) == ["de", "en", "pt-BR"]
    assert entry["localizations"]["en"]["stringUnit"]["value"] == "%@ %@"


def test_apply_one_writes_plural_variations():
    entry: dict = {}
    l10n.apply_one(entry, "%lld documents", "de",
                   {"plural": {"one": "%lld Dokument", "other": "%lld Dokumente"}}, review=False)
    plural = entry["localizations"]["de"]["variations"]["plural"]
    assert plural["one"]["stringUnit"] == {"state": "translated", "value": "%lld Dokument"}
    assert plural["other"]["stringUnit"]["value"] == "%lld Dokumente"


def test_apply_one_refuses_a_plural_without_other():
    with pytest.raises(ValueError, match="other"):
        l10n.apply_one({}, "%lld documents", "de", {"plural": {"one": "%lld Dokument"}}, review=False)


def _phrase_entry(key):
    return {"localizations": {"en": {"stringSet": {"state": "new", "values": [key]}}}}


def test_apply_one_writes_a_shortcut_phrase_set():
    entry: dict = _phrase_entry("Ask ${applicationName}")
    phrases = ["Frag ${applicationName}", "Stell ${applicationName} eine Frage"]
    l10n.apply_one(entry, "Ask ${applicationName}", "de", {"values": phrases}, review=False)
    assert entry["localizations"]["de"] == {"stringSet": {"state": "translated", "values": phrases}}


def test_apply_one_refuses_a_phrase_without_the_app_name():
    with pytest.raises(ValueError, match="lost the parameter"):
        l10n.apply_one(_phrase_entry("Ask ${applicationName}"), "Ask ${applicationName}", "de",
                       {"values": ["Frag M1K3"]}, review=False)


def test_apply_one_refuses_a_dropped_argument():
    with pytest.raises(ValueError, match="missing argument"):
        l10n.apply_one({}, "%@ is ready", "de", {"value": "Fertig"}, review=False)


def test_apply_one_refuses_a_rekinded_argument():
    with pytest.raises(ValueError, match="int"):
        l10n.apply_one({}, "%lld left", "fr", {"value": "%@ restants"}, review=False)


def test_apply_one_allows_reordered_positional_arguments():
    entry: dict = {}
    l10n.apply_one(entry, "%1$@ of %2$@", "de", {"value": "%2$@: %1$@"}, review=False)
    assert entry["localizations"]["de"]["stringUnit"]["value"] == "%2$@: %1$@"


def test_apply_one_refuses_an_empty_value():
    with pytest.raises(ValueError, match="empty"):
        l10n.apply_one({}, "Done", "de", {"value": "  "}, review=False)


def test_apply_one_refuses_a_locale_outside_the_wave():
    with pytest.raises(ValueError, match="locale"):
        l10n.apply_one({}, "Done", "en", {"value": "Done"}, review=False)


# --------------------------------------------------------------------------- #
# translatable: which keys a translator ever sees
# --------------------------------------------------------------------------- #

def test_translatable_skips_do_not_translate_blank_and_stale():
    strings = {
        "": {"shouldTranslate": False},
        " ": {},
        "M1K3": {"shouldTranslate": False},
        "Gone": {"extractionState": "stale"},
        "Done": {},
    }
    assert [key for key, _ in l10n.translatable(strings)] == ["Done"]


def test_source_text_prefers_the_english_value():
    entry = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Mic access lets M1K3 hear you."}}}}
    assert l10n.source_text("NSMicrophoneUsageDescription", entry) == "Mic access lets M1K3 hear you."
    assert l10n.source_text("Done", {}) == "Done"


def test_apply_one_refuses_a_lost_intent_parameter():
    with pytest.raises(ValueError, match="todoTitle"):
        l10n.apply_one({}, "Add ${todoTitle} to M1K3's todos", "de", {"value": "Zu den Todos hinzufügen"}, review=False)


def test_apply_one_keeps_an_intent_parameter_anywhere_in_the_sentence():
    entry: dict = {}
    l10n.apply_one(entry, "Add ${todoTitle} to M1K3's todos", "de",
                   {"value": "${todoTitle} zu M1K3s Todos hinzufügen"}, review=False)
    assert "${todoTitle}" in entry["localizations"]["de"]["stringUnit"]["value"]


# --------------------------------------------------------------------------- #
# Review fold (2026-11-20): dumps never touches braces inside a string
# --------------------------------------------------------------------------- #

def test_dumps_leaves_braces_inside_strings_alone():
    catalog = {"strings": {"Use {} here": {"localizations": {"de": {"stringUnit": {"state": "translated",
                                                                                  "value": "Nimm {} hier"}}}},
                           "Empty": {}}}
    text = l10n.dumps(catalog)
    assert json.loads(text) == catalog
    assert '"Use {} here"' in text and '"Nimm {} hier"' in text


# --------------------------------------------------------------------------- #
# Review fold: the shape of a draft must match its entry
# --------------------------------------------------------------------------- #

def test_apply_one_checks_every_intent_token_in_a_phrase():
    with pytest.raises(ValueError, match=r"lost the parameter \$\{question\}"):
        l10n.apply_one(_phrase_entry("Ask ${applicationName} ${question}"), "Ask ${applicationName} ${question}", "de",
                       {"values": ["Frag ${applicationName}"]}, review=False)


def test_apply_one_refuses_a_plain_value_for_a_phrase_set():
    entry = {"localizations": {"en": {"stringSet": {"state": "new", "values": ["Ask ${applicationName}"]}}}}
    with pytest.raises(ValueError, match="does not fit the entry"):
        l10n.apply_one(entry, "Ask ${applicationName}", "de", {"value": "Frag ${applicationName}"}, review=False)


def test_apply_one_refuses_a_plural_for_a_key_without_one_integer():
    with pytest.raises(ValueError, match="exactly one integer"):
        l10n.apply_one({}, "%@ downloaded", "de", {"plural": {"one": "%@", "other": "%@"}}, review=False)


def test_apply_one_refuses_a_draft_with_two_shapes():
    with pytest.raises(ValueError, match="one of"):
        l10n.apply_one({}, "Done", "de", {"value": "Fertig", "values": ["Fertig"]}, review=False)


# --------------------------------------------------------------------------- #
# Review fold: which lines a native speaker must read is the tool's call, not the draft's
# --------------------------------------------------------------------------- #

def test_needs_native_read_holds_privacy_sentences_and_permission_prompts():
    assert l10n.needs_native_read("M1K3App/InfoPlist.xcstrings", "Mic")
    assert l10n.needs_native_read("x/Localizable.xcstrings", "Your notes stay on this Mac, encrypted.")
    assert not l10n.needs_native_read("x/Localizable.xcstrings", "Web search")  # a label names, never promises
    assert not l10n.needs_native_read("x/Localizable.xcstrings", "Rename this chat for me later")


# --------------------------------------------------------------------------- #
# Review fold: apply() end to end on a scratch catalog
# --------------------------------------------------------------------------- #

def _catalog(tmp_path, strings):
    folder = tmp_path / "App"
    folder.mkdir(exist_ok=True)
    path = folder / "Localizable.xcstrings"
    path.write_text(l10n.dumps({"sourceLanguage": "en", "strings": strings, "version": "1.0"}), encoding="utf-8")
    return "App/Localizable.xcstrings"


def _drafts(tmp_path, rows, name="drafts.json"):
    path = tmp_path / name
    path.write_text(json.dumps(rows), encoding="utf-8")
    return str(path)


PRIVACY = "Your notes stay on this Mac and never leave it."


def _sheet(tmp_path, pending, locale="de"):
    """Print the reader's sheet, which stamps what it showed into the pending file."""
    assert l10n.review_sheet(str(tmp_path), str(pending), locale, str(tmp_path / f"sheet-{locale}.md")) == 0


def _no_approvals(tmp_path):
    path = tmp_path / "approved.json"
    path.write_text("[]\n")
    return path


def test_apply_holds_privacy_even_when_the_draft_says_otherwise(tmp_path):
    cat = _catalog(tmp_path, {"Rename chat": {}, PRIVACY: {}})
    rows = [{"catalog": cat, "key": "Rename chat", "locale": "de", "value": "Chat umbenennen", "review": False},
            {"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Deine Notizen bleiben auf diesem Mac.",
             "review": False}]
    pending = tmp_path / "pending.json"
    assert l10n.apply(str(tmp_path), _drafts(tmp_path, rows), None, str(pending)) == 0
    strings = json.loads((tmp_path / cat).read_text())["strings"]
    assert strings["Rename chat"]["localizations"]["de"]["stringUnit"]["state"] == "translated"
    assert "localizations" not in strings[PRIVACY]
    assert [r["key"] for r in json.loads(pending.read_text())] == [PRIVACY]


def test_apply_merges_into_an_existing_pending_file(tmp_path):
    cat = _catalog(tmp_path, {PRIVACY: {}})
    pending = tmp_path / "pending.json"
    first = [{"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Deine Notizen bleiben hier.", "review": True}]
    second = [{"catalog": cat, "key": PRIVACY, "locale": "fr", "value": "Tes notes restent ici.", "review": True}]
    l10n.apply(str(tmp_path), _drafts(tmp_path, first, "a.json"), None, str(pending))
    l10n.apply(str(tmp_path), _drafts(tmp_path, second, "b.json"), None, str(pending))
    assert sorted(r["locale"] for r in json.loads(pending.read_text())) == ["de", "fr"]


def test_apply_refuses_privacy_rows_without_a_hold_or_an_approval(tmp_path):
    cat = _catalog(tmp_path, {PRIVACY: {}})
    rows = [{"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Deine Notizen bleiben hier.", "review": True}]
    assert l10n.apply(str(tmp_path), _drafts(tmp_path, rows), None) == 1
    assert "localizations" not in json.loads((tmp_path / cat).read_text())["strings"][PRIVACY]


def test_apply_approved_writes_translated_and_clears_the_pending_rows(tmp_path):
    cat = _catalog(tmp_path, {PRIVACY: {}})
    row = {"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Deine Notizen bleiben hier.", "review": True}
    pending = tmp_path / "pending.json"
    l10n.apply(str(tmp_path), _drafts(tmp_path, [row]), None, str(pending))
    _sheet(tmp_path, pending)
    assert l10n.apply(str(tmp_path), str(pending), None, str(pending), approved=True, locales=["de"]) == 0
    unit = json.loads((tmp_path / cat).read_text())["strings"][PRIVACY]["localizations"]["de"]["stringUnit"]
    assert unit["state"] == "translated"
    assert json.loads(pending.read_text()) == []


def test_apply_rejects_rows_for_a_missing_catalog_without_touching_the_others(tmp_path):
    cat = _catalog(tmp_path, {"Rename chat": {}})
    rows = [{"catalog": "Nope/Localizable.xcstrings", "key": "x", "locale": "de", "value": "y"},
            {"catalog": cat, "key": "Rename chat", "locale": "de", "value": "Chat umbenennen"}]
    assert l10n.apply(str(tmp_path), _drafts(tmp_path, rows), None, str(tmp_path / "p.json")) == 1
    assert json.loads((tmp_path / cat).read_text())["strings"]["Rename chat"]["localizations"]["de"]


# --------------------------------------------------------------------------- #
# Bot pass 1 fold (#873): the rule alone holds every held row; sweep retracts; one reader at a time
# --------------------------------------------------------------------------- #

def test_apply_never_writes_a_row_the_pending_file_holds_even_without_its_flag(tmp_path):
    # The draft's `review` flag is not stored in the catalogs, but the pending file is in the repo: a re-draft that
    # loses the flag must not ship a held line (bot pass 1 on #873).
    held_only_by_its_flag = "Only approve a device you're holding right now."
    cat = _catalog(tmp_path, {held_only_by_its_flag: {}})
    pending = tmp_path / "pending.json"
    first = [{"catalog": cat, "key": held_only_by_its_flag, "locale": "de", "value": "Koppel nur Geräte in deiner Hand.",
              "review": True}]
    l10n.apply(str(tmp_path), _drafts(tmp_path, first, "a.json"), None, str(pending))
    redraft = [{**first[0], "review": False, "value": "Gib nur ein Gerät frei, das du gerade in der Hand hältst."}]
    assert l10n.apply(str(tmp_path), _drafts(tmp_path, redraft, "b.json"), None, str(pending)) == 0
    assert "localizations" not in json.loads((tmp_path / cat).read_text())["strings"][held_only_by_its_flag]
    assert json.loads(pending.read_text())[0]["value"].startswith("Gib nur")


@pytest.mark.parametrize("text", [
    "Searches go to %@",
    "Every thumb and note goes. Your conversations stay.",
    "Your mail app didn't open it. The full text is on your clipboard.",
    "Pings you when a long reply finishes, never with the reply itself.",
])
def test_egress_sentences_the_first_rule_missed_are_held(text):
    assert l10n.needs_native_read("x/Localizable.xcstrings", text)


@pytest.mark.parametrize("text", ["Stays on device", "Nothing is sent", "Not shared"])
def test_a_short_privacy_claim_is_held(text):
    assert l10n.needs_native_read("x/Localizable.xcstrings", text)


def test_sweep_retracts_a_shipped_translation_the_rule_now_holds(tmp_path):
    cat = _catalog(tmp_path, {PRIVACY: {"localizations": {"de": {"stringUnit": {
        "state": "translated", "value": "Deine Notizen bleiben hier."}}}}, "Rename chat": {"localizations": {
        "de": {"stringUnit": {"state": "translated", "value": "Chat umbenennen"}}}}})
    pending = tmp_path / "pending.json"
    assert l10n.sweep(str(tmp_path), str(pending)) == 0
    strings = json.loads((tmp_path / cat).read_text())["strings"]
    assert "localizations" not in strings[PRIVACY]
    assert strings["Rename chat"]["localizations"]["de"]["stringUnit"]["value"] == "Chat umbenennen"
    assert [(r["locale"], r["key"], r["value"]) for r in json.loads(pending.read_text())] == [
        ("de", PRIVACY, "Deine Notizen bleiben hier.")]


def test_approving_one_locale_leaves_the_others_held(tmp_path):
    cat = _catalog(tmp_path, {PRIVACY: {}})
    pending = tmp_path / "pending.json"
    rows = [{"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Deine Notizen bleiben hier.", "review": True},
            {"catalog": cat, "key": PRIVACY, "locale": "fr", "value": "Tes notes restent ici.", "review": True}]
    l10n.apply(str(tmp_path), _drafts(tmp_path, rows), None, str(pending))
    _sheet(tmp_path, pending)
    assert l10n.apply(str(tmp_path), str(pending), None, str(pending), approved=True, locales=["de"]) == 0
    localizations = json.loads((tmp_path / cat).read_text())["strings"][PRIVACY]["localizations"]
    assert list(localizations) == ["de"]
    assert [r["locale"] for r in json.loads(pending.read_text())] == ["fr"]


# --------------------------------------------------------------------------- #
# Bot pass 1 fold, round 2 (#873): a native reader's approval is recorded, so sweep and re-drafts keep it
# --------------------------------------------------------------------------- #

def _approve_de(tmp_path):
    cat = _catalog(tmp_path, {PRIVACY: {}})
    pending, approvals = tmp_path / "pending.json", _no_approvals(tmp_path)
    row = {"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Deine Notizen bleiben hier.", "review": True}
    l10n.apply(str(tmp_path), _drafts(tmp_path, [row]), None, str(pending))
    _sheet(tmp_path, pending)
    assert l10n.apply(str(tmp_path), str(pending), None, str(pending), approved=True, locales=["de"],
                      approvals_path=str(approvals)) == 0
    return cat, pending, approvals, row


def test_an_approval_is_recorded_against_the_english_it_was_read_against(tmp_path):
    cat, _, approvals, _ = _approve_de(tmp_path)
    assert json.loads(approvals.read_text()) == [{"catalog": cat, "english": PRIVACY, "key": PRIVACY, "locale": "de"}]


def test_sweep_keeps_an_approved_line(tmp_path):
    cat, pending, approvals, _ = _approve_de(tmp_path)
    assert l10n.sweep(str(tmp_path), str(pending), str(approvals)) == 0
    unit = json.loads((tmp_path / cat).read_text())["strings"][PRIVACY]["localizations"]["de"]["stringUnit"]
    assert unit["value"] == "Deine Notizen bleiben hier."
    assert json.loads(pending.read_text()) == []


def test_a_redraft_never_replaces_or_holds_an_approved_line(tmp_path):
    cat, pending, approvals, row = _approve_de(tmp_path)
    redraft = [{**row, "value": "Ein ungelesener neuer Entwurf.", "review": True}]
    assert l10n.apply(str(tmp_path), _drafts(tmp_path, redraft, "b.json"), None, str(pending),
                      approvals_path=str(approvals)) == 0
    unit = json.loads((tmp_path / cat).read_text())["strings"][PRIVACY]["localizations"]["de"]["stringUnit"]
    assert unit["value"] == "Deine Notizen bleiben hier."
    assert json.loads(pending.read_text()) == []


def test_an_approval_lapses_when_the_english_changes(tmp_path):
    cat, pending, approvals, _ = _approve_de(tmp_path)
    data = json.loads(approvals.read_text())
    data[0]["english"] = "Your notes stay on this Mac."  # read against an older English line
    approvals.write_text(json.dumps(data))
    l10n.sweep(str(tmp_path), str(pending), str(approvals))
    assert "localizations" not in json.loads((tmp_path / cat).read_text())["strings"][PRIVACY]
    assert [r["locale"] for r in json.loads(pending.read_text())] == ["de"]


@pytest.mark.parametrize("text", [
    "Local API (OpenAI-compatible, localhost)",
    "Every app you've pointed at M1K3 stops working until you give it the new key.",
    "How Apple protects it",
])
def test_rows_pass_two_found_shipping_unread_are_held(text):
    assert l10n.needs_native_read("x/Localizable.xcstrings", text)


@pytest.mark.parametrize("text", ["Always local", "Fully offline", "Private by design"])
def test_a_short_local_or_offline_claim_is_held(text):
    assert l10n.needs_native_read("x/Localizable.xcstrings", text)


# --------------------------------------------------------------------------- #
# Approval guards (#873 round-2 follow-ups): an approval covers exactly what a reader read
# --------------------------------------------------------------------------- #

def test_a_held_row_carries_the_english_it_was_drafted_against(tmp_path):
    cat = _catalog(tmp_path, {PRIVACY: {}})
    pending = tmp_path / "pending.json"
    row = {"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Deine Notizen bleiben hier.", "review": True}
    l10n.apply(str(tmp_path), _drafts(tmp_path, [row]), None, str(pending))
    assert json.loads(pending.read_text())[0]["english"] == PRIVACY


def test_approved_refuses_a_row_the_pending_file_does_not_hold(tmp_path):
    # A drafts file passed with --approved would skip the native read.
    cat = _catalog(tmp_path, {PRIVACY: {}})
    pending, approvals = tmp_path / "pending.json", _no_approvals(tmp_path)
    row = {"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Ungelesen.", "review": True}
    assert l10n.apply(str(tmp_path), _drafts(tmp_path, [row]), None, str(pending), approved=True,
                      approvals_path=str(approvals)) == 1
    assert "localizations" not in json.loads((tmp_path / cat).read_text())["strings"][PRIVACY]
    assert json.loads(approvals.read_text()) == []


def test_approved_refuses_a_row_whose_english_changed_after_the_sheet(tmp_path):
    cat = _catalog(tmp_path, {PRIVACY: {}})
    pending, approvals = tmp_path / "pending.json", _no_approvals(tmp_path)
    row = {"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Deine Notizen bleiben hier.", "review": True}
    l10n.apply(str(tmp_path), _drafts(tmp_path, [row]), None, str(pending))
    _sheet(tmp_path, pending)
    rows = json.loads(pending.read_text())
    rows[0]["english"] = "Your notes stay here."  # the reader's sheet showed an older English line
    pending.write_text(json.dumps(rows))
    assert l10n.apply(str(tmp_path), str(pending), None, str(pending), approved=True,
                      approvals_path=str(approvals)) == 1
    assert "localizations" not in json.loads((tmp_path / cat).read_text())["strings"][PRIVACY]
    assert [r["locale"] for r in json.loads(pending.read_text())] == ["de"]


def test_approved_refuses_a_held_row_without_its_english(tmp_path):
    cat = _catalog(tmp_path, {PRIVACY: {}})
    pending = tmp_path / "pending.json"
    pending.write_text(json.dumps([{"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Hier.", "review": True}]))
    assert l10n.apply(str(tmp_path), str(pending), None, str(pending), approved=True) == 1


def test_a_kept_row_whose_translation_is_gone_is_held_again(tmp_path):
    cat, pending, approvals, row = _approve_de(tmp_path)
    data = json.loads((tmp_path / cat).read_text())
    data["strings"][PRIVACY] = {}  # the approved translation was removed from the catalog
    (tmp_path / cat).write_text(l10n.dumps(data))
    l10n.apply(str(tmp_path), _drafts(tmp_path, [{**row, "value": "Neu."}], "b.json"), None, str(pending),
               approvals_path=str(approvals))
    assert "localizations" not in json.loads((tmp_path / cat).read_text())["strings"][PRIVACY]
    assert [r["value"] for r in json.loads(pending.read_text())] == ["Neu."]


# Review fold (pre-push): the sheet stamp binds an approval to the English AND the translation the reader saw

def _held_with_sheet(tmp_path):
    cat = _catalog(tmp_path, {PRIVACY: {}})
    pending = tmp_path / "pending.json"
    row = {"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Deine Notizen bleiben hier.", "review": True}
    l10n.apply(str(tmp_path), _drafts(tmp_path, [row]), None, str(pending))
    _sheet(tmp_path, pending)
    return cat, pending, row


def test_a_redraft_after_the_sheet_needs_a_new_sheet(tmp_path):
    cat, pending, row = _held_with_sheet(tmp_path)
    redraft = {**row, "value": "Ein Entwurf, den niemand gelesen hat."}
    l10n.apply(str(tmp_path), _drafts(tmp_path, [redraft], "b.json"), None, str(pending))
    assert "sheet" not in json.loads(pending.read_text())[0]
    assert l10n.apply(str(tmp_path), str(pending), None, str(pending), approved=True, locales=["de"]) == 1
    assert "localizations" not in json.loads((tmp_path / cat).read_text())["strings"][PRIVACY]


def test_the_same_redraft_keeps_its_sheet(tmp_path):
    _, pending, row = _held_with_sheet(tmp_path)
    l10n.apply(str(tmp_path), _drafts(tmp_path, [row], "b.json"), None, str(pending))
    assert l10n.apply(str(tmp_path), str(pending), None, str(pending), approved=True, locales=["de"]) == 0


def test_approved_refuses_a_translation_that_differs_from_the_sheet(tmp_path):
    cat, pending, row = _held_with_sheet(tmp_path)
    edited = _drafts(tmp_path, [{**row, "value": "Etwas anderes."}], "edited.json")
    assert l10n.apply(str(tmp_path), edited, None, str(pending), approved=True, locales=["de"]) == 1
    assert "localizations" not in json.loads((tmp_path / cat).read_text())["strings"][PRIVACY]


def test_approved_refuses_a_held_row_no_sheet_showed(tmp_path):
    cat = _catalog(tmp_path, {PRIVACY: {}})
    pending = tmp_path / "pending.json"
    row = {"catalog": cat, "key": PRIVACY, "locale": "de", "value": "Deine Notizen bleiben hier.", "review": True}
    l10n.apply(str(tmp_path), _drafts(tmp_path, [row]), None, str(pending))
    assert l10n.apply(str(tmp_path), str(pending), None, str(pending), approved=True, locales=["de"]) == 1


def test_a_missing_approvals_file_is_an_error_not_an_empty_set(tmp_path):
    _catalog(tmp_path, {PRIVACY: {}})
    with pytest.raises(FileNotFoundError):
        l10n.sweep(str(tmp_path), str(tmp_path / "pending.json"), str(tmp_path / "typo.json"))


def test_approved_without_a_locale_is_a_usage_error(tmp_path):
    with pytest.raises(SystemExit):
        l10n.main(["--root", str(tmp_path), "apply", "pending.json", "--approved", "--hold-review", "pending.json"])


def test_shipped_privacy_copy_in_the_repo_was_read_against_its_english():
    # The hold invariant over the real catalogs: CI fails when a translation the rule holds ships without an
    # approval for its current English (a hand edit, an Xcode re-extract, or an approved line's English edited).
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    leaks = l10n.unread_shipped(root, os.path.join(root, l10n.APPROVALS))
    assert leaks == [], f"{len(leaks)} privacy lines ship unread, first: {leaks[:3]}"


def test_pending_rows_in_the_repo_carry_their_english():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    with open(os.path.join(root, "docs/l10n/pending-review.json"), encoding="utf-8") as handle:
        rows = json.load(handle)
    assert rows and all(isinstance(r.get("english"), str) and r["english"] for r in rows)
