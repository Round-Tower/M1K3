"""Pins for the pure half of asc.py (no key, no network)."""
from __future__ import annotations

import json
from pathlib import Path

import asc


def test_credentials_prefers_the_fastlane_json(tmp_path: Path) -> None:
    (tmp_path / "asc_api_key.json").write_text(json.dumps({"key_id": "K1", "issuer_id": "I1", "key": "PEM"}))
    (tmp_path / "AuthKey_K2.p8").write_text("PEM2")
    assert asc.credentials(tmp_path, {"ASC_KEY_ID": "K2", "ASC_KEY_ISSUER_ID": "I2"}) == ("K1", "I1", "PEM")


def test_credentials_falls_back_to_the_env_pair(tmp_path: Path) -> None:
    (tmp_path / "AuthKey_K2.p8").write_text("PEM2")
    assert asc.credentials(tmp_path, {"ASC_KEY_ID": "K2", "ASC_KEY_ISSUER_ID": "I2"}) == ("K2", "I2", "PEM2")


def test_jwt_claims_shape() -> None:
    assert asc.jwt_claims("iss", 1000) == {"iss": "iss", "iat": 1000, "exp": 1900, "aud": "appstoreconnect-v1"}
    assert asc.jwt_claims("iss", 1000)["exp"] - 1000 <= 1200  # ASC rejects longer tokens
