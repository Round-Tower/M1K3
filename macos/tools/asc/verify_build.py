#!/usr/bin/env python3
"""Check the build about to be submitted is the one running on this Mac, then stamp it.

  verify_build.py --build N     installed /Applications/M1K3.app is build N, it is running,
                                and its MCP server answers initialize with instructions.
                                On a pass, writes the stamp `submit.py submit` requires.

Why: on 2026-10-05 the Mac and iOS submissions were cancelled and resubmitted before
anyone had run the new build. This is the minimum smoke; feature checks (the #482
fixes, the voice) still need their own repro, and this check doesn't claim them.

The MCP access token is read from ~/.claude.json (the `m1k3` server entry that
`m1k3 connect claude` writes) or M1K3_MCP_TOKEN, in-process; it is never printed.
No third-party packages.

Signed: Kev + claude-opus-5-5, 2026-10-05, Confidence 0.8, Prior: Unknown. The probe is
the one that told build 442 (no instructions) from 453 (instructions) live on 2026-10-05.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from submit import STAMP_DIR

APP = Path("/Applications/M1K3.app")

# --------------------------------------------------------------------------- #
# Pure (unit-pinned)
# --------------------------------------------------------------------------- #


def parse_mcp_body(body: str) -> dict[str, Any]:
    """Streamable HTTP answers as SSE (`data: {...}`) or plain JSON; return the result."""
    line = next((ln[5:].strip() for ln in body.splitlines() if ln.startswith("data:")), body.strip())
    reply = json.loads(line)
    if "result" not in reply:
        raise ValueError(f"MCP error: {(reply.get('error') or {}).get('message', 'no result')}")
    return reply["result"]


def stale(process_started: float | None, bundle_modified: float | None) -> bool:
    """The running process predates the app on disk: a TestFlight update replaced the bundle,
    but the old binary is still the one answering MCP (review on #490)."""
    return process_started is not None and bundle_modified is not None and process_started < bundle_modified


def is_loopback(url: str) -> bool:
    return urllib.parse.urlparse(url).hostname in ("127.0.0.1", "localhost", "::1")


def problems(installed: str | None, expected: str, running: bool, instructions: str | None,
             stale: bool = False) -> list[str]:
    found = []
    if installed != expected:
        found.append(f"installed build is {installed}, not {expected}: install {expected} from TestFlight")
    if not running:
        found.append("M1K3 is not running: launch it")
    elif stale:
        found.append("M1K3 was launched before this build was installed: quit and relaunch it")
    elif not instructions:
        found.append("the MCP server answered without instructions")
    return found


def write_stamp(stamp_dir: Path, build: str, facts: dict[str, Any]) -> Path:
    stamp_dir.mkdir(parents=True, exist_ok=True)
    path = stamp_dir / f"verified-{build}.json"
    path.write_text(json.dumps({"build": build, "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), **facts}, indent=2))
    return path


# --------------------------------------------------------------------------- #
# Effectful
# --------------------------------------------------------------------------- #


def installed_build() -> str | None:
    try:
        with open(APP / "Contents/Info.plist", "rb") as fh:
            return str(plistlib.load(fh).get("CFBundleVersion"))
    except OSError:
        return None


def running_pid() -> str | None:
    out = subprocess.run(["pgrep", "-f", f"{APP}/Contents/MacOS/M1K3$"], capture_output=True, text=True, check=False)
    pids = out.stdout.split()
    return pids[0] if pids else None


def process_started(pid: str) -> float | None:
    out = subprocess.run(["ps", "-o", "lstart=", "-p", pid], capture_output=True, text=True, check=False)
    try:
        return time.mktime(time.strptime(out.stdout.strip(), "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return None


def bundle_modified() -> float | None:
    try:
        return (APP / "Contents/MacOS/M1K3").stat().st_mtime
    except OSError:
        return None


def mcp_initialize() -> dict[str, Any]:
    server = json.loads(Path("~/.claude.json").expanduser().read_text()).get("mcpServers", {}).get("m1k3", {})
    url = server.get("url", "http://127.0.0.1:4242/mcp")
    if not is_loopback(url):
        raise ValueError(f"refusing to send the MCP token off this Mac ({urllib.parse.urlparse(url).hostname})")
    headers = dict(server.get("headers", {}))
    if os.environ.get("M1K3_MCP_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['M1K3_MCP_TOKEN']}"
    req = urllib.request.Request(url, headers={**headers, "Content-Type": "application/json",
                                               "Accept": "application/json, text/event-stream"},
                                 data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                                     "protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "verify_build", "version": "1"}}}).encode())
    with urllib.request.urlopen(req, timeout=10) as resp:
        return parse_mcp_body(resp.read().decode())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--build", required=True)
    args = ap.parse_args()
    installed, pid = installed_build(), running_pid()
    running = pid is not None
    is_stale = running and stale(process_started(pid), bundle_modified())
    instructions = None
    if running:
        try:
            instructions = mcp_initialize().get("instructions")
        except Exception as exc:  # noqa: BLE001 — any transport failure is a fail, reported plainly
            # The type, plus our own ValueError text (a JSON-RPC message, never a header).
            print(f"MCP initialize failed: {exc if isinstance(exc, ValueError) else type(exc).__name__}")
    found = problems(installed, args.build, running, instructions, stale=is_stale)
    print(f"installed {installed} · running {running} · instructions {len(instructions or '')} chars")
    if found:
        print("FAIL\n  " + "\n  ".join(found))
        return 1
    path = write_stamp(STAMP_DIR, args.build, {"installed": installed, "instructions_chars": len(instructions)})
    print(f"PASS — stamped {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
