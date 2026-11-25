"""verify.py's plate-drift check: a frame whose plate changed since its crop was last
checked by eye fails, by name (2026-11-24: two hand-tuned Mac crops went wrong under
a recapture and "spec OK" passed both).

    uv run --with pytest --with pillow pytest test_verify.py
"""
import json

import verify

MANIFEST = {
    "08_data-not-collected": ["mac/privacy-label.png"],
    "09_you-approve": ["mac/agent-scripts.png"],
    "07_companion": ["mac/companion-fox.png", "mac/companion-gecko.png"],
}
HASHES = {
    "mac/privacy-label.png": "aaa",
    "mac/agent-scripts.png": "bbb",
    "mac/companion-fox.png": "ccc",
    "mac/companion-gecko.png": "ddd",
}


def test_a_matching_lock_is_clean():
    assert verify.drift(MANIFEST, dict(HASHES), HASHES) == []


def test_a_changed_plate_names_every_frame_that_reads_it():
    lock = dict(HASHES, **{"mac/privacy-label.png": "old"})
    problems = verify.drift(MANIFEST, lock, HASHES)
    assert len(problems) == 1
    assert "08_data-not-collected" in problems[0] and "mac/privacy-label.png" in problems[0]
    assert "changed" in problems[0]


def test_a_plate_never_checked_fails_too():
    lock = {k: v for k, v in HASHES.items() if k != "mac/agent-scripts.png"}
    problems = verify.drift(MANIFEST, lock, HASHES)
    assert len(problems) == 1
    assert "09_you-approve" in problems[0] and "never" in problems[0]


def test_a_missing_plate_file_fails():
    hashes = {k: v for k, v in HASHES.items() if k != "mac/companion-gecko.png"}
    problems = verify.drift(MANIFEST, dict(HASHES), hashes)
    assert len(problems) == 1 and "missing" in problems[0]


def test_approve_stamps_only_the_plates_the_set_reads_and_keeps_the_rest():
    lock = {"ios/chat.png": "zzz", "mac/privacy-label.png": "old"}
    out = verify.approve(MANIFEST, lock, HASHES)
    assert out["ios/chat.png"] == "zzz", "another target's stamps survive"
    assert out["mac/privacy-label.png"] == "aaa"
    assert set(HASHES) <= set(out)
    assert verify.drift(MANIFEST, out, HASHES) == []


def test_the_cli_reads_the_render_manifest_and_the_lock(tmp_path, monkeypatch):
    plates = tmp_path / "plates" / "mac"
    plates.mkdir(parents=True)
    (plates / "privacy-label.png").write_bytes(b"one")
    root = tmp_path / "out" / "mac" / "en-US"
    root.mkdir(parents=True)
    (root / ".plates.json").write_text(json.dumps({"08_data-not-collected": ["mac/privacy-label.png"]}))
    lock = tmp_path / "plates.lock.json"
    monkeypatch.setattr(verify, "PLATES_ROOT", str(tmp_path / "plates"))
    monkeypatch.setattr(verify, "LOCK", str(lock))

    assert verify.check_drift(str(root), approve_now=False)  # never checked: fails
    assert verify.check_drift(str(root), approve_now=True) == []  # stamped
    assert json.loads(lock.read_text())["mac/privacy-label.png"]
    assert verify.check_drift(str(root), approve_now=False) == []
    (plates / "privacy-label.png").write_bytes(b"two")  # recaptured
    assert verify.check_drift(str(root), approve_now=False)
