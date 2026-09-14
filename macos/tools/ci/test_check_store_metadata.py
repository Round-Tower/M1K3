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
    (tmp_path / "review_information" / "notes.txt").write_text("x" * 5000)
    assert problems(tmp_path) == []
