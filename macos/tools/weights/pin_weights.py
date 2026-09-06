#!/usr/bin/env python3
"""Regenerate Sources/M1K3MLX/PinnedWeights.swift — the shipped weight manifest.

Why this is a script and not hand-typed hex: re-pinning happens every time a
brain is promoted (both tiers moved inside 26 hours in July 2026), and a
manifest is only worth anything if regenerating it is mechanical enough that
nobody is tempted to skip it.

TRUST MODEL — read before changing anything here.

The digests are computed from the LOCAL, already-downloaded snapshot by
default, NOT from HuggingFace's API. That is deliberate: the local copy is the
one that has actually been run and evaluated, so pinning it pins the bytes we
know behave correctly. HuggingFace's published LFS oid is then used as an
INDEPENDENT SECOND OPINION — if the two agree, two parties confirm the same
bytes, and a compromise would have to have happened before our evals to slip
through. A mismatch is a hard stop, never a warning.

Small files (config.json, chat_template.jinja, tokenizer_config.json) are not
LFS-backed, so HF publishes no content digest for them and only the local hash
is available. They are pinned anyway — the chat template in particular IS the
tool-calling contract for gemma, so a silent change there is a behaviour change
in disguise.

Usage:
    python3 macos/tools/weights/pin_weights.py                # verify + regenerate
    python3 macos/tools/weights/pin_weights.py --check        # verify only, exit 1 on drift
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
import urllib.request

# The repos M1K3 actually ships and downloads for a user-selectable brain.
# Spikes, A/B overrides and retired checkpoints are deliberately NOT pinned —
# see WeightIntegrity.Verdict.unpinned for why that stays permissive.
# Two download bases, because the 2.x layout is preserved byte-for-byte so
# existing caches keep working (see HuggingFaceBridge): LLM weights under
# Application Support (Caches until #92), embedder weights under Documents. Both flow through the same
# HubApiDownloader.download choke point, so both are enforceable.
CONTAINER = pathlib.Path.home() / "Library/Containers/app.m1k3/Data"
# LLM weights moved from Library/Caches to Application Support on 2026-08-02
# (#92, 3379ed9f: macOS purges Caches under disk pressure). ModelStoreLocation is the
# Swift source of truth; this mirrors it.
LLM_CACHE = CONTAINER / "Library/Application Support/models"
EMBEDDER_CACHE = CONTAINER / "Documents/huggingface/models"

SHIPPED_REPOS = {
    "mlx-community/gemma-4-12B-it-4bit": LLM_CACHE,
    # Lil: the DWQ-2510 recipe of the same Qwen3-4B-Instruct-2507 weights beat
    # the plain 4-bit 18/21 vs 15/21 (security 6/7 vs 3/7; x3 repeats 16/21 vs
    # 12/21) on 2026-09-05 — docs/evals/2026-09-05-lil-*.json.
    "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510": LLM_CACHE,
    # Mini on devices without Apple Intelligence (the 3 GB A12 iPad has no
    # other local brain): LFM2.5-1.2B, ~630 MB. Tool-use 5/6 through the live
    # path once PR #232 rendered its tool block in trained key order
    # (swift-jinja's tojson sorts keys); open-chat 7-8/8 at ~1.9 s/turn.
    "mlx-community/LFM2.5-1.2B-Instruct-4bit": LLM_CACHE,
    # The retrieval embedder. Smaller, but it is still third-party weights
    # fetched at runtime and fed to MLX — the same exposure, just quieter.
    "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ": EMBEDDER_CACHE,
}

# Which download root each repo belongs under, emitted into the manifest so the
# app never has to guess. Derived from the cache path above rather than listed
# separately — a second list is a second thing to forget to update.
BASE_NAMES = {LLM_CACHE: "llm", EMBEDDER_CACHE: "embedder"}

# Per-file notes emitted as comments above the pinned entry. The generator
# owns this file end to end, so a note that lives only in the .swift output is
# wiped by the next re-pin (the gemma template note was lost exactly that way
# on 2026-09-05). Keep the WHY of any hash that is not the raw snapshot here.
FILE_NOTES: dict[tuple[str, str], str] = {
    ("mlx-community/gemma-4-12B-it-4bit", "chat_template.jinja"): (
        "NOT the snapshot's template: Gemma4TemplateFix installs\n"
        "Google's 2026-07-09 canonical over the stale 2026-06-03 one\n"
        "BEFORE the scan runs, so the manifest pins the healed bytes\n"
        "(vendored resource, sha re-verified on every read)."
    ),
}

# Deliberately NO suffix filter. An earlier cut mirrored mlx-swift-lm's
# `modelDownloadPatterns` as a hardcoded tuple, which security review flagged
# as silent-drift bait: those patterns are `package`-scoped so we cannot assert
# against them, and an upstream bump adding a file type (a SentencePiece
# `*.model`, say) would ship it unpinned with no test going red.
#
# Pinning every real file in the snapshot removes the coupling instead of
# guarding it. The directory already contains exactly what the patterns
# fetched, so this is a no-op today and self-correcting tomorrow.

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = REPO_ROOT / "macos/Sources/M1K3MLX/PinnedWeights.swift"

# The same manifest in a form anything can read. Because verification is
# client-side, publishing this is what makes it safe for ANYONE to mirror the
# weights: a third party can serve the bytes without being trusted, since the
# app checks them against digests that travel with our source. That is a docs
# page instead of an ops commitment, and it is strictly more useful than a
# mirror we run ourselves.
JSON_OUT = REPO_ROOT / "macos/weights-manifest.json"

# Deliberately NO generation timestamp in either output. A timestamp would make
# `--check` report drift on every single run, and a drift check that always
# cries wolf is one people learn to ignore.
SCHEMA_VERSION = 1


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def hf_json(url: str):
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.load(resp)


def collect(repo: str, cache: pathlib.Path) -> tuple[str, dict[str, dict]]:
    """Local digests for `repo`, cross-checked against HF. Exits on disagreement."""
    directory = cache / repo
    if not directory.is_dir():
        sys.exit(
            f"FATAL {repo}: no local snapshot at {directory}.\n"
            "Pin from bytes that have been run and evaluated — download and "
            "exercise the model first, then re-run this."
        )

    revision = hf_json(f"https://huggingface.co/api/models/{repo}/revision/main")["sha"]

    # ⚠️ The revision and the digests MUST come from the same commit.
    #
    # The revision above is whatever `main` points at RIGHT NOW, while the
    # digests below are computed from whatever is sitting in the local cache,
    # which may be older. Pin those together and a user's fresh download at the
    # pinned revision legitimately differs from the pinned digests — a FALSE
    # tamper verdict on honest content, and per "refuse, don't heal" it never
    # recovers on its own. That is this tool inverting the exact failure it
    # exists to catch, and non-LFS files (chat_template.jinja above all) have
    # no cross-check that would notice.
    #
    # HubApi records the commit each file was fetched at, so we can simply ask.
    local_commits = {
        path.read_text().splitlines()[0].strip()
        for path in (directory / ".cache/huggingface/download").rglob("*.metadata")
    }
    if not local_commits:
        sys.exit(
            f"FATAL {repo}: no HubApi download metadata under {directory}, so the "
            "local snapshot's commit cannot be established.\n"
            "Re-download through the app so provenance is recorded, then re-run."
        )
    if local_commits != {revision}:
        sys.exit(
            f"FATAL {repo}: local snapshot is at {sorted(local_commits)} but main is "
            f"now {revision}.\n"
            "Pinning today's revision beside yesterday's bytes would make every "
            "user's honest download look tampered with. Refresh the local copy "
            "(and re-run your evals against it) before pinning."
        )

    published: dict[str, str] = {}
    for entry in hf_json(f"https://huggingface.co/api/models/{repo}/tree/main?recursive=1"):
        if entry.get("type") != "file":
            continue
        if oid := (entry.get("lfs") or {}).get("oid"):
            published[entry["path"]] = oid

    files: dict[str, dict] = {}
    confirmed = 0
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or path.name.startswith(".") or ".cache" in path.parts:
            continue
        rel = str(path.relative_to(directory))
        digest = sha256(path)

        if expected := published.get(rel):
            if expected != digest:
                sys.exit(
                    f"FATAL {repo}/{rel}: local sha256 {digest} disagrees with "
                    f"HuggingFace's published LFS oid {expected}.\n"
                    "Two independent sources disagree about these bytes. Do NOT "
                    "pin. Investigate before doing anything else."
                )
            confirmed += 1

        files[rel] = {"size": path.stat().st_size, "sha256": digest}

    print(
        f"  {repo}\n"
        f"    revision {revision}\n"
        f"    {len(files)} files pinned, {confirmed} independently confirmed against HF"
    )
    return revision, files


def swift_int(value: int) -> str:
    """Format an Int the way swiftformat will anyway.

    Its default `decimalGrouping: 3,6` inserts underscores every three digits
    once a literal reaches six. Emitting a different shape would mean the
    format-on-save hook rewrites this file after every regeneration, and
    `--check` would then report drift on a manifest that is perfectly correct —
    which would train everyone to ignore it.
    """
    text = str(value)
    if len(text) < 6:
        return text
    digits = []
    for offset, char in enumerate(reversed(text)):
        if offset and offset % 3 == 0:
            digits.append("_")
        digits.append(char)
    return "".join(reversed(digits))


def swift_literal(pins: dict[str, tuple[str, dict[str, dict]]]) -> str:
    lines = [
        "//",
        "//  PinnedWeights.swift",
        "//  M1K3MLX",
        "//",
        "//  GENERATED — do not hand-edit. Regenerate with:",
        "//      python3 macos/tools/weights/pin_weights.py",
        "//",
        "//  The manifest WeightIntegrity checks downloaded weights against. It",
        "//  lives in our source, under review, on purpose: fetching the expected",
        "//  digest from the same host that serves the file proves nothing, since",
        "//  whoever can swap the file can swap its published hash too.",
        "//",
        "//  Each digest was computed from a local snapshot that had been run and",
        "//  evaluated, then cross-checked against HuggingFace's published LFS oid",
        "//  where one exists. The generator hard-stops on any disagreement.",
        "//",
        "//  Changing a pin is a deliberate act: it means shipping different",
        "//  weights, and it should be reviewed like any other behaviour change.",
        "//",
        "",
        "import Foundation",
        "",
        "/// The shipped weight manifest. Repos absent from this table load",
        "/// unverified by design — see `WeightIntegrity.Verdict.unpinned`.",
        "public enum PinnedWeights {",
        "    public static let all: [String: WeightIntegrity.Pin] = [",
    ]
    for repo, (revision, files, _base) in sorted(pins.items()):
        lines.append(f'        "{repo}": .init(')
        lines.append(f'            revision: "{revision}",')
        lines.append("            files: [")
        for name, meta in sorted(files.items()):
            if note := FILE_NOTES.get((repo, name)):
                lines.extend(f"                // {line}" for line in note.splitlines())
            lines.append(
                f'                "{name}": '
                f'.init(size: {swift_int(meta["size"])}, sha256: "{meta["sha256"]}"),'
            )
        lines.append("            ]")
        lines.append("        ),")
    lines += [
        "    ]",
        "",
        "    /// Which download root each pinned repo belongs under. LLM weights",
        "    /// and embedder weights live in genuinely different places (the 2.x",
        "    /// layout, preserved so existing caches keep working), so anything",
        "    /// installing files has to know which — assuming one base puts the",
        "    /// embedder where its loader never looks.",
        "    public static let bases: [String: WeightIntegrity.DownloadBase] = [",
    ]
    for repo, (_revision, _files, base) in sorted(pins.items()):
        lines.append(f'        "{repo}": .{base},')
    lines += [
        "    ]",
        "",
        "    /// The pin for `repoID`, or nil when the repo ships unpinned.",
        "    public static func pin(for repoID: String) -> WeightIntegrity.Pin? {",
        "        all[repoID]",
        "    }",
        "",
        "    /// The download root for `repoID`, or nil when the repo is unpinned.",
        "    public static func downloadBase(for repoID: String) -> WeightIntegrity.DownloadBase? {",
        "        bases[repoID]",
        "    }",
        "}",
        "",
    ]
    return "\n".join(lines)


def json_manifest(pins: dict[str, tuple[str, dict[str, dict]]]) -> str:
    """The machine-readable twin of PinnedWeights.swift.

    Kept byte-derived from the same `pins` structure as the Swift output so the
    two can never disagree — a published manifest that drifts from what the app
    actually enforces would be worse than publishing nothing.
    """
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "about": (
            "sha256 digests and pinned revisions for the model weights M1K3 downloads. "
            "The app verifies every downloaded or imported file against these before "
            "loading it, so any host can serve these bytes without being trusted. "
            "See macos/docs/MIRRORING_WEIGHTS.md."
        ),
        "repos": {
            repo: {
                "revision": revision,
                "downloadBase": base,
                "files": {
                    name: {"size": meta["size"], "sha256": meta["sha256"]}
                    for name, meta in sorted(files.items())
                },
            }
            for repo, (revision, files, base) in sorted(pins.items())
        },
    }
    return json.dumps(document, indent=2, sort_keys=False) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify and report drift without rewriting the manifests",
    )
    args = parser.parse_args()

    print("Pinning shipped model weights (local bytes, cross-checked against HF):")
    pins = {
        repo: (*collect(repo, cache), BASE_NAMES[cache])
        for repo, cache in SHIPPED_REPOS.items()
    }
    outputs = {OUT: swift_literal(pins), JSON_OUT: json_manifest(pins)}

    if args.check:
        stale = [
            path.relative_to(REPO_ROOT)
            for path, generated in outputs.items()
            if (path.read_text() if path.exists() else "") != generated
        ]
        if stale:
            names = ", ".join(str(path) for path in stale)
            sys.exit(f"DRIFT: {names} stale — re-run without --check")
        print("Manifests are up to date.")
        return

    for path, generated in outputs.items():
        path.write_text(generated)
        print(f"Wrote {path.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
