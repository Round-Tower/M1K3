"""Pins for pin_weights' pure half (#223).

The generator's I/O half (hashing the local snapshot, asking HuggingFace for
LFS oids) needs the model cache and the network; everything that turns pins
into the two manifests is pure and is pinned here. The last two tests rebuild
PinnedWeights.swift from the COMMITTED weights-manifest.json — both are
generated from one `pins` structure, so they must agree byte for byte, and a
FILE_NOTES key that no longer names a pinned file fails loudly.

Signed: Kev + claude-opus-5, 2026-09-12, Confidence 0.9 (pure functions only;
the committed-manifest round trip needs no model cache). Prior: Unknown
Review: Kev + claude-opus-5-5, 2026-10-08 — `--only`'s merge (carry committed pins, refuse a
shipped repo with none, refuse a stray name or a moved download base). Confidence 0.9.
Review: Kev + claude-opus-5-5, 2026-10-08 — two refusals from the Qwen3.5 re-pin: an unreadable
snapshot (macOS app-data privacy) is named as such, not as missing metadata; a snapshot lacking a
published LFS file the app downloads is refused (a partial `hf download` pinned 9 of 10 files).
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
    return m.committed_pins(m.JSON_OUT.read_text())


def test_committed_swift_manifest_is_the_generator_output_of_the_committed_json():
    assert m.swift_literal(_committed_pins()) == m.OUT.read_text(), (
        "PinnedWeights.swift and weights-manifest.json disagree — re-run pin_weights.py, never hand-edit either"
    )
    assert m.json_manifest(_committed_pins()) == m.JSON_OUT.read_text()


def test_every_file_note_names_a_committed_pin():
    assert m.orphan_file_notes(_committed_pins(), m.FILE_NOTES) == []


def test_every_shipped_repo_is_in_the_committed_manifest():
    assert set(m.SHIPPED_REPOS) == set(_committed_pins())


# --only (2026-10-08): promoting Lil to Qwen3.5 needed ONE repo re-pinned, but the
# generator re-collected every shipped repo and hard-stopped on Big's snapshot (no
# HubApi metadata on this Mac — the provenance check working as designed). A
# re-pin of one repo must not require re-downloading 6.7 GB of another.

def _committed():
    return {
        "org/kept": ("rev-k", {"k.safetensors": {"size": 10, "sha256": "kk"}}, "llm"),
        "org/retired": ("rev-r", {"r.safetensors": {"size": 20, "sha256": "rr"}}, "llm"),
    }


def test_merge_takes_fresh_pins_for_named_repos_and_carries_the_rest():
    fresh = {"org/new": ("rev-n", {"n.safetensors": {"size": 30, "sha256": "nn"}}, "llm")}
    shipped = {"org/kept": "llm", "org/new": "llm"}
    merged = m.merge_pins(shipped, fresh, _committed(), only={"org/new"})
    assert merged == {"org/kept": _committed()["org/kept"], "org/new": fresh["org/new"]}


def test_merge_drops_a_committed_repo_that_no_longer_ships():
    fresh = {"org/new": ("rev-n", {}, "llm")}
    merged = m.merge_pins({"org/kept": "llm", "org/new": "llm"}, fresh, _committed(), only={"org/new"})
    assert "org/retired" not in merged


def test_merge_refuses_a_shipped_repo_with_no_committed_pin_that_was_not_named():
    import pytest
    with pytest.raises(ValueError, match="org/new"):
        m.merge_pins({"org/kept": "llm", "org/new": "llm"}, {}, _committed(), only=set())


def test_merge_refuses_naming_a_repo_that_does_not_ship():
    import pytest
    with pytest.raises(ValueError, match="org/stray"):
        m.merge_pins({"org/kept": "llm"}, {}, _committed(), only={"org/stray"})


def test_merge_refuses_a_carried_pin_whose_download_base_changed():
    import pytest
    with pytest.raises(ValueError, match="org/kept"):
        m.merge_pins({"org/kept": "embedder"}, {}, _committed(), only=set())


def test_committed_pins_reads_the_manifest_shape():
    doc = json.dumps({"repos": {"org/a": {"revision": "r", "downloadBase": "llm", "files": {"f": {"size": 1, "sha256": "s"}}}}})
    assert m.committed_pins(doc) == {"org/a": ("r", {"f": {"size": 1, "sha256": "s"}}, "llm")}


def test_an_unreadable_snapshot_is_refused_as_unreadable_not_as_missing_metadata(tmp_path):
    # macOS app-data privacy lets an outside process stat the container but not list it,
    # and pathlib's rglob swallows the PermissionError: an unreadable snapshot used to read
    # as "no HubApi download metadata" and sent Kev to re-download (2026-10-08).
    import pytest
    snapshot = tmp_path / "org" / "model"
    (snapshot / ".cache/huggingface/download").mkdir(parents=True)
    snapshot.chmod(0)
    try:
        with pytest.raises(PermissionError, match="org/model"):
            m.require_listable("org/model", snapshot)
    finally:
        snapshot.chmod(0o755)


def test_a_readable_snapshot_passes_the_listing_check(tmp_path):
    m.require_listable("org/model", tmp_path)


def test_a_snapshot_missing_a_published_weight_file_is_refused():
    # 2026-10-08: a partial `hf download` (the shard never fetched) pinned 9 of 10 files and
    # reported success, so the app would have "verified" Lil without ever hashing its weights.
    published = {"model.safetensors": "aa", "tokenizer.json": "bb", "assets/banner.png": "cc"}
    local = {"tokenizer.json", "config.json"}
    assert m.missing_published_files(published, local) == ["model.safetensors"]


def test_a_complete_snapshot_misses_nothing():
    published = {"model-00001-of-00002.safetensors": "aa", "model-00002-of-00002.safetensors": "bb"}
    assert m.missing_published_files(published, set(published)) == []


def test_a_snapshot_missing_a_small_published_file_is_refused_too():
    # Small files are not LFS-backed, but chat_template.jinja IS the tool-calling contract.
    listed = {"model.safetensors", "chat_template.jinja", "README.md", ".gitattributes"}
    assert m.missing_published_files(listed, {"model.safetensors"}) == ["chat_template.jinja"]
