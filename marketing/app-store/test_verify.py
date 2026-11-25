"""verify.py's plate-drift check: a frame whose plate changed since its crop was last
checked by eye fails, by name (2026-11-24: two hand-tuned Mac crops went wrong under
a recapture and "spec OK" passed both).

The render writes, per frame, each plate's hash AS RENDERED: `raw` (the capture's
bytes) and `look` (bytes + its PLATE_MASKS retouch). Approval stamps `look`; the
current file is compared with `raw`, so approve can never stamp pixels the contact
sheet did not show.

    uv run --with pytest --with pillow pytest test_verify.py
"""
import json

import verify


def entry(raw, look=None):
    return {"raw": raw, "look": look or raw + "-look"}


MANIFEST = {
    "08_data-not-collected": {"mac/privacy-label.png": entry("aaa")},
    "09_you-approve": {"mac/agent-scripts.png": entry("bbb")},
    "07_companion": {"mac/companion-fox.png": entry("ccc"), "mac/companion-gecko.png": entry("ddd")},
}
CURRENT = {"mac/privacy-label.png": "aaa", "mac/agent-scripts.png": "bbb",
           "mac/companion-fox.png": "ccc", "mac/companion-gecko.png": "ddd"}
LOCK = {p: e["look"] for plates in MANIFEST.values() for p, e in plates.items()}


def test_a_matching_lock_is_clean():
    assert verify.drift(MANIFEST, dict(LOCK), CURRENT) == []


def test_a_changed_look_names_every_frame_that_reads_it():
    lock = dict(LOCK, **{"mac/privacy-label.png": "old"})
    problems = verify.drift(MANIFEST, lock, CURRENT)
    assert len(problems) == 1
    assert "08_data-not-collected" in problems[0] and "mac/privacy-label.png" in problems[0]
    assert "changed" in problems[0]


def test_a_mask_edit_alone_is_drift():
    manifest = dict(MANIFEST, **{"08_data-not-collected": {"mac/privacy-label.png": entry("aaa", "remasked")}})
    problems = verify.drift(manifest, dict(LOCK), CURRENT)
    assert len(problems) == 1 and "08_data-not-collected" in problems[0]


def test_a_plate_never_checked_fails_too():
    lock = {k: v for k, v in LOCK.items() if k != "mac/agent-scripts.png"}
    problems = verify.drift(MANIFEST, lock, CURRENT)
    assert len(problems) == 1
    assert "09_you-approve" in problems[0] and "never" in problems[0]


def test_a_plate_recaptured_after_the_render_says_re_render():
    current = dict(CURRENT, **{"mac/agent-scripts.png": "new"})
    problems = verify.stale(MANIFEST, current)
    assert len(problems) == 1 and "09_you-approve" in problems[0] and "re-render" in problems[0]


def test_a_missing_plate_file_is_stale():
    current = {k: v for k, v in CURRENT.items() if k != "mac/companion-gecko.png"}
    problems = verify.stale(MANIFEST, current)
    assert len(problems) == 1 and "missing" in problems[0]


def test_every_png_needs_a_manifest_entry_and_an_empty_manifest_fails():
    pngs = ["07_companion", "08_data-not-collected", "09_you-approve", "10_extra"]
    problems = verify.coverage(MANIFEST, pngs)
    assert len(problems) == 1 and "10_extra" in problems[0]
    assert verify.coverage({}, []) != []


def test_approve_stamps_the_rendered_looks_and_keeps_other_stamps():
    lock = {"ios/chat.png": "zzz", "mac/privacy-label.png": "old"}
    out = verify.approve(MANIFEST, lock)
    assert out["ios/chat.png"] == "zzz", "another target's stamps survive"
    assert out["mac/privacy-label.png"] == "aaa-look"
    assert verify.drift(MANIFEST, out, CURRENT) == []


def _set(tmp_path, monkeypatch, plate_bytes=b"one"):
    plates = tmp_path / "plates" / "mac"
    plates.mkdir(parents=True)
    (plates / "privacy-label.png").write_bytes(plate_bytes)
    root = tmp_path / "out" / "mac" / "en-US"
    root.mkdir(parents=True)
    (root / "08_data-not-collected.png").write_bytes(b"png")
    raw = verify.file_hash(str(plates / "privacy-label.png"))
    (root / ".plates.json").write_text(json.dumps(
        {"08_data-not-collected": {"mac/privacy-label.png": {"raw": raw, "look": raw + "m"}}}))
    lock = tmp_path / "plates.lock.json"
    monkeypatch.setattr(verify, "PLATES_ROOT", str(tmp_path / "plates"))
    monkeypatch.setattr(verify, "LOCK", str(lock))
    return plates, root, lock


def test_the_cli_reads_the_render_manifest_and_the_lock(tmp_path, monkeypatch):
    plates, root, lock = _set(tmp_path, monkeypatch)
    assert verify.check_drift(str(root), approve_now=False)  # never checked: fails
    assert verify.check_drift(str(root), approve_now=True) == []  # stamped
    assert json.loads(lock.read_text())["mac/privacy-label.png"]
    assert verify.check_drift(str(root), approve_now=False) == []
    (plates / "privacy-label.png").write_bytes(b"two")  # recaptured after the render
    assert verify.check_drift(str(root), approve_now=False)


def test_approve_refuses_a_set_that_fails(tmp_path, monkeypatch):
    plates, root, lock = _set(tmp_path, monkeypatch)
    assert verify.check_drift(str(root), approve_now=True, blocked=True)
    assert not lock.exists(), "a failing set is never stamped"
    (plates / "privacy-label.png").write_bytes(b"two")  # stale: the render predates it
    assert verify.check_drift(str(root), approve_now=True)
    assert not lock.exists(), "a stale render is never stamped"
