# Signed: Kev + claude-opus-5-5, 2026-11-19, Confidence 0.75, Prior: none (new file).
# Pins l10n-args.zsh (l10n Phase 0): the exact launch arguments PSEUDO=1 / RTL=1 / LOCALE=<code> add, that none
# set adds nothing (every lane launches as before), that a LOCALE which is not a language tag is refused, and
# that every screengrab lane sources the helper and passes its arguments on.
from __future__ import annotations

import os
import subprocess
from pathlib import Path

HERE = Path(__file__).parent
HELPER = HERE / "l10n-args.zsh"
LANES = {
    "capture.sh": HERE / "capture.sh",
    "capture-look.sh": HERE / "capture-look.sh",
    "direct/capture-direct.sh": HERE / "direct" / "capture-direct.sh",
    "direct/hud-capture.sh": HERE / "direct" / "hud-capture.sh",
}


def _env(**extra: str) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in {"PSEUDO", "RTL", "LOCALE"}}
    return {**env, **extra}


def _print(**extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["/bin/zsh", str(HELPER), "--print"],
                          capture_output=True, text=True, env=_env(**extra), timeout=30)


def _args_and_suffix(**extra: str) -> tuple[list[str], str]:
    r = _print(**extra)
    assert r.returncode == 0, r.stderr
    lines = r.stdout.splitlines()
    assert lines[-1].startswith("suffix="), r.stdout
    return [line for line in lines[:-1] if line], lines[-1].removeprefix("suffix=")


def test_nothing_set_adds_nothing() -> None:
    assert _args_and_suffix() == ([], "")


def test_zero_values_add_nothing() -> None:
    assert _args_and_suffix(PSEUDO="0", RTL="0", LOCALE="") == ([], "")


def test_pseudo_doubles_strings() -> None:
    assert _args_and_suffix(PSEUDO="1") == (["-NSDoubleLocalizedStrings", "YES"], "pseudo")


def test_rtl_forces_right_to_left() -> None:
    assert _args_and_suffix(RTL="1") == (
        ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"], "rtl")


def test_locale_sets_language_and_region() -> None:
    assert _args_and_suffix(LOCALE="de") == (["-AppleLanguages", "(de)", "-AppleLocale", "de"], "de")
    assert _args_and_suffix(LOCALE="pt-BR") == (
        ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt-BR"], "pt-BR")


def test_options_combine_in_order() -> None:
    assert _args_and_suffix(PSEUDO="1", RTL="1", LOCALE="es_MX") == (
        ["-NSDoubleLocalizedStrings", "YES",
         "-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES",
         "-AppleLanguages", "(es_MX)", "-AppleLocale", "es_MX"],
        "pseudo-rtl-es_MX")


def test_refuses_a_locale_that_is_not_a_language_tag() -> None:
    for bad in ("de;rm -rf ~", "../de", "d", "de BR", "(de)"):
        r = _print(LOCALE=bad)
        assert r.returncode == 2, bad
        assert "not a language tag" in r.stderr


def test_every_lane_sources_the_helper_and_passes_its_arguments() -> None:
    for name, script in LANES.items():
        text = script.read_text()
        assert "l10n-args.zsh" in text and "source " in text, name
        assert "${l10n_args" in text, name
        assert "l10n_suffix:+-$l10n_suffix" in text, f"{name}: a localised run must not overwrite English output"


def test_hud_lane_refuses_a_bad_locale_before_anything_runs(tmp_path: Path) -> None:
    # The helper exits the sourcing script: no app path is even resolved.
    r = subprocess.run(["/bin/zsh", str(LANES["direct/hud-capture.sh"]), str(tmp_path / "none.app"),
                        str(tmp_path / "out")], capture_output=True, text=True,
                       env=_env(LOCALE="x;y", HUD_CAPTURE_CHECK_ONLY="1"), timeout=30)
    assert r.returncode == 2
    assert "not a language tag" in r.stderr
