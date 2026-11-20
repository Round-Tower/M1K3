#!/usr/bin/env python3
"""Move string-catalog copy out to translators and back in, safely.

Localisation Phase 1 (plan 2026-11-18 §3; Kev's decisions 2026-11-19 §5a): an LLM
drafts every string, a native speaker reads the privacy / egress / consent lines.
This tool is the plumbing on both sides of that draft:

    xcstrings_l10n.py export OUT_DIR [--batch N]   # batches of keys, each with its call sites
    xcstrings_l10n.py apply DRAFTS.json --hold-review PENDING.json   # drafts in; privacy lines held
    xcstrings_l10n.py apply PENDING.json --approved --hold-review PENDING.json --locale de   # one reader approved
    xcstrings_l10n.py sweep PENDING.json            # retract shipped lines the rule now holds (approved ones stay)
    xcstrings_l10n.py coverage                     # translated / needs_review / missing per locale
    xcstrings_l10n.py review-sheet PENDING.json LOCALE OUT.md   # the held lines, for the native read

`export` gives a translator what a catalog cannot: where the string is used (the Swift
line), whether it is privacy copy (`review`), and whether it may vary by plural. `apply`
refuses a translation that drops or re-kinds a format argument, loses `${applicationName}`
from an App Shortcuts phrase, or is empty, so a bad draft is a reject line, never a crash
at runtime. Privacy copy is held out of the catalogs (`--hold-review`, a pending file the
native reader's sheet is printed from), because master ships publicly in the nightly DMG and an
unread privacy promise must not; a held line renders in English until `apply --approved`.
An approval is recorded in `docs/l10n/approved.json` with the English it was read against, so a
later `sweep` or re-draft keeps that line until its English changes.

Run from macos/ (paths are relative to it). The pure helpers are unit-tested in
test_xcstrings_l10n.py; the file walk is verify-by-run.

Signed: claude-opus-5-5, 2026-11-20, Confidence 0.75 (the call-site finder is a regex
over single-line literals: a multi-line or concatenated literal gets no context, which
costs a translator nuance, not correctness). Prior: none (new file, localisation wave one).
Review: claude-opus-5-5, 2026-11-20 (bot passes, round 2 on #873) — approvals are recorded with the English
they were read against (`docs/l10n/approved.json`), so `sweep` and a re-draft keep them until the English
changes; the rule holds localhost / API-key / "protects" copy and short local / offline / private claims
(the sweep retracted 50 more lines). Confidence 0.8.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections.abc import Iterator

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ci"))
import check_string_catalogs as gate

# Wave one (Kev, 2026-11-19). ja is its own next wave.
LOCALES: tuple[str, ...] = ("de", "fr", "es", "pt-BR")

APP_NAME = "${applicationName}"
# An App Intents parameter (`${todoTitle}`): the runtime fills it by name, so it must survive.
_INTENT_TOKEN = re.compile(r"\$\{[A-Za-z0-9_]+\}")

# Copy a native speaker must read before it ships (decision 3): what leaves the device,
# what stays, consent, permissions. Deliberately wide — a false flag costs a reader a
# line, a missed one ships an unread privacy promise.
_PRIVACY = re.compile(
    r"privacy|private|leaves? (your|this|the)|\bnever\b|\bstay(s|ed)?\b|"
    r"web search|search the web|\bsearches\b|duckduckgo|wikipedia|internet|online|offline|wi.?fi|"
    r"server|send|sent|\bgo(es)? to\b|upload|share|shared|clipboard|e-?mail|mail app|round tower|"
    r"telemetry|track|analytics|consent|permission|\bagents?\b|spotlight|\bpair|"
    r"microphone|camera|location|contacts|calendar|photos|keychain|encrypt|"
    r"on-device|on this (mac|device|iphone)|third[- ]part|apple's|network|egress|"
    r"data|delete|erase|forget|\blocal(host)?\b|\bapi key|\bthe new key|\bprotects?\b",
    re.IGNORECASE,
)
# A label of three words or fewer ships unless it makes a claim ("Stays on device", "Nothing is sent").
_CLAIM = re.compile(
    r"\b(never|not|nothing|no one|nobody|stays?|shared|sent|leaves?|encrypted|private|local|offline)\b", re.IGNORECASE)

# Where each catalog's keys are used: its own folder (a package catalog lives in Resources/).
_SWIFT_LINE_CAP = 220


# --------------------------------------------------------------------------- #
# Pure helpers (unit-tested)
# --------------------------------------------------------------------------- #

def dumps(catalog: dict) -> str:
    """`catalog` as Xcode writes it: 2-space indent, `" : "`, raw UTF-8, `{\\n\\n}` for empty."""
    text = json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : "))
    # Only a whole-line empty object (`"key" : {}` or a bare `{}`), never braces inside a string value.
    text = re.sub(
        r'^( *)((?:"(?:[^"\\]|\\.)*" : )?)\{\}(,?)$',
        lambda m: f"{m.group(1)}{m.group(2)}{{\n\n{m.group(1)}}}{m.group(3)}",
        text,
        flags=re.MULTILINE,
    )
    return text + "\n"


def source_pattern(key: str) -> str:
    """A regex for the Swift string literal that produced `key`.

    A printf argument came from an interpolation (`\\(...)`), `%%` from a bare `%`,
    a `"` from `\\"`, and `${applicationName}` from `\\(.applicationName)`.
    """
    out: list[str] = []
    token = re.compile(r"\$\{applicationName\}|%%|" + gate._SPEC.pattern)
    cursor = 0
    for match in token.finditer(key):
        out.append(re.escape(key[cursor:match.start()]).replace('"', r'\\"'))
        piece = match.group(0)
        if piece == APP_NAME:
            out.append(r"\\\(\.applicationName\)")
        elif piece == "%%":
            out.append("%")
        else:
            out.append(r"\\\(.+?\)")
        cursor = match.end()
    out.append(re.escape(key[cursor:]).replace('"', r'\\"'))
    return '"' + "".join(out) + '"'


def privacy_hint(text: str) -> bool:
    """True when `text` reads as privacy / egress / consent copy (needs a native read)."""
    return bool(_PRIVACY.search(text))


def needs_native_read(catalog: str, english: str) -> bool:
    """Whether a translation of `english` must wait for a native reader (Kev, 2026-11-19, decision 3).

    Every system permission prompt (an InfoPlist catalog) and every privacy sentence. A label of three
    words or fewer ("Delete", "Web search", "Always allow") names an action and makes no promise, so it
    ships with the wave unless it makes a claim ("Stays on device"); the sentence that explains it is held. The
    tool decides with the pending file: `apply` holds any row this says, or the draft flags, or the pending file
    already holds, so a re-draft that loses its `review` flag cannot ship a held line.
    """
    if os.path.basename(catalog) == "InfoPlist.xcstrings":
        return True
    if not privacy_hint(english):
        return False
    return len(english.split()) > 3 or bool(_CLAIM.search(english))


def translatable(strings: dict) -> Iterator[tuple[str, dict]]:
    """The keys a translator sees: not blank, not `shouldTranslate: false`, not stale."""
    for key, entry in strings.items():
        entry = entry or {}
        if not key.strip() or not entry.get("shouldTranslate", True) or entry.get("extractionState") == "stale":
            continue
        yield key, entry


def source_text(key: str, entry: dict) -> str:
    """The English the person reads: the `en` value when the catalog has one, else the key."""
    unit = ((entry.get("localizations") or {}).get(gate.SOURCE_LANGUAGE) or {}).get("stringUnit") or {}
    return unit.get("value") or key


def _check(key: str, text: str, variant: bool, source: dict[int, str]) -> None:
    if not text.strip():
        raise ValueError(f"empty translation for {key!r}")
    for token in sorted(set(_INTENT_TOKEN.findall(key)) - {APP_NAME}):
        if token not in text:
            raise ValueError(f"lost the parameter {token}: {key!r} -> {text!r}")
    why = gate.specifier_problem(source, gate.specifiers(text), variant)
    if why:
        raise ValueError(f"{why}: {key!r} -> {text!r}")


def apply_one(entry: dict, key: str, locale: str, draft: dict, review: bool) -> None:
    """Write one locale's draft into `entry` (a catalog's `strings[key]`), in place.

    `draft` holds exactly one of `value` (a string), `values` (App Shortcuts phrases) or
    `plural` ({"one": ..., "other": ..., optional "zero"/"two"/"few"/"many"}), and it must fit the
    entry: phrases for a phrase set, a plural only for a key with one integer argument. Raises
    ValueError on anything the gate or the runtime would reject.
    """
    if locale not in LOCALES:
        raise ValueError(f"locale {locale!r} is not in this wave {LOCALES}")
    shapes = [field for field in ("value", "values", "plural") if draft.get(field) is not None]
    if len(shapes) != 1:
        raise ValueError(f"a draft holds exactly one of value / values / plural, got {shapes or 'none'}: {key!r}")
    english = (entry.get("localizations") or {}).get(gate.SOURCE_LANGUAGE) or {}
    is_phrase_set = "stringSet" in english
    if is_phrase_set != (shapes[0] == "values"):
        raise ValueError(f"the draft's shape ({shapes[0]}) does not fit the entry (phrase set: {is_phrase_set}): {key!r}")
    state = "needs_review" if review else "translated"
    source = gate.specifiers(key)
    if shapes[0] == "values":
        phrases = [p for p in draft["values"] if p and p.strip()]
        if not phrases:
            raise ValueError(f"empty phrase set for {key!r}")
        for phrase in phrases:
            for token in sorted(set(_INTENT_TOKEN.findall(key))):
                if token not in phrase:
                    raise ValueError(f"phrase lost the parameter {token}: {key!r} -> {phrase!r}")
        localization: dict = {"stringSet": {"state": state, "values": phrases}}
    elif shapes[0] == "plural":
        if sorted(source.values()) != ["int"]:
            raise ValueError(f"a plural needs exactly one integer argument in the key: {key!r}")
        cases = draft["plural"] or {}
        if "other" not in cases:
            raise ValueError(f"plural without 'other' for {key!r}")
        built = {}
        for case in ("zero", "one", "two", "few", "many", "other"):
            if case in cases:
                _check(key, cases[case], case != "other", source)
                built[case] = {"stringUnit": {"state": state, "value": cases[case]}}
        localization = {"variations": {"plural": built}}
    else:
        value = draft["value"]
        _check(key, value, False, source)
        localization = {"stringUnit": {"state": state, "value": value}}
    localizations = dict(entry.get("localizations") or {})
    localizations[locale] = localization
    entry["localizations"] = {name: localizations[name] for name in sorted(localizations)}


# --------------------------------------------------------------------------- #
# File walk (verify-by-run)
# --------------------------------------------------------------------------- #

def _catalogs(root: str) -> list[str]:
    return [os.path.relpath(p, root) for p in gate.catalog_paths(root)]


def _search_dir(catalog: str) -> str:
    folder = os.path.dirname(catalog)
    return os.path.dirname(folder) if os.path.basename(folder) == "Resources" else folder


def _swift_lines(root: str, folder: str) -> list[tuple[str, int, str]]:
    found = []
    for directory, _, files in os.walk(os.path.join(root, folder)):
        for name in files:
            if name.endswith(".swift"):
                path = os.path.join(directory, name)
                with open(path, encoding="utf-8", errors="replace") as handle:
                    for number, line in enumerate(handle, 1):
                        found.append((os.path.relpath(path, root), number, line.strip()))
    return found


def export(root: str, out_dir: str, batch: int) -> int:
    os.makedirs(out_dir, exist_ok=True)
    count = 0
    for catalog in _catalogs(root):
        with open(os.path.join(root, catalog), encoding="utf-8") as handle:
            strings = json.load(handle).get("strings") or {}
        is_plist = os.path.basename(catalog) == "InfoPlist.xcstrings"
        lines = [] if is_plist else _swift_lines(root, _search_dir(catalog))
        items = []
        for key, entry in sorted(translatable(strings)):
            english = source_text(key, entry)
            en = (entry.get("localizations") or {}).get(gate.SOURCE_LANGUAGE) or {}
            pattern = re.compile(source_pattern(key))
            sites = [f"{p}:{n}: {t[:_SWIFT_LINE_CAP]}" for p, n, t in lines if pattern.search(t)][:3]
            kinds = set(gate.specifiers(key).values())
            items.append({
                "catalog": catalog,
                "key": key,
                "english": english,
                "comment": entry.get("comment", ""),
                "kind": "phrases" if "stringSet" in en else "string",
                "english_phrases": (en.get("stringSet") or {}).get("values", []),
                "may_vary_by_plural": kinds == {"int"} and len(gate.specifiers(key)) == 1,
                "review": is_plist or privacy_hint(english),
                "sites": sites if not is_plist else [f"Info.plist key {key} (a system permission prompt)"],
            })
        for start in range(0, len(items), batch):
            chunk = items[start:start + batch]
            name = re.sub(r"[^A-Za-z0-9]+", "-", catalog).strip("-") + f"-{start // batch:02d}.json"
            with open(os.path.join(out_dir, name), "w", encoding="utf-8") as handle:
                json.dump(chunk, handle, ensure_ascii=False, indent=1)
            count += 1
    print(f"exported {count} batches to {out_dir}")
    return 0


def _write_atomically(path: str, text: str) -> None:
    temp = f"{path}.tmp-{os.getpid()}"
    with open(temp, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(temp, path)


def _row_id(row: dict) -> tuple[str, str, str]:
    return (row["locale"], row["catalog"], row["key"])


APPROVALS = "docs/l10n/approved.json"


def _load_approvals(path: str | None) -> dict[tuple[str, str, str], str]:
    """(locale, catalog, key) → the English a native reader approved the translation against."""
    if not path or not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        return {_row_id(row): row["english"] for row in json.load(handle)}


def _save_approvals(path: str, approvals: dict[tuple[str, str, str], str]) -> None:
    rows = [{"catalog": c, "english": e, "key": k, "locale": loc} for (loc, c, k), e in sorted(approvals.items())]
    _write_atomically(path, json.dumps(rows, ensure_ascii=False, indent=1) + "\n")


def apply(
    root: str, path: str, rejects_path: str | None, hold_path: str | None = None, approved: bool = False,
    locales: list[str] | None = None, approvals_path: str | None = None,
) -> int:
    """Write drafts into the catalogs.

    A row that `needs_native_read` (or that its draft flags) is held in `hold_path`, merged with what the
    file already holds, so unread privacy copy never ships (the nightly DMG ships master). Without a hold
    file such a row is refused, never written. `approved` (after the native read) writes every row as
    translated and drops the written rows from the hold file (pass the same file to both: one reader's approval at a
    time with `locales`). Holding a row also retracts any translation the catalog already has for it. Rows for
    other `locales` are left alone, in the catalogs and in the hold file. Each catalog is written whole, atomically.
    With `approvals_path`, an approved write is recorded there with its English, and a row whose approval still
    matches the English is kept as the reader approved it: a later draft neither replaces nor holds it. Pass only
    the pending file with `approved`: a drafts file there would skip the native read.
    Exit 0 when every row landed or was held, 1 when anything was rejected.
    """
    with open(path, encoding="utf-8") as handle:
        drafts = json.load(handle)
    held_before: list[dict] = []
    if hold_path and os.path.exists(hold_path):
        with open(hold_path, encoding="utf-8") as handle:
            held_before = json.load(handle)
    held = {_row_id(row): row for row in held_before}
    approvals = _load_approvals(approvals_path)
    approvals_before = dict(approvals)
    by_catalog: dict[str, list[dict]] = {}
    applied, kept, rejects = 0, 0, []
    for draft in drafts:
        if locales and draft.get("locale") not in locales:
            continue
        if not all(isinstance(draft.get(field), str) for field in ("catalog", "key", "locale")):
            rejects.append({**draft, "why": "a row needs catalog, key and locale"})
            continue
        by_catalog.setdefault(draft["catalog"], []).append(draft)
    for catalog, rows in sorted(by_catalog.items()):
        full = os.path.join(root, catalog)
        if not os.path.isfile(full):
            rejects.extend({**row, "why": "no such catalog"} for row in rows)
            continue
        with open(full, encoding="utf-8") as handle:
            text = handle.read()
        data = json.loads(text)
        strings = data.get("strings") or {}
        for row in rows:
            entry = strings.get(row["key"])
            if entry is None:
                rejects.append({**row, "why": "key not in catalog"})
                continue
            if not entry.get("shouldTranslate", True):
                rejects.append({**row, "why": "the catalog marks this key do-not-translate"})
                continue
            english = source_text(row["key"], entry)
            if not approved and approvals.get(_row_id(row)) == english:
                kept += 1  # a native reader approved what ships; a new draft waits for a new read
                continue
            private = (bool(row.get("review")) or _row_id(row) in held
                       or needs_native_read(catalog, english))
            try:
                if private and not approved:
                    if not hold_path:
                        raise ValueError("privacy copy needs --hold-review (or --approved after the native read)")
                    apply_one(json.loads(json.dumps(entry)), row["key"], row["locale"], row, True)  # validate only
                    held[_row_id(row)] = {**row, "review": True}
                    _retract(entry, row["locale"])
                    continue
                apply_one(entry, row["key"], row["locale"], row, False)
                held.pop(_row_id(row), None)
                if approved and private:
                    approvals[_row_id(row)] = english
                applied += 1
            except ValueError as error:
                rejects.append({**row, "why": str(error)})
        out = dumps(data)
        if not text.endswith("\n"):
            out = out.rstrip("\n")
        _write_atomically(full, out)
    print(f"applied {applied}, held for the native read {len(held)} (was {len(held_before)}), "
          f"kept as approved {kept}, rejected {len(rejects)}")
    if approvals_path and approvals != approvals_before:
        _save_approvals(approvals_path, approvals)
    if hold_path and (held or held_before):
        rows = sorted(held.values(), key=lambda r: (r["locale"], r["catalog"], r["key"]))
        _write_atomically(hold_path, json.dumps(rows, ensure_ascii=False, indent=1) + "\n")
    if rejects_path:
        with open(rejects_path, "w", encoding="utf-8") as handle:
            json.dump(rejects, handle, ensure_ascii=False, indent=1)
    for reject in rejects[:20]:
        print(f"  reject {reject.get('locale')} {reject.get('catalog')}: {reject['why']}")
    return 0 if not rejects else 1


def _retract(entry: dict, locale: str) -> dict | None:
    """Remove `locale`'s translation from `entry`; returns what was there."""
    localizations = entry.get("localizations") or {}
    removed = localizations.pop(locale, None)
    if not localizations:
        entry.pop("localizations", None)
    return removed


def _draft_of(localization: dict) -> dict:
    """A shipped localization back in draft form (value / values / plural)."""
    if "stringSet" in localization:
        return {"values": localization["stringSet"].get("values") or []}
    plural = (localization.get("variations") or {}).get("plural")
    if plural:
        return {"plural": {case: (unit.get("stringUnit") or {}).get("value", "") for case, unit in plural.items()}}
    return {"value": (localization.get("stringUnit") or {}).get("value", "")}


def sweep(root: str, hold_path: str, approvals_path: str | None = None) -> int:
    """Retract every shipped wave translation the rule now holds (after the rule widens) into the hold file.

    A line a native reader approved against its current English stays (`approvals_path`).
    """
    approvals = _load_approvals(approvals_path)
    held: dict = {}
    if os.path.exists(hold_path):
        with open(hold_path, encoding="utf-8") as handle:
            held = {_row_id(row): row for row in json.load(handle)}
    moved = 0
    for catalog in _catalogs(root):
        full = os.path.join(root, catalog)
        with open(full, encoding="utf-8") as handle:
            text = handle.read()
        data = json.loads(text)
        changed = False
        for key, entry in translatable(data.get("strings") or {}):
            if not needs_native_read(catalog, source_text(key, entry)):
                continue
            english = source_text(key, entry)
            for locale in LOCALES:
                if approvals.get((locale, catalog, key)) == english:
                    continue
                if locale in (entry.get("localizations") or {}):
                    removed = _retract(entry, locale)
                    held[(locale, catalog, key)] = {"catalog": catalog, "key": key, "locale": locale, "review": True,
                                                    **_draft_of(removed or {})}
                    moved += 1
                    changed = True
        if changed:
            out = dumps(data)
            _write_atomically(full, out if text.endswith("\n") else out.rstrip("\n"))
    rows = sorted(held.values(), key=lambda r: (r["locale"], r["catalog"], r["key"]))
    _write_atomically(hold_path, json.dumps(rows, ensure_ascii=False, indent=1) + "\n")
    print(f"retracted {moved} shipped translations into {hold_path} ({len(rows)} held)")
    return 0


def coverage(root: str) -> int:
    print(f"{'catalog':58} " + " ".join(f"{loc:>14}" for loc in LOCALES))
    totals = {loc: [0, 0, 0] for loc in LOCALES}
    for catalog in _catalogs(root):
        with open(os.path.join(root, catalog), encoding="utf-8") as handle:
            strings = json.load(handle).get("strings") or {}
        keys = list(translatable(strings))
        cells = []
        for loc in LOCALES:
            done = review = 0
            for _, entry in keys:
                units = list(gate.string_units((entry.get("localizations") or {}).get(loc) or {}))
                states = {(u or {}).get("state") for _, u, _ in units}
                if units and states == {"translated"}:
                    done += 1
                elif units:
                    review += 1
            totals[loc][0] += done
            totals[loc][1] += review
            totals[loc][2] += len(keys)
            cells.append(f"{done:>4}+{review:<3}/{len(keys):<4}")
        print(f"{catalog:58} " + " ".join(f"{c:>14}" for c in cells))
    print(f"{'TOTAL (translated+needs_review/keys)':58} " + " ".join(
        f"{t[0]:>4}+{t[1]:<3}/{t[2]:<4}" for t in totals.values()))
    return 0


def review_sheet(root: str, pending: str, locale: str, out: str) -> int:
    """The held privacy lines for `locale`, English beside the draft, for a native reader."""
    with open(pending, encoding="utf-8") as handle:
        rows = [r for r in json.load(handle) if r["locale"] == locale]
    english: dict[tuple[str, str], str] = {}
    for catalog in {r["catalog"] for r in rows}:
        with open(os.path.join(root, catalog), encoding="utf-8") as handle:
            strings = json.load(handle).get("strings") or {}
        for key, entry in strings.items():
            english[(catalog, key)] = source_text(key, entry or {})
    with open(out, "w", encoding="utf-8") as handle:
        handle.write(f"# M1K3 privacy copy, {locale}: native read\n\n")
        handle.write("Each line says what leaves the device, what stays, or asks permission. Mark any line "
                     "that promises more or less than the English, or reads unnaturally.\n\n")
        for number, row in enumerate(rows, 1):
            draft = row.get("value") or " / ".join(row.get("values") or []) or json.dumps(row.get("plural"), ensure_ascii=False)
            handle.write(f"{number}. **EN:** {english.get((row['catalog'], row['key']), row['key'])}  \n"
                         f"   **{locale}:** {draft}\n\n")
    print(f"{len(rows)} lines → {out}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", default=".")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("export")
    p.add_argument("out_dir")
    p.add_argument("--batch", type=int, default=45)
    p = sub.add_parser("apply")
    p.add_argument("translations")
    p.add_argument("--rejects")
    p.add_argument("--hold-review", help="hold privacy rows in this file instead of the catalogs")
    p.add_argument("--locale", action="append", dest="locales", help="only these locales (repeatable): one reader at a time")
    p.add_argument("--approved", action="store_true",
                   help="the rows passed the native read: write them as translated (pass the pending file only)")
    p.add_argument("--approvals", default=APPROVALS, help="where approvals are recorded (default %(default)s)")
    p = sub.add_parser("sweep")
    p.add_argument("hold_review", help="the pending file the retracted translations join")
    p.add_argument("--approvals", default=APPROVALS, help="approved lines stay (default %(default)s)")
    sub.add_parser("coverage")
    p = sub.add_parser("review-sheet")
    p.add_argument("pending")
    p.add_argument("locale")
    p.add_argument("out")
    args = parser.parse_args(argv)
    if args.command == "export":
        return export(args.root, args.out_dir, args.batch)
    if args.command == "apply":
        return apply(args.root, args.translations, args.rejects, args.hold_review, args.approved, args.locales,
                     os.path.join(args.root, args.approvals))
    if args.command == "sweep":
        return sweep(args.root, args.hold_review, os.path.join(args.root, args.approvals))
    if args.command == "coverage":
        return coverage(args.root)
    return review_sheet(args.root, args.pending, args.locale, args.out)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
