#!/usr/bin/env python3
"""Render the two brand images that bake in copy: site/og.png (the share card)
and assets/brand/readme-hero.png (the README banner).

    python3 tools/site/render_brand_images.py            # both
    python3 tools/site/render_brand_images.py og         # just one (og | readme-hero)

Each image is an HTML template under tools/site/brand/ rendered by headless
Chrome at the image's exact size. The script serves the repo root on a
loopback port for the length of the run, so the templates load the site's own
self-hosted faces (site/fonts.css), its vendored THREE.js and Fox.glb: no
network. A template sets document.title to "ready" once its fonts (and, for
og, the fox) are in, or to "error: …"; the script waits for that over the
DevTools protocol (--remote-debugging-pipe, stdlib only) and only then takes
the screenshot, so a half-drawn PNG is never written.

Needs Google Chrome (or set CHROME to a Chromium-family binary).

Signed: Kev + claude-opus-5-5, 2026-10-02, Confidence 0.8. Prior: Unknown (new
file; the June og.png and the July/September readme-hero.png left no generator
in the tree, so the tagline change from "Nothing leaves." to "Private by
design." (ADR 0006) had nothing to re-run). Why the pipe and not
--screenshot: on macOS, Chrome 154's headless --screenshot / --dump-dom fire at
the load event (before the fox's GLB arrives, --virtual-time-budget or not) and
then never exit. The templates copy the hero's look by hand: index.html's CSS
and THREE scene are the source of truth, these are copies, and a hero restyle
owes a re-render here.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import fcntl
import functools
import json
import os
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[3]
BRAND_DIR = Path(__file__).resolve().parent / "brand"
DEFAULT_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
READY_TIMEOUT_S = 60


@dataclass(frozen=True)
class Target:
    name: str
    template: str      # file under tools/site/brand/
    output: str        # repo-relative PNG path
    width: int
    height: int


TARGETS: dict[str, Target] = {
    "og": Target("og", "og.html", "site/og.png", 1200, 630),
    "readme-hero": Target("readme-hero", "readme-hero.html", "assets/brand/readme-hero.png", 1280, 420),
}


def licence_abbreviation(license_text: str) -> str:
    """The SPDX-style id under LICENSE's "## Abbreviation" heading."""
    match = re.search(r"^## Abbreviation\s*\n\s*\n?\s*(\S+)", license_text, re.MULTILINE)
    if not match:
        raise ValueError("LICENSE has no '## Abbreviation' section")
    return match.group(1)


def template_url(port: int, target: Target) -> str:
    rel = (BRAND_DIR / target.template).relative_to(REPO).as_posix()
    return f"http://127.0.0.1:{port}/{rel}"


def chrome_args(chrome: str, profile: Path) -> list[str]:
    """Headless Chrome speaking DevTools on fds 3 (in) and 4 (out), on a bare
    profile: no Keychain prompt, no background services."""
    return [
        chrome,
        "--headless=new",
        "--remote-debugging-pipe",
        "--hide-scrollbars",
        "--force-device-scale-factor=1",
        "--no-first-run",
        "--no-default-browser-check",
        "--use-mock-keychain",
        "--password-store=basic",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-extensions",
        "--disable-sync",
        f"--user-data-dir={profile}",
        "about:blank",
    ]


def encode(message: dict[str, Any]) -> bytes:
    """One DevTools-pipe frame: JSON, NUL-terminated."""
    return json.dumps(message).encode() + b"\0"


def split_frames(buffer: bytes) -> tuple[list[dict[str, Any]], bytes]:
    """Complete frames out of `buffer`, plus the partial tail to keep."""
    *frames, tail = buffer.split(b"\0")
    return [json.loads(frame) for frame in frames if frame], tail


def readiness(title: str) -> str | None:
    """'ready' / the error a template reported / None while it is still loading."""
    if title == "ready":
        return "ready"
    if title.startswith("error"):
        return title
    return None


class DevTools:
    """A minimal client for Chrome's --remote-debugging-pipe. `args` is the
    whole command line (chrome_args in production, a stub in the tests)."""

    def __init__(self, args: list[str], *, call_timeout_s: float = 30, close_timeout_s: float = 10) -> None:
        self.call_timeout_s = call_timeout_s
        self.close_timeout_s = close_timeout_s
        to_chrome_r, self._to_chrome = os.pipe()
        self._from_chrome, from_chrome_w = os.pipe()
        self._stderr = tempfile.TemporaryFile()

        def wire_fds() -> None:
            # Chrome reads commands on fd 3 and answers on fd 4. Lift both ends
            # clear of 3/4 first, so one dup2 can't clobber the other.
            high_r = fcntl.fcntl(to_chrome_r, fcntl.F_DUPFD, 10)
            high_w = fcntl.fcntl(from_chrome_w, fcntl.F_DUPFD, 10)
            os.dup2(high_r, 3)
            os.dup2(high_w, 4)

        try:
            self.proc = subprocess.Popen(  # noqa: PLW1509 — preexec_fn only wires fds in the forked child
                args,
                stdout=subprocess.DEVNULL, stderr=self._stderr,
                preexec_fn=wire_fds, pass_fds=(3, 4), start_new_session=True,
            )
        except BaseException:
            for fd in (to_chrome_r, self._to_chrome, self._from_chrome, from_chrome_w):
                os.close(fd)
            self._stderr.close()
            raise
        os.close(to_chrome_r)
        os.close(from_chrome_w)
        self._next_id = 0
        self._buffer = b""

    def call(self, method: str, params: dict[str, Any] | None = None, session: str | None = None) -> dict[str, Any]:
        self._next_id += 1
        message: dict[str, Any] = {"id": self._next_id, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = session
        os.write(self._to_chrome, encode(message))
        deadline = time.monotonic() + self.call_timeout_s
        while True:
            for frame in self._read_frames(deadline, method):
                if frame.get("id") == self._next_id:
                    if "error" in frame:
                        raise RuntimeError(f"{method}: {frame['error']}")
                    return frame.get("result", {})

    def _read_frames(self, deadline: float, method: str) -> list[dict[str, Any]]:
        remaining = deadline - time.monotonic()
        ready, _, _ = select.select([self._from_chrome], [], [], max(0.0, remaining))
        if not ready:
            raise TimeoutError(f"{method}: no answer from Chrome in {self.call_timeout_s:.0f}s")
        chunk = os.read(self._from_chrome, 1 << 20)
        if not chunk:
            raise RuntimeError(f"Chrome closed the DevTools pipe{self._stderr_tail()}")
        frames, self._buffer = split_frames(self._buffer + chunk)
        return frames

    def _stderr_tail(self) -> str:
        self._stderr.seek(0)
        tail = self._stderr.read().decode(errors="replace").strip().splitlines()[-5:]
        return (":\n  " + "\n  ".join(tail)) if tail else ""

    def close(self) -> None:
        try:
            os.write(self._to_chrome, encode({"id": 0, "method": "Browser.close"}))
        except OSError:
            pass
        try:
            self.proc.wait(timeout=self.close_timeout_s)
        except subprocess.TimeoutExpired:
            # Chrome's helpers share its session; take the whole group down.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.wait(timeout=10)
        os.close(self._to_chrome)
        os.close(self._from_chrome)
        self._stderr.close()


def png_size(data: bytes) -> tuple[int, int]:
    """Width and height from a PNG's IHDR chunk."""
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("not a PNG")
    return struct.unpack(">II", data[16:24])


def render(target: Target, chrome: str, port: int) -> Path:
    with tempfile.TemporaryDirectory(prefix="m1k3-brand-") as profile:
        devtools = DevTools(chrome_args(chrome, Path(profile)))
        try:
            target_id = devtools.call("Target.createTarget", {"url": "about:blank"})["targetId"]
            session = devtools.call("Target.attachToTarget", {"targetId": target_id, "flatten": True})["sessionId"]
            devtools.call(
                "Emulation.setDeviceMetricsOverride",
                {"width": target.width, "height": target.height, "deviceScaleFactor": 1, "mobile": False},
                session,
            )
            nav = devtools.call("Page.navigate", {"url": template_url(port, target)}, session)
            if nav.get("errorText"):
                raise RuntimeError(f"{target.name}: navigation failed ({nav['errorText']})")
            state, deadline = None, time.monotonic() + READY_TIMEOUT_S
            while state is None:
                if time.monotonic() > deadline:
                    raise TimeoutError(f"{target.name}: not ready after {READY_TIMEOUT_S}s")
                time.sleep(0.25)
                try:
                    title = devtools.call(
                        "Runtime.evaluate", {"expression": "document.title", "returnByValue": True}, session
                    )["result"].get("value", "")
                except RuntimeError:   # the context swapped mid-navigation; ask again
                    continue
                state = readiness(title)
            if state != "ready":
                raise RuntimeError(f"{target.name}: {state}")
            time.sleep(0.5)   # one more composited frame after the last draw
            shot = devtools.call(
                "Page.captureScreenshot",
                {"format": "png", "clip": {"x": 0, "y": 0, "width": target.width, "height": target.height, "scale": 1}},
                session,
            )
        finally:
            devtools.close()
    data = base64.b64decode(shot["data"])
    if png_size(data) != (target.width, target.height):
        raise RuntimeError(f"{target.name}: Chrome returned {png_size(data)}, wanted {(target.width, target.height)}")
    out = REPO / target.output
    tmp = out.with_suffix(".png.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, out)
    return out


# Only what the templates load is served: never the whole repo (gitignored
# private files live there too).
SERVED_PREFIXES = ("/site/", "/macos/tools/site/brand/")


def is_served(path: str) -> bool:
    clean = path.split("?", 1)[0].split("#", 1)[0]
    return ".." not in clean and clean.startswith(SERVED_PREFIXES)


@functools.cache
def _handler() -> type[SimpleHTTPRequestHandler]:
    class AllowListed(SimpleHTTPRequestHandler):
        def send_head(self):  # type: ignore[override]
            if not is_served(self.path):
                self.send_error(404)
                return None
            return super().send_head()

        def list_directory(self, path):  # type: ignore[override]
            self.send_error(404)
            return None

        def log_message(self, *_: object) -> None:  # the run prints its own summary
            pass

    return AllowListed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("targets", nargs="*", metavar="target", help=f"{' | '.join(TARGETS)} (default: all)")
    args = parser.parse_args(argv)
    unknown = [name for name in args.targets if name not in TARGETS]
    if unknown:
        parser.error(f"unknown target(s): {', '.join(unknown)}")
    chrome = os.environ.get("CHROME", DEFAULT_CHROME)
    if not Path(chrome).exists():
        print(f"render_brand_images: no Chrome at {chrome} (set CHROME)", file=sys.stderr)
        return 2

    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(_handler(), directory=str(REPO)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for name in args.targets or TARGETS:
            out = render(TARGETS[name], chrome, server.server_address[1])
            print(f"wrote {out.relative_to(REPO)}")
    finally:
        server.shutdown()
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
