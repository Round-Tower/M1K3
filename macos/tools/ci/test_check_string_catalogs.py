"""Pins for check_string_catalogs: stale keys, untranslated keys in a shipped locale,
and format-specifier drift between a key and its values fail CI.

Signed: claude-opus-5-5, 2026-11-19, Confidence 0.8. Prior: none (new file, localisation Phase 0).
"""
import json

import check_string_catalogs as m


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def catalog(strings, source="en"):
    return {"sourceLanguage": source, "strings": strings, "version": "1.0"}


# --- specifiers ------------------------------------------------------------- #


def test_specifiers_read_swift_and_swiftui_forms():
    assert m.specifiers("Step %lld of %lld: %@") == {1: "int", 2: "int", 3: "object"}
    assert m.specifiers("Step %1$lld of %2$lld: %3$@") == {1: "int", 2: "int", 3: "object"}
    assert m.specifiers("%2$@ before %1$@") == {1: "object", 2: "object"}
    assert m.specifiers("%.1f GB, %d left, %s") == {1: "float", 2: "int", 3: "cstring"}


def test_a_literal_percent_is_not_an_argument():
    assert m.specifiers("Downloading %@… %lld%%") == {1: "object", 2: "int"}
    assert m.specifiers("100%% sure") == {}
    assert m.specifiers("zu 100 % sicher") == {}, "a translator's spaced percent is text, not a spec"


def test_substitutions_are_skipped_and_a_position_reused_with_two_kinds_is_a_conflict():
    assert m.specifiers("%#@items@ left") == {}
    assert m.specifiers("%1$@ and %1$lld") == {1: "conflict"}


# --- specifier_problem ------------------------------------------------------ #


def test_a_reordered_positional_translation_fits():
    key = m.specifiers("%@ needs %lld GB")
    assert m.specifier_problem(key, m.specifiers("%2$lld GB braucht %1$@"), variant=False) is None


def test_a_swapped_kind_or_a_missing_or_extra_argument_does_not_fit():
    key = m.specifiers("%@ needs %lld GB")
    assert "argument 2 is object" in m.specifier_problem(key, m.specifiers("%1$@ braucht %2$@ GB"), False)
    assert "missing argument 2 (int)" in m.specifier_problem(key, m.specifiers("%@ braucht mehr"), False)
    assert "argument 3" in m.specifier_problem(key, m.specifiers("%@ %lld %@"), False)


def test_a_plural_variant_may_drop_the_count_but_not_change_it():
    key = m.specifiers("%lld items")
    assert m.specifier_problem(key, m.specifiers("an item"), variant=True) is None
    assert m.specifier_problem(key, m.specifiers("%@ items"), variant=True) is not None


# --- catalog_problems ------------------------------------------------------- #


def test_an_english_only_catalog_with_new_keys_passes_while_nothing_ships():
    cat = catalog({
        "Done": {},
        "Step %lld of %lld: %@": {"localizations": {"en": unit("Step %1$lld of %2$lld: %3$@", "new")}},
        "Lil": {"shouldTranslate": False},
    })
    assert m.catalog_problems(cat, shipped=()) == []


def test_a_stale_key_fails():
    problems = m.catalog_problems(catalog({"Old copy": {"extractionState": "stale"}}), shipped=())
    assert problems == ["stale key (the code no longer uses it; re-sync the catalog): 'Old copy'"]


def test_a_manual_infoplist_key_is_not_stale():
    cat = catalog({"NSCameraUsageDescription": {"extractionState": "manual", "localizations": {"en": unit("x")}}})
    assert m.catalog_problems(cat, shipped=()) == []


def test_a_shipped_locale_needs_every_key_translated():
    cat = catalog({
        "Done": {"localizations": {"de": unit("Fertig")}},
        "Cancel": {},
        "Save": {"localizations": {"de": unit("Sichern", "needs_review")}},
        "Lil": {"shouldTranslate": False},
    })
    problems = m.catalog_problems(cat, shipped=("de",))
    assert problems == [
        "de: untranslated: 'Cancel'",
        "de: value is 'needs_review', not translated: 'Save'",
    ]
    assert m.catalog_problems(cat, shipped=()) == [], "an unshipped locale may be half done"


def test_every_plural_variant_of_a_shipped_locale_must_be_translated():
    plural = {"variations": {"plural": {"one": unit("ein Element"), "other": unit("%lld Elemente", "new")}}}
    cat = catalog({"%lld items": {"localizations": {"de": plural}}})
    assert m.catalog_problems(cat, shipped=("de",)) == [
        "de: plural.other/ is 'new', not translated: '%lld items'"
    ]


def test_an_app_shortcuts_phrase_set_is_checked_phrase_by_phrase():
    def phrases(state, *values):
        return {"stringSet": {"state": state, "values": list(values)}}

    key = "Ask ${applicationName}"
    cat = catalog({key: {"localizations": {
        "en": phrases("new", "Ask ${applicationName}", "Ask ${applicationName} a question"),
        "de": phrases("translated", "Frag ${applicationName}", "Stell ${applicationName} eine Frage"),
        "fr": phrases("new", "Demande à ${applicationName}"),
    }}})
    assert m.catalog_problems(cat, shipped=("de",)) == []
    assert m.catalog_problems(cat, shipped=("fr",)) == [f"fr: phrase[0] is 'new', not translated: {key!r}"]


def test_a_specifier_mismatch_fails_in_any_locale_shipped_or_not():
    cat = catalog({
        "%@ is ready": {"localizations": {"fr": unit("%lld est prêt")}},
        "Kept %@ — %lld chunks.": {"localizations": {"en": unit("Kept %1$@ — %2$@ chunks.", "new")}},
    })
    problems = m.catalog_problems(cat, shipped=())
    assert len(problems) == 2
    assert problems[0].startswith("fr value: argument 1 is int, the key has object")
    assert problems[1].startswith("en value: argument 2 is object, the key has int")


def test_a_catalog_in_another_source_language_fails():
    assert m.catalog_problems(catalog({}, source="en-GB"), shipped=()) == ['sourceLanguage is "en-GB", not "en"']


def test_nothing_ships_yet():
    """Phase 0 is English only. When a locale ships, change this pin in the same PR."""
    assert m.SHIPPED_LOCALES == ()


# --- the walk and the wiring ------------------------------------------------ #


def test_the_walk_finds_catalogs_and_skips_build_products(tmp_path):
    (tmp_path / "App").mkdir()
    (tmp_path / "App" / "Localizable.xcstrings").write_text(json.dumps(catalog({"Done": {}})))
    for skipped in (".build/x", "M1K3.xcodeproj", ".dd-l10n/Build"):
        (tmp_path / skipped).mkdir(parents=True)
        (tmp_path / skipped / "Localizable.xcstrings").write_text("{}")
    assert [p.replace(str(tmp_path), "") for p in m.catalog_paths(str(tmp_path))] == ["/App/Localizable.xcstrings"]


def test_main_exits_one_on_a_broken_catalog_and_zero_on_a_clean_tree(tmp_path, capsys):
    (tmp_path / "Localizable.xcstrings").write_text(json.dumps(catalog({"Done": {}})))
    assert m.main(["x", str(tmp_path)]) == 0
    (tmp_path / "Bad.xcstrings").write_text(json.dumps(catalog({"Gone": {"extractionState": "stale"}})))
    assert m.main(["x", str(tmp_path)]) == 1
    assert "✗ Bad.xcstrings" in capsys.readouterr().out


def test_main_fails_when_it_finds_no_catalog(tmp_path):
    assert m.main(["x", str(tmp_path)]) == 1


def test_the_real_tree_passes():
    assert m.main(["x"]) == 0
