#!/bin/zsh
# Localisation launch arguments for the screengrab lanes (l10n Phase 0, 2026-11-19).
#
# Sourced by capture.sh, direct/capture-direct.sh, direct/hud-capture.sh and capture-look.sh.
# Reads three opt-in environment variables and sets two things:
#
#   PSEUDO=1        -NSDoubleLocalizedStrings YES      (every localised string doubled: undoubled
#                                                       text on a plate is a string not yet wrapped)
#   RTL=1           -AppleTextDirection YES -NSForceRightToLeftWritingDirection YES
#   LOCALE=<code>   -AppleLanguages "(<code>)" -AppleLocale <code>     (e.g. LOCALE=de, LOCALE=pt-BR)
#
#   l10n_args    the launch arguments above, in that order (empty when none is set)
#   l10n_suffix  "pseudo", "rtl", the code, joined with "-" (empty when none is set): a lane files a
#                localised run under <its usual folder>-<suffix>, so it never overwrites the English plates
#
# With none set, both are empty and every lane launches exactly as before.
# A LOCALE that is not a plain language tag (letters, digits, - and _) is refused (exit 2), so nothing
# odd reaches argv or a folder name.
#
#   zsh tools/screengrab/l10n-args.zsh --print     one argument per line, then "suffix=<suffix>"
#
# Signed: Kev + claude-opus-5-5, 2026-11-19, Confidence 0.7 (zsh -n checked and pinned by
# test_l10n_args.py; no capture run with it yet). Prior: none (new file).

l10n_args=()
l10n_suffix_parts=()
if [[ ${PSEUDO:-0} == 1 ]]; then
  l10n_args+=(-NSDoubleLocalizedStrings YES)
  l10n_suffix_parts+=(pseudo)
fi
if [[ ${RTL:-0} == 1 ]]; then
  l10n_args+=(-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES)
  l10n_suffix_parts+=(rtl)
fi
if [[ -n ${LOCALE:-} ]]; then
  if [[ ! $LOCALE =~ '^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$' ]]; then
    print -u2 "LOCALE=$LOCALE is not a language tag (e.g. de, fr, pt-BR, es_MX)"
    exit 2
  fi
  l10n_args+=(-AppleLanguages "($LOCALE)" -AppleLocale $LOCALE)
  l10n_suffix_parts+=($LOCALE)
fi
l10n_suffix=${(j:-:)l10n_suffix_parts}
unset l10n_suffix_parts

if [[ ${1:-} == --print && $ZSH_EVAL_CONTEXT == toplevel ]]; then
  print -rl -- "${l10n_args[@]}"
  print -r -- "suffix=$l10n_suffix"
fi
