"""Pins for render_brand_images.py — the sizes the pages declare, the Chrome
run shape, and the copy the images must (and must never again) carry."""
import re
import sys
from pathlib import Path

import pytest
import render_brand_images as rbi

REPO = rbi.REPO


def test_targets_match_the_sizes_the_site_declares():
    index = (REPO / "site/index.html").read_text()
    og = rbi.TARGETS["og"]
    assert f'og:image:width" content="{og.width}"' in index
    assert f'og:image:height" content="{og.height}"' in index
    # The README now shows the animated readme-hero.svg (pinned in test_readme_hero_svg.py).


def test_every_template_exists_and_waits_for_ready():
    for target in rbi.TARGETS.values():
        html = (rbi.BRAND_DIR / target.template).read_text()
        script = html[html.index("<script"):]   # in code, not in a comment above it
        assert "document.title = 'ready'" in script, target.name
        assert "document.fonts.load(" in script, target.name   # explicit loads, not fonts.ready alone
        assert "/site/fonts.css" in html, target.name   # the site's own faces, no Google Fonts hop


def test_templates_carry_the_current_tagline_and_never_the_retired_one():
    for target in rbi.TARGETS.values():
        html = (rbi.BRAND_DIR / target.template).read_text()
        assert "Private by design." in html, target.name
        assert not re.search(r"nothing leaves", html, re.IGNORECASE), target.name


def test_readme_hero_licence_label_is_the_licence_in_the_tree():
    abbreviation = rbi.licence_abbreviation((REPO / "LICENSE").read_text())
    assert abbreviation == "FSL-1.1-ALv2"
    html = (rbi.BRAND_DIR / "readme-hero.html").read_text()
    assert abbreviation in html
    assert "APACHE" not in html.upper()


def test_licence_abbreviation_needs_the_heading():
    assert rbi.licence_abbreviation("# X\n\n## Abbreviation\n\nFSL-1.1-MIT\n\n## Notice\n") == "FSL-1.1-MIT"
    with pytest.raises(ValueError):
        rbi.licence_abbreviation("Apache License 2.0")


def test_template_url_serves_the_template_from_the_repo_root():
    url = rbi.template_url(4321, rbi.TARGETS["readme-hero"])
    assert url == "http://127.0.0.1:4321/macos/tools/site/brand/readme-hero.html"


def test_chrome_runs_headless_on_the_devtools_pipe_with_a_throwaway_profile(tmp_path: Path):
    args = rbi.chrome_args("chrome", tmp_path)
    assert args[0] == "chrome" and args[-1] == "about:blank"
    for flag in ("--headless=new", "--remote-debugging-pipe", "--force-device-scale-factor=1", "--use-mock-keychain"):
        assert flag in args, flag
    assert f"--user-data-dir={tmp_path}" in args


def test_pipe_frames_are_nul_terminated_json_and_partials_wait():
    frame = rbi.encode({"id": 1, "method": "Page.navigate", "params": {"url": "x"}})
    assert frame.endswith(b"\0") and frame.count(b"\0") == 1
    frames, tail = rbi.split_frames(b'{"id":1,"result":{}}\0{"method":"Page.load')
    assert frames == [{"id": 1, "result": {}}]
    assert tail == b'{"method":"Page.load'
    frames, tail = rbi.split_frames(tail + b'EventFired"}\0')
    assert frames == [{"method": "Page.loadEventFired"}] and tail == b""


def test_readiness_waits_for_ready_and_surfaces_a_template_error():
    assert rbi.readiness("og") is None
    assert rbi.readiness("ready") == "ready"
    assert rbi.readiness("error: Fox.glb did not load") == "error: Fox.glb did not load"
    assert rbi.readiness("errors-and-omissions") is None   # only the documented "error: …" form


def test_the_committed_images_are_the_sizes_the_targets_render():
    for target in rbi.TARGETS.values():
        data = (REPO / target.output).read_bytes()
        assert rbi.png_size(data) == (target.width, target.height), target.name
    with pytest.raises(ValueError):
        rbi.png_size(b"GIF89a" + b"\0" * 30)


def test_the_server_serves_only_what_the_templates_load():
    assert rbi.is_served("/site/fonts.css")
    assert rbi.is_served("/site/vendor/Fox.glb?v=1")
    assert rbi.is_served("/macos/tools/site/brand/og.html")
    for private in ("/", "/.claude/project-memory.md", "/.env", "/macos/Package.swift", "/site/../.env"):
        assert not rbi.is_served(private), private


# A stand-in for Chrome on the DevTools pipe: reads NUL-terminated commands on
# fd 3 and answers on fd 4, the way --remote-debugging-pipe does. Each reply is
# preceded by an unrelated event and split across two writes, so the client
# has to filter by id and reassemble partial frames.
STUB = r"""
import json, os, sys, time
mode = sys.argv[1]
buf = b""
while True:
    chunk = os.read(3, 65536)
    if not chunk:
        break
    buf += chunk
    while b"\0" in buf:
        raw, buf = buf.split(b"\0", 1)
        msg = json.loads(raw)
        if msg["method"] == "Browser.close":
            sys.exit(0)
        if mode == "die":
            sys.stderr.write("stub: no GPU for you\n"); sys.stderr.flush(); sys.exit(3)
        if mode == "hang":
            time.sleep(30); continue
        os.write(4, json.dumps({"method": "Page.loadEventFired", "params": {}}).encode() + b"\0")
        reply = {"id": msg["id"]}
        if mode == "error":
            reply["error"] = {"code": -32000, "message": "Cannot find context"}
        else:
            reply["result"] = {"echo": msg["method"]}
        data = json.dumps(reply).encode() + b"\0"
        os.write(4, data[:5]); time.sleep(0.01); os.write(4, data[5:])
"""


def _stub(tmp_path: Path, mode: str) -> list[str]:
    script = tmp_path / "stub_chrome.py"
    script.write_text(STUB)
    return [sys.executable, str(script), mode]


def test_devtools_reassembles_split_frames_and_skips_events(tmp_path: Path):
    devtools = rbi.DevTools(_stub(tmp_path, "ok"), call_timeout_s=10)
    try:
        assert devtools.call("Target.createTarget", {"url": "about:blank"}) == {"echo": "Target.createTarget"}
        assert devtools.call("Page.navigate", {"url": "x"}, session="s1") == {"echo": "Page.navigate"}
    finally:
        devtools.close()
    assert devtools.proc.returncode == 0   # Browser.close let it exit; nothing left running


def test_devtools_raises_on_an_error_frame(tmp_path: Path):
    devtools = rbi.DevTools(_stub(tmp_path, "error"), call_timeout_s=10)
    try:
        with pytest.raises(RuntimeError, match="Cannot find context"):
            devtools.call("Runtime.evaluate", {"expression": "1"})
    finally:
        devtools.close()


def test_devtools_reports_chrome_dying_with_its_stderr(tmp_path: Path):
    devtools = rbi.DevTools(_stub(tmp_path, "die"), call_timeout_s=10)
    try:
        with pytest.raises(RuntimeError, match="no GPU for you"):
            devtools.call("Target.createTarget")
    finally:
        devtools.close()


def test_devtools_times_out_instead_of_hanging(tmp_path: Path):
    devtools = rbi.DevTools(_stub(tmp_path, "hang"), call_timeout_s=0.5, close_timeout_s=0.5)
    try:
        with pytest.raises(TimeoutError):
            devtools.call("Page.captureScreenshot")
    finally:
        devtools.close()   # the stub ignores Browser.close while asleep: close() kills its group
    assert devtools.proc.returncode is not None


def test_main_refuses_an_unknown_target():
    with pytest.raises(SystemExit) as exit_info:
        rbi.main(["nope"])
    assert exit_info.value.code == 2


def test_the_og_card_says_what_the_live_hero_says():
    """The og template copies index.html's hero by hand; pin the line that matters."""
    index = (REPO / "site/index.html").read_text()
    og = (rbi.BRAND_DIR / "og.html").read_text()
    line3 = re.search(r'id="line3">([^<]+)<', og).group(1)
    assert f'id="rotator">{line3}</span>' in index
