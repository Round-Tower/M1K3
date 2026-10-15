"""Pins for check_company_name: the old "Software Studios" name fails CI (#574),
except where it is still literally true (Apple's certificates) or is history.

Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.9. Prior: none (new file).
"""
import check_company_name as m

OLD = "Round Tower Software " + "Studios Ltd"  # split so this file never matches itself


def test_the_old_name_fails_wherever_a_reader_sees_it():
    assert m.offenders("site/x.html", f"<span>© 2026 {OLD.upper()}</span>\n") == [(1, f"<span>© 2026 {OLD.upper()}</span>")]
    assert m.offenders("LICENSE", f"MIT\nCopyright 2026 {OLD}\n") == [(2, f"Copyright 2026 {OLD}")]
    assert m.offenders("NOTICE", "developed by Round Tower Software\nStudios Ltd and contributors\n") == [
        (1, "developed by Round Tower Software")]


def test_the_new_name_passes():
    assert m.offenders("LICENSE", "Copyright 2026 Round Tower Software Ltd\n") == []


def test_apples_certificates_keep_the_old_name_until_the_apps_move():
    for line in (f"Signing identity: **Developer ID Application: {OLD}", f'"Apple Distribution: {OLD} (76DJH43A4P)"'):
        assert m.offenders("macos/tools/release/README.md", line + "\n") == [], line


def test_dated_provenance_is_history_not_a_claim():
    html = f"<p>ok</p>\n<!-- Review: Kev, 2026-10-02 — the footer names\n     {OLD}. -->\n<p>{OLD}</p>\n"
    assert m.offenders("site/x.html", html) == [(4, f"<p>{OLD}</p>")], "line numbers survive the strip"
    md = f"Terms.\n\n*Review: Kev, 2026-10-02 — the grant runs to\n{OLD} (was …). Confidence 0.8.*\n"
    assert m.offenders("CLA.md", md) == []
    # outside a provenance paragraph the same name still fails
    assert m.offenders("CLA.md", f"   {OLD} and to every recipient\n") == [(1, f"   {OLD} and to every recipient")]


def test_the_guard_skips_itself():
    assert m.scannable("macos/tools/ci/check_company_name.py") is False
    assert m.scannable("macos/tools/ci/test_check_company_name.py") is False
    assert m.scannable("site/index.html") is True
