#!/usr/bin/env python3
"""Fail CI when a string catalog (.xcstrings) would ship broken copy.

Localisation Phase 0 (plan 2026-11-18, §3): M1K3 ships English only, but every
target now carries a catalog — the Mac app, the iOS/visionOS shell, the Live
Activity extension, each shell's InfoPlist.xcstrings and one Localizable.xcstrings
per package module (`bundle: .module`). Three rules, all pure JSON reads:

1. Every catalog's `sourceLanguage` is "en" (Kev, 2026-11-19: development language
   `en`, written in en-GB spelling). A catalog in another source language would
   resolve its keys against the wrong table.
2. No key is `stale`, and in each SHIPPED locale every key is translated. A stale
   key is copy the code no longer asks for (a re-sync drops it); an untranslated
   key in a shipped locale renders English inside a translated app. The shipped set
   is `SHIPPED_LOCALES` below and starts EMPTY: a locale joins it in the same PR
   that finishes its translation (Phase 1: de, fr, es, pt-BR).
3. Every value — the English one and every translation, each plural/device variant
   included — uses the same format specifiers as its key: same argument positions,
   same kinds (integer, float, object, C string, char, pointer). A translation that
   swaps `%lld` for `%@`, or drops an argument, crashes or misrenders at runtime.
   A plural or device variant may OMIT an argument (`one` often reads "an item"),
   but may not add one or change its kind.

Keys marked `"shouldTranslate": false` (brand and tier names) need no translation
and are still checked for specifiers.

    python3 check_string_catalogs.py [ROOT]

ROOT defaults to the repo's macos/. Read-only. The pure helpers are unit-tested in
test_check_string_catalogs.py; the file walk and exit wiring are verify-by-run.

Signed: claude-opus-5-5, 2026-11-19, Confidence 0.8 (the specifier grammar covers
what Swift's String(localized:) and SwiftUI's LocalizedStringKey emit — %@ %lld %lf
%d, positional forms, %% — not every printf corner; `%#@name@` substitutions are
skipped, not checked). Prior: none (new file, localisation Phase 0).
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections.abc import Iterator

# Locales whose translation is complete and shipped. Empty in Phase 0 (English only).
SHIPPED_LOCALES: tuple[str, ...] = ()

SOURCE_LANGUAGE = "en"

# Folders under ROOT that never hold a shipped catalog.
SKIP_DIRS = {".build", ".git", "DerivedData", "node_modules", ".swiftpm", "M1K3.xcodeproj"}

# printf grammar as Foundation uses it: optional `n$` position, flags, width, precision,
# length modifier, conversion. No space flag: "100 % sure" in a translation is text.
_SPEC = re.compile(
    r"%(?:(?P<pos>\d+)\$)?[-+#0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?P<len>hh|h|ll|l|q|L|z|t|j)?(?P<conv>[@dDiuUxXoOfFeEgGaAcCsSp])"
)
_SUBSTITUTION = re.compile(r"%#@[A-Za-z0-9_]+@")

_KIND = {
    **{c: "int" for c in "dDiuUxXoO"},
    **{c: "float" for c in "fFeEgGaA"},
    "@": "object",
    "s": "cstring",
    "S": "cstring",
    "c": "char",
    "C": "char",
    "p": "pointer",
}

# --------------------------------------------------------------------------- #
# Pure helpers (unit-tested)
# --------------------------------------------------------------------------- #


def specifiers(text: str) -> dict[int, str]:
    """The format arguments in `text`, as {1-based position: kind}.

    `%%` is a literal percent, not an argument. Implicit specifiers take the next
    position in order, as printf does; `%2$@` names its own. `%#@name@`
    substitutions are skipped. A position used twice with two kinds keeps the
    first kind and records the clash as kind "conflict".
    """
    text = _SUBSTITUTION.sub("", text.replace("%%", ""))
    found: dict[int, str] = {}
    implicit = 0
    for match in _SPEC.finditer(text):
        if match.group("pos"):
            position = int(match.group("pos"))
        else:
            implicit += 1
            position = implicit
        kind = _KIND[match.group("conv")]
        if position in found and found[position] != kind:
            found[position] = "conflict"
        else:
            found[position] = kind
    return found


def specifier_problem(source: dict[int, str], value: dict[int, str], variant: bool) -> str | None:
    """Why `value`'s arguments don't fit `source`'s, or None when they do.

    A plain value must carry exactly the source's arguments. A plural/device
    variant may leave arguments out, never add or re-kind one.
    """
    for position, kind in sorted(value.items()):
        if position not in source:
            return f"argument {position} ({kind}) is not in the key"
        if kind != source[position]:
            return f"argument {position} is {kind}, the key has {source[position]}"
    if not variant:
        missing = sorted(set(source) - set(value))
        if missing:
            return "missing argument " + ", ".join(f"{p} ({source[p]})" for p in missing)
    return None


def string_units(localization: dict, path: str = "") -> Iterator[tuple[str, dict, bool]]:
    """Every stringUnit in one localization, as (variant path, unit, is_variant).

    An App Shortcuts phrase table holds a `stringSet` (several phrases for one key):
    each phrase is yielded as its own unit carrying the set's state.
    """
    if "stringUnit" in localization:
        yield path or "value", localization["stringUnit"], bool(path)
    string_set = localization.get("stringSet")
    if string_set is not None:
        for index, phrase in enumerate(string_set.get("values") or []):
            yield f"{path}phrase[{index}]", {"state": string_set.get("state"), "value": phrase}, bool(path)
    for axis, cases in (localization.get("variations") or {}).items():
        for case, nested in (cases or {}).items():
            yield from string_units(nested or {}, f"{path}{axis}.{case}/")
    for name, sub in (localization.get("substitutions") or {}).items():
        yield from string_units(sub or {}, f"{path}substitution.{name}/")


def catalog_problems(catalog: dict, shipped: tuple[str, ...] = SHIPPED_LOCALES) -> list[str]:
    """Every rule broken by one parsed catalog, as human-readable lines."""
    problems: list[str] = []
    source_language = catalog.get("sourceLanguage")
    if source_language != SOURCE_LANGUAGE:
        problems.append(f'sourceLanguage is "{source_language}", not "{SOURCE_LANGUAGE}"')
    for key, entry in sorted((catalog.get("strings") or {}).items()):
        entry = entry or {}
        if entry.get("extractionState") == "stale":
            problems.append(f"stale key (the code no longer uses it; re-sync the catalog): {key!r}")
        localizations = entry.get("localizations") or {}
        if entry.get("shouldTranslate", True):
            for locale in shipped:
                units = list(string_units(localizations.get(locale) or {}))
                if not units:
                    problems.append(f"{locale}: untranslated: {key!r}")
                    continue
                for variant, unit, _ in units:
                    if (unit or {}).get("state") != "translated":
                        problems.append(f"{locale}: {variant} is {(unit or {}).get('state')!r}, not translated: {key!r}")
        source = specifiers(key)
        for locale, localization in sorted(localizations.items()):
            for variant, unit, is_variant in string_units(localization or {}):
                value = (unit or {}).get("value")
                if value is None:
                    continue
                why = specifier_problem(source, specifiers(value), is_variant)
                if why:
                    problems.append(f"{locale} {variant}: {why}: {key!r} -> {value!r}")
    return problems


def catalog_paths(root: str) -> list[str]:
    """Every .xcstrings under `root`, skipping build products and the generated project."""
    found: list[str] = []
    for directory, subdirs, files in os.walk(root):
        subdirs[:] = sorted(d for d in subdirs if d not in SKIP_DIRS and not d.startswith(".dd"))
        found.extend(os.path.join(directory, f) for f in sorted(files) if f.endswith(".xcstrings"))
    return found


# --------------------------------------------------------------------------- #
# Wiring (verify-by-run)
# --------------------------------------------------------------------------- #


def main(argv: list[str]) -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(argv[1] if len(argv) > 1 else os.path.join(here, "..", ".."))
    paths = catalog_paths(root)
    failed = False
    for path in paths:
        rel = os.path.relpath(path, root)
        try:
            with open(path, encoding="utf-8") as fh:
                catalog = json.load(fh)
        except (OSError, json.JSONDecodeError) as error:
            failed = True
            print(f"✗ {rel}: unreadable catalog ({error})")
            continue
        problems = catalog_problems(catalog)
        if problems:
            failed = True
            print(f"✗ {rel}")
            for problem in problems:
                print(f"  - {problem}")
    shipped = ", ".join(SHIPPED_LOCALES) or "none yet (English only)"
    if not paths:
        print(f"✗ no .xcstrings under {root}: the walk is broken or the catalogs moved")
        return 1
    if not failed:
        print(f"✓ {len(paths)} string catalogs: source en, no stale keys, specifiers match; shipped: {shipped}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
