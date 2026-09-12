"""Pins for pin_weights' pure half (#223).

The generator's I/O half (hashing the local snapshot, asking HuggingFace for
LFS oids) needs the model cache and the network; everything that turns pins
into the two manifests is pure and is pinned here. The last two tests rebuild
PinnedWeights.swift from the COMMITTED weights-manifest.json — both are
generated from one `pins` structure, so they must agree byte for byte, and a
FILE_NOTES key that no longer names a pinned file fails loudly.

Signed: Kev + claude-opus-5, 2026-09-12, Confidence 0.9 (pure functions only;
the committed-manifest round trip needs no model cache). Prior: Unknown
"""
import json

import pin_weights as m


def test_swift_int_groups_like_swiftformat_from_six_digits():
    assert m.swift_int(12345) == "12345"
    assert m.swift_int(123456) == "123_456"
    assert m.swift_int(6_700_000_123) == "6_700_000_123"


def _pins():
    return {
        "org/b-model": ("rev2", {"b.safetensors": {"size": 1_000_000, "sha256": "bb"}}, "llm"),
        "org/a-model": ("rev1", {
            "config.json": {"size": 12, "sha256": "c1"},
            "chat_template.jinja": {"size": 400, "sha256": "t1"},
        }, "embedder"),
    }


def test_swift_literal_sorts_repos_and_files_and_formats_sizes():
    out = m.swift_literal(_pins())
    assert out.index('"org/a-model"') < out.index('"org/b-model"')
    assert out.index('"chat_template.jinja"') < out.index('"config.json"')
    assert "size: 1_000_000" in out
    assert '"org/a-model": .embedder,' in out and '"org/b-model": .llm,' in out


def test_swift_literal_emits_file_notes_above_their_entry(monkeypatch):
    monkeypatch.setattr(m, "FILE_NOTES", {("org/a-model", "chat_template.jinja"): "line one\nline two"})
    out = m.swift_literal(_pins()).splitlines()
    at = next(i for i, l in enumerate(out) if '"chat_template.jinja"' in l)
    assert out[at - 2].strip() == "// line one"
    assert out[at - 1].strip() == "// line two"


def test_json_manifest_mirrors_the_same_pins():
    doc = json.loads(m.json_manifest(_pins()))
    assert doc["schemaVersion"] == m.SCHEMA_VERSION
    assert list(doc["repos"]) == ["org/a-model", "org/b-model"]
    assert doc["repos"]["org/b-model"] == {
        "revision": "rev2", "downloadBase": "llm",
        "files": {"b.safetensors": {"size": 1_000_000, "sha256": "bb"}},
    }


def test_orphan_file_notes_are_reported():
    notes = {("org/a-model", "chat_template.jinja"): "x", ("org/a-model", "renamed.jinja"): "y"}
    assert m.orphan_file_notes(_pins(), notes) == [("org/a-model", "renamed.jinja")]


def _committed_pins():
    doc = json.loads(m.JSON_OUT.read_text())
    return {
        repo: (entry["revision"], entry["files"], entry["downloadBase"])
        for repo, entry in doc["repos"].items()
    }


def test_committed_swift_manifest_is_the_generator_output_of_the_committed_json():
    assert m.swift_literal(_committed_pins()) == m.OUT.read_text(), (
        "PinnedWeights.swift and weights-manifest.json disagree — re-run pin_weights.py, never hand-edit either"
    )
    assert m.json_manifest(_committed_pins()) == m.JSON_OUT.read_text()


def test_every_file_note_names_a_committed_pin():
    assert m.orphan_file_notes(_committed_pins(), m.FILE_NOTES) == []


def test_every_shipped_repo_is_in_the_committed_manifest():
    assert set(m.SHIPPED_REPOS) == set(_committed_pins())
