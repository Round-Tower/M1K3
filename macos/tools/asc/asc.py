"""App Store Connect API client for the app.m1k3 record — the one copy.

Every listing script in this directory imports `call`, `paginate` and
`APP_ID` from here. The launch-day scripts (keywords, pricing, submit) lived
in a session scratchpad and died with it; this module is their durable home.

Auth: an ES256 JWT signed from the on-disk key. Two conventions are read, in
order — the fastlane JSON at `~/.appstoreconnect/private_keys/asc_api_key.json`
(`key_id`, `issuer_id`, `key` — what the Fastfile reads), then the env pair
`ASC_KEY_ID` + `ASC_KEY_ISSUER_ID` with `AuthKey_<id>.p8` beside it (what the
Lexy tools read). Nothing is read at import time, so pytest never needs a key.

Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.85
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: dyslexia-ai/ios/marketing/tools/asc.py (Kev + claude-fable-5, 2026-08),
  ported; the JSON-key convention and `paginate` are new here.
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any, Iterator

BASE = "https://api.appstoreconnect.apple.com"
APP_ID = "6780230835"  # the one universal record: Mac + iOS + visionOS
AUDIENCE = "appstoreconnect-v1"
KEY_DIR = Path("~/.appstoreconnect/private_keys").expanduser()
PLATFORMS = ("MAC_OS", "IOS", "VISION_OS")


def credentials(key_dir: Path = KEY_DIR, environ: dict[str, str] | None = None) -> tuple[str, str, str]:
    """(key_id, issuer_id, pem). JSON convention first, env pair second."""
    env = os.environ if environ is None else environ
    json_path = key_dir / "asc_api_key.json"
    if json_path.exists():
        data = json.loads(json_path.read_text())
        return data["key_id"], data["issuer_id"], data["key"]
    key_id = env["ASC_KEY_ID"]
    pem = (key_dir / f"AuthKey_{key_id}.p8").read_text()
    return key_id, env["ASC_KEY_ISSUER_ID"], pem


def jwt_claims(issuer_id: str, now: int, ttl: int = 900) -> dict[str, Any]:
    """The claim set ASC accepts (ttl <= 1200 s)."""
    return {"iss": issuer_id, "iat": now, "exp": now + ttl, "aud": AUDIENCE}


def token() -> str:
    import jwt  # PyJWT — lazy so pytest needs no key material or the dep

    key_id, issuer, pem = credentials()
    return jwt.encode(jwt_claims(issuer, int(time.time())), pem, algorithm="ES256", headers={"kid": key_id})


def call(method: str, path: str, **kw: Any) -> dict[str, Any]:
    """One request. Errors come back as `{'_error': status_or_'transport', '_body': ...}`
    so every caller makes the same `'_error' in result` check."""
    import requests  # lazy, see token()

    url = path if path.startswith("http") else BASE + path
    headers = kw.pop("headers", {})
    headers["Authorization"] = f"Bearer {token()}"
    if "json" in kw:
        headers["Content-Type"] = "application/json"
    try:
        r = requests.request(method, url, headers=headers, timeout=120, **kw)
    except requests.RequestException as exc:
        return {"_error": "transport", "_body": str(exc)[:600]}
    if r.status_code >= 400:
        return {"_error": r.status_code, "_body": r.text[:600]}
    if r.content and "json" in r.headers.get("content-type", ""):
        return r.json()
    return {"_status": r.status_code}


def paginate(path: str) -> Iterator[dict[str, Any]]:
    """Yield every `data` item across `links.next` pages; raises on an error page."""
    page: str | None = path
    while page:
        resp = call("GET", page)
        if "_error" in resp:
            raise RuntimeError(f"GET {page} -> {resp['_error']}: {resp.get('_body', '')[:300]}")
        yield from resp.get("data", [])
        page = resp.get("links", {}).get("next")


def bail(step: str, resp: dict[str, Any]) -> None:
    raise SystemExit(f"FAILED at {step}:\n{json.dumps(resp, indent=2)[:1200]}")
