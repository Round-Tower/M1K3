"""Pins for indexnow.py — the key discovery, sitemap parsing and payload shape."""
from pathlib import Path

import pytest

import indexnow

KEY = "df247e91fdb00bc8b270be929a758b1c"


def _site(tmp_path: Path, key_body: str = KEY, extra_keys: int = 0) -> Path:
    (tmp_path / f"{KEY}.txt").write_text(key_body)
    for i in range(extra_keys):
        (tmp_path / f"{'0' * 31}{i}.txt").write_text("x")
    (tmp_path / "sitemap.xml").write_text(
        "<urlset><url><loc>https://m1k3.app/</loc></url>"
        "<url><loc> https://m1k3.app/install </loc></url>"
        "<url><loc>https://m1k3.app/</loc></url></urlset>"
    )
    return tmp_path


def test_find_key_reads_the_one_hex_file(tmp_path):
    assert indexnow.find_key(_site(tmp_path)) == KEY


def test_find_key_refuses_two_key_files(tmp_path):
    with pytest.raises(SystemExit):
        indexnow.find_key(_site(tmp_path, extra_keys=1))


def test_find_key_refuses_a_file_that_does_not_name_itself(tmp_path):
    with pytest.raises(SystemExit):
        indexnow.find_key(_site(tmp_path, key_body="something-else"))


def test_sitemap_urls_are_trimmed_and_deduplicated(tmp_path):
    site = _site(tmp_path)
    assert indexnow.sitemap_urls(site / "sitemap.xml") == ["https://m1k3.app/", "https://m1k3.app/install"]


def test_payload_shape_matches_the_indexnow_spec():
    body = indexnow.payload(KEY, ["https://m1k3.app/", "https://m1k3.app/install"])
    assert body == {
        "host": "m1k3.app",
        "key": KEY,
        "keyLocation": f"https://m1k3.app/{KEY}.txt",
        "urlList": ["https://m1k3.app/", "https://m1k3.app/install"],
    }


def test_payload_refuses_off_host_urls():
    with pytest.raises(SystemExit):
        indexnow.payload(KEY, ["https://example.com/"])


def test_dry_run_prints_the_payload_and_touches_no_network(tmp_path, capsys, monkeypatch):
    site = _site(tmp_path)
    monkeypatch.setattr(indexnow, "submit", lambda body: (_ for _ in ()).throw(AssertionError("network")))
    assert indexnow.main(["--dry-run", "--site-dir", str(site)]) == 0
    out = capsys.readouterr().out
    assert '"keyLocation": "https://m1k3.app/' in out and "https://m1k3.app/install" in out
