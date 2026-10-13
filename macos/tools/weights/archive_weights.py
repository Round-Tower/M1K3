#!/usr/bin/env python3
"""Stage a licence-compliant cold archive of the pinned model weights.

This is item 2 of the weight supply-chain plan (the "braces"): a second home
for the exact bytes a pin points at, so a pin cannot be stranded if upstream
deletes or force-pushes a repo. See issue #75 and ADR 0002.

WHAT IT DOES, AND WHAT IT DELIBERATELY DOES NOT.

It stages — verifies every pinned file against `weights-manifest.json`, then
copies the exact bytes into a per-repo tree with the licence notices a
redistributor owes. It NEVER pushes without an explicit `--push-hf` flag and
credentials, because publishing bytes is an outward-facing act that is the
user's to authorise, not a script's. The default run stages, verifies, reports,
and prints the push commands, touching no remote.

The R2 half is print-only: neither `rclone` nor the `aws` CLI is installed on
this machine, and silently no-oping an upload would be worse than saying so.
The HuggingFace half can run end-to-end (`huggingface-cli` is present) once a
token and an org are supplied.

TRUST MODEL. It refuses to archive bytes that disagree with the manifest —
archiving a poisoned or stale file would defeat the whole point, so a mismatch
is a hard stop, never a warning. Same rule as `pin_weights.py`.

LICENCE POSITION (from the 2026-07-21 review; see MIRRORING_WEIGHTS.md and the
`gemma-4-is-apache-2` memory). All three pinned models are Apache-2.0, so
redistribution is permitted and the obligation is small: ship the LICENSE and
say what was modified. The catch is that `mlx-community/gemma-4-12B-it-4bit`
ships NO licence and NO attribution — so re-hosting it as-is would republish
that omission. This tool adds a LICENSE and a modification NOTICE to every
staged repo, which makes our copy strictly more compliant than the upstream we
took it from.

Usage:
    python3 macos/tools/weights/archive_weights.py                 # stage + verify + plan (no network)
    python3 macos/tools/weights/archive_weights.py --out DIR       # stage into DIR
    python3 macos/tools/weights/archive_weights.py --push-hf ORG    # also upload to hf.co/ORG/<repo> (needs a token)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
MANIFEST = REPO_ROOT / "macos/weights-manifest.json"
APACHE_LICENSE = pathlib.Path(__file__).resolve().parent / "licenses/Apache-2.0.txt"

CONTAINER = pathlib.Path.home() / "Library/Containers/app.m1k3/Data"
# Must match pin_weights.py's bases — the manifest's downloadBase names them.
BASE_DIRS = {
    "llm": CONTAINER / "Library/Caches/models",
    "embedder": CONTAINER / "Documents/huggingface/models",
}

DEFAULT_OUT = REPO_ROOT / "macos/scratch/weights-archive"


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def notice_text(repo: str, revision: str) -> str:
    """The redistributor's NOTICE. States provenance, the pinned commit, and —
    load-bearing for Apache-2.0 section 4(b) — that the files are a modified
    (quantised) derivative, which the upstream mlx repo fails to say."""
    return (
        f"This directory redistributes the model weights from:\n"
        f"    https://huggingface.co/{repo}\n"
        f"    at commit {revision}\n\n"
        f"Licence: Apache License 2.0 (see the LICENSE file in this directory).\n\n"
        f"MODIFICATION NOTICE (Apache-2.0 section 4(b)):\n"
        f"These weights are a 4-bit quantised, MLX-converted derivative of the\n"
        f"original model — the weight files were quantised and re-sharded for MLX.\n"
        f"Redistributed here by Round Tower Software Ltd as a byte-for-byte\n"
        f"copy of the commit above, so that M1K3 has a second source for the exact\n"
        f"revision it pins. Round Tower is not affiliated with or endorsed by the\n"
        f"original model's authors.\n\n"
        f"Every file in this directory is verifiable against the sha256 digests in\n"
        f"macos/weights-manifest.json in the M1K3 source repository.\n"
    )


def stage_repo(repo: str, spec: dict, out_root: pathlib.Path, copy_weights: bool) -> tuple[pathlib.Path, int]:
    """Verify `repo`'s local bytes against the manifest and write the licence
    notices into `out_root/<repo-name>`. Copies the weight files only when
    `copy_weights` is set — verification is cheap-ish (a hash pass) and always
    runs, but copying gigabytes is gated so the default plan never fills a disk.
    Hard-stops on any mismatch."""
    base = BASE_DIRS.get(spec["downloadBase"])
    if base is None:
        sys.exit(f"FATAL {repo}: unknown downloadBase {spec['downloadBase']!r}")
    source = base / repo
    if not source.is_dir():
        sys.exit(
            f"FATAL {repo}: no local snapshot at {source}.\n"
            "Archive the bytes you have verified, not bytes you hope exist — "
            "download the model through the app first."
        )

    dest = out_root / repo.split("/")[-1]
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    total = 0
    for name, meta in sorted(spec["files"].items()):
        src_file = source / name
        if not src_file.is_file():
            sys.exit(f"FATAL {repo}/{name}: pinned file missing from local snapshot at {src_file}")
        size = src_file.stat().st_size
        if size != meta["size"]:
            sys.exit(
                f"FATAL {repo}/{name}: size {size} != manifest {meta['size']}. "
                "Not archiving bytes that disagree with the pin."
            )
        digest = sha256(src_file)
        if digest != meta["sha256"]:
            sys.exit(
                f"FATAL {repo}/{name}: sha256 {digest} != manifest {meta['sha256']}. "
                "Not archiving bytes that disagree with the pin."
            )
        if copy_weights:
            dest_file = dest / name
            dest_file.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_file, dest_file)
        total += size

    shutil.copy2(APACHE_LICENSE, dest / "LICENSE")
    (dest / "NOTICE").write_text(notice_text(repo, spec["revision"]))
    verb = "staged" if copy_weights else "verified"
    print(f"  {verb} {repo}\n    {len(spec['files'])} files verified + LICENSE + NOTICE  ({total / 1e9:.2f} GB)")
    return dest, total


def push_hf(dest: pathlib.Path, repo: str, org: str) -> None:
    """Upload a staged repo to hf.co/<org>/<name> via huggingface-cli. Requires
    a token in the environment (HF_TOKEN / a prior `huggingface-cli login`)."""
    target = f"{org}/{repo.split('/')[-1]}"
    print(f"  uploading {dest.name} -> https://huggingface.co/{target}")
    result = subprocess.run(
        ["huggingface-cli", "upload", target, str(dest), ".", "--repo-type", "model"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"FATAL hf upload {target} failed:\n{result.stderr.strip()}")
    print(f"    done: https://huggingface.co/{target}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=pathlib.Path, default=DEFAULT_OUT, help="staging directory")
    parser.add_argument(
        "--stage",
        action="store_true",
        help="actually copy the weight files (default: verify + write notices only, no multi-GB copy)",
    )
    parser.add_argument(
        "--push-hf",
        metavar="ORG",
        help="stage and upload each repo to hf.co/ORG/<name> (needs a HuggingFace token); implies --stage",
    )
    args = parser.parse_args()

    if not APACHE_LICENSE.is_file():
        sys.exit(f"FATAL missing {APACHE_LICENSE} — the Apache 2.0 text the archive must ship.")
    manifest = json.loads(MANIFEST.read_text())

    copy_weights = args.stage or bool(args.push_hf)
    mode = "Staging" if copy_weights else "Verifying (no weight copy)"
    print(f"{mode} cold archive into {args.out.relative_to(REPO_ROOT)}, checking against the manifest:")
    args.out.mkdir(parents=True, exist_ok=True)
    staged: list[tuple[pathlib.Path, str]] = []
    grand = 0
    for repo, spec in sorted(manifest["repos"].items()):
        dest, total = stage_repo(repo, spec, args.out, copy_weights)
        staged.append((dest, repo))
        grand += total

    print(f"\n{'Staged' if copy_weights else 'Verified'} {len(staged)} repos, {grand / 1e9:.2f} GB total.")

    if args.push_hf:
        print(f"\nPushing to HuggingFace org {args.push_hf}:")
        for dest, repo in staged:
            push_hf(dest, repo, args.push_hf)
    else:
        tool = pathlib.Path(__file__).relative_to(REPO_ROOT)
        if not copy_weights:
            print("\nVerify-only — no bytes copied. Next:")
            print(f"  Stage locally:  python3 {tool} --stage")
        print("\nNothing pushed. To publish:")
        print(f"  HuggingFace:  python3 {tool} --push-hf <your-org>")
        print("                (needs `huggingface-cli login` or HF_TOKEN first)")
        print("  Cloudflare R2 (rclone/aws not installed here — run where they are):")
        print(f"      python3 {tool} --stage && rclone copy {args.out.relative_to(REPO_ROOT)} r2:<bucket>/m1k3-weights --progress")
        print("  Then note the archive locations in issue #75, and wire the runtime")
        print("  fallback per issue #76.")


if __name__ == "__main__":
    main()
