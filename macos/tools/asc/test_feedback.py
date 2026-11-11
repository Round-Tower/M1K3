"""Pins for feedback.py's pure half, on made-up fixtures: no live tester feedback is ever committed."""
from __future__ import annotations

import json
from pathlib import Path

import feedback as f

BUILDS = {"b-mac": "MAC_OS", "b-ios": "IOS"}


def submission(kind: str, sid: str, build: str, **attrs) -> tuple[str, dict]:
    # As the live list sends it: no build relationship. The build is the one the request asked for.
    return build, {"type": kind, "id": sid, "attributes": attrs}


SHOT = submission("betaFeedbackScreenshotSubmissions", "s1", "b-ios", createdDate="2026-11-12T09:00:00Z",
                  comment="The eye button overlaps the mic.\nSecond line.", email="tester@example.com",
                  deviceModel="iPhone18,1", osVersion="27.1", appPlatform="IOS",
                  screenshots=[{"url": "https://example.com/a.png?sig=SECRET", "width": 1, "height": 2}])
CRASH = submission("betaFeedbackCrashSubmissions", "c1", "b-mac", createdDate="2026-11-12T10:00:00Z",
                   comment=None, email="other@example.com", deviceModel="Mac14,6", osVersion="27.0",
                   appPlatform="MAC_OS")


def test_rows_are_newest_first_and_carry_kind_platform_device_and_os():
    rows = f.rows([SHOT, CRASH], BUILDS)
    assert [r["id"] for r in rows] == ["c1", "s1"]
    assert rows[0] == {"id": "c1", "kind": "crash", "at": "2026-11-12T10:00:00Z", "platform": "MAC_OS",
                       "device": "Mac14,6", "os": "27.0", "comment": "", "email": "other@example.com",
                       "screenshots": 0, "screenshot_images": []}
    assert rows[1]["kind"] == "screenshot" and rows[1]["screenshots"] == 1


def test_only_the_asked_builds_are_kept():
    stray = submission("betaFeedbackCrashSubmissions", "c9", "b-other", createdDate="2026-11-12T11:00:00Z")
    assert [r["id"] for r in f.rows([stray, CRASH], BUILDS)] == ["c1"]


def test_the_terminal_line_never_shows_an_email_and_hides_the_words_unless_asked():
    row = f.rows([SHOT], BUILDS)[0]
    quiet = f.line(row, show_text=False)
    assert "tester@example.com" not in quiet and "eye button" not in quiet
    assert "screenshot" in quiet and "IOS" in quiet and "iPhone18,1" in quiet and "27.1" in quiet
    assert "comment: 45 chars" in quiet
    loud = f.line(row, show_text=True)
    assert "The eye button overlaps the mic. Second line." in loud  # one line, newlines folded
    assert "tester@example.com" not in loud


def test_the_summary_counts_by_kind_and_platform():
    assert f.summary(f.rows([SHOT, CRASH], BUILDS)) == "2 item(s): 1 crash on MAC_OS, 1 screenshot on IOS"
    assert f.summary([]) == "no feedback"


def test_the_saved_record_keeps_everything_and_lands_outside_the_repo(tmp_path):
    rows = f.rows([SHOT, CRASH], BUILDS)
    path = f.save(tmp_path, "546", rows, {"c1": "Thread 0 crashed"})
    saved = json.loads(path.read_text())
    assert saved["build"] == "546" and len(saved["items"]) == 2
    assert saved["items"][0]["crash_log"] == "Thread 0 crashed"
    assert saved["items"][1]["email"] == "tester@example.com"
    assert oct(path.stat().st_mode & 0o777) == "0o600"
    # The default folder is the release cache, never a path inside the checkout.
    assert f.REPO not in f.OUT_DIR.parents and f.OUT_DIR != f.REPO


def test_there_is_no_write_verb():
    source = Path(f.__file__).read_text(encoding="utf-8")
    for verb in ('"POST"', '"PATCH"', '"DELETE"', '"PUT"'):
        assert verb not in source


def test_an_item_returned_under_both_platform_builds_is_listed_once():
    twin = ("b-mac", CRASH[1])
    again = ("b-ios", CRASH[1])
    assert [r["id"] for r in f.rows([twin, again], BUILDS)] == ["c1"]


def test_a_testers_escape_sequences_never_reach_the_terminal():
    nasty = submission("betaFeedbackScreenshotSubmissions", "s2", "b-ios", createdDate="2026-11-12T09:00:00Z",
                       comment="hello\x1b]0;owned\x07 there\x1b[2J", appPlatform="IOS")
    shown = f.line(f.rows([nasty], BUILDS)[0], show_text=True)
    assert "\x1b" not in shown and "\x07" not in shown and "hello" in shown and "there" in shown


def test_the_signed_screenshot_links_are_saved_and_never_printed(tmp_path):
    rows = f.rows([SHOT], BUILDS)
    assert "example.com" not in f.line(rows[0], show_text=True)
    saved = json.loads(f.save(tmp_path, "546", rows, {}).read_text())
    assert saved["items"][0]["screenshot_images"][0]["url"].startswith("https://example.com/a.png")


def test_a_later_run_without_logs_keeps_the_logs_already_fetched(tmp_path):
    rows = f.rows([CRASH], BUILDS)
    f.save(tmp_path, "546", rows, {"c1": "Thread 0 crashed"})
    again = json.loads(f.save(tmp_path, "546", rows, {}).read_text())
    assert again["items"][0]["crash_log"] == "Thread 0 crashed"


def run_main(monkeypatch, tmp_path, argv, found):
    monkeypatch.setattr(f, "OUT_DIR", tmp_path / "out")
    monkeypatch.setattr(f, "build_ids", lambda build: dict(BUILDS))
    monkeypatch.setattr(f, "submissions", lambda kind, ids: found if "Screenshot" in kind else [])
    monkeypatch.setattr("sys.argv", ["feedback.py", *argv])
    return f.main()


def test_main_prints_no_email_and_no_words_unless_asked(monkeypatch, tmp_path, capsys):
    assert run_main(monkeypatch, tmp_path, ["list", "--build", "546"], [SHOT]) == 0
    quiet = capsys.readouterr().out
    assert "tester@example.com" not in quiet and "eye button" not in quiet and "SECRET" not in quiet
    assert (tmp_path / "out" / "build-546.json").exists()
    assert run_main(monkeypatch, tmp_path, ["list", "--build", "546", "--text"], [SHOT]) == 0
    loud = capsys.readouterr().out
    assert "eye button" in loud and "tester@example.com" not in loud and "SECRET" not in loud


def test_main_writes_nothing_when_there_is_no_feedback(monkeypatch, tmp_path, capsys):
    assert run_main(monkeypatch, tmp_path, ["list", "--build", "546"], []) == 0
    assert "no feedback" in capsys.readouterr().out
    assert not (tmp_path / "out").exists()


def test_main_refuses_a_build_that_is_not_a_number(monkeypatch, tmp_path, capsys):
    assert run_main(monkeypatch, tmp_path, ["list", "--build", "../546"], []) == 2
