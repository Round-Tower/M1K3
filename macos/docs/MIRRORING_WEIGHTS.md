# Mirroring M1K3's model weights

M1K3 downloads its brains at runtime rather than bundling them — the largest is
6.7 GB, and a DMG that size helps nobody. That means the app depends on a
third-party host being reachable at the moment someone onboards, which is the
worst possible moment for a download to fail.

**You do not need our permission, or our trust, to fix that for yourself.**

Every file M1K3 downloads is verified against sha256 digests committed in this
repository before it is loaded. Verification is entirely client-side, so the
app does not care where the bytes came from. A mirror cannot poison anything,
because a mirror is never trusted — the manifest is.

That property is why this page exists. Publishing the manifest is strictly more
useful than running a CDN ourselves: it lets a university, a company with a
locked-down network, or anyone on a bad connection host these weights without
us being involved at all.

## The manifest

[`macos/weights-manifest.json`](../weights-manifest.json) — the machine-readable
form of [`Sources/M1K3MLX/PinnedWeights.swift`](../Sources/M1K3MLX/PinnedWeights.swift),
generated from the same data by the same script, so they cannot disagree.

```json
{
  "schemaVersion": 1,
  "repos": {
    "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510": {
      "revision": "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
      "files": {
        "config.json": { "size": 938, "sha256": "574349e5…" }
      }
    }
  }
}
```

`revision` is the exact upstream commit the digests were taken at. `sha256` is
the digest of the file's raw bytes — nothing is wrapped, compressed or
re-encoded.

The manifest changes whenever a brain is promoted. Pin your mirror to a tag or
commit of this repo rather than tracking `master`, so your copy and your
manifest always agree.

## Verifying a copy

Any sha256 implementation works. There is nothing M1K3-specific about it:

```bash
shasum -a 256 model.safetensors
# compare against .repos["<repo>"].files["model.safetensors"].sha256
```

If a digest disagrees, **do not "fix" it by re-pinning.** The manifest is the
reference; a disagreement means the bytes are wrong, or that upstream moved and
this repo has not caught up yet. Open an issue.

## Using weights you already have

M1K3 can adopt a folder of weights directly, so you never need to download
twice — if you have them from `huggingface-cli`, another machine, or a mirror,
point the app at the folder: **Settings → Advanced → Import weights from a
folder…**, having picked the matching brain.

The app verifies the folder against the manifest first and **refuses it
outright if anything disagrees**. On success it installs the files along with
the download metadata the underlying HuggingFace client expects.

That last part is the bit that matters, and it is worth stating plainly because
we got it wrong once: simply copying weights into the cache directory **does not
work**. On 2026-07-16 a cache pre-seeded with `hf download --local-dir` failed
the client's freshness check and triggered a full re-download of both models —
strictly worse than having done nothing. Use the import path, which writes the
metadata correctly.

## Hosting a mirror

Serving the files is enough for manual placement and import. If you want the
app itself to fetch from your mirror, note that it currently talks to one
endpoint — a runtime fallback source is
[tracked separately](https://github.com/Round-Tower/M1K3/issues) and would
require your mirror to answer two HuggingFace API routes so a pinned commit can
be resolved.

**Practical constraints, learned the expensive way:**

- The largest single file is **5.35 GB**. That rules out GitHub Releases, which
  caps assets at 2 GiB, and Git LFS, whose largest tier maxes out at 5 GB.
- Serve HTTP **range requests** if you can. Without them an interrupted
  multi-GB download restarts from zero.
- Object storage with free or cheap egress is the sane choice. The full payload
  across all three pinned repos is **9.40 GB** (8.75 GiB) — 6.77 GB for the
  12B brain, 2.28 GB for the 4B, 0.35 GB for the embedder. Sum the `size`
  fields in the manifest yourself rather than trusting this line; it is
  reproducible, and a figure in prose goes stale the moment a brain is
  promoted.

## Licensing

All three pinned models are **Apache-2.0**: `gemma-4-12B-it` (Gemma 4 is
Apache-2.0 — it is *not* under Google's Gemma Terms of Use, which cover Gemma 1
through 3n and the other family members), `Qwen3-4B-Instruct-2507`, and
`Qwen3-Embedding-0.6B`.

Redistribution is permitted. Apache-2.0 section 4 asks you to include a copy of
the licence, and to state plainly if you changed any files. Note that some
community quantisations — including `mlx-community/gemma-4-12B-it-4bit`, which
is what M1K3 downloads — ship **no LICENSE and no attribution at all**. If you
mirror one of those, adding the licence and an accurate modification notice
makes your copy more compliant than the original, and costs you one text file.

This is a description of what the licences say, not legal advice.

## Regenerating the manifest (maintainers)

```bash
python3 macos/tools/weights/pin_weights.py           # regenerate both manifests
python3 macos/tools/weights/pin_weights.py --check    # fail if either is stale
```

Digests are computed from a local snapshot that has actually been run and
evaluated, then cross-checked against HuggingFace's published LFS digests where
they exist. The script hard-stops if the two disagree, and refuses to pin at all
unless the local snapshot's recorded commit matches the revision being pinned —
pinning today's revision beside yesterday's bytes would make every honest
download look tampered with.

### Publishing a cold archive (maintainers)

To put the pinned bytes somewhere they cannot be stranded if upstream deletes
or force-pushes a repo (issue #75):

```bash
python3 macos/tools/weights/archive_weights.py               # verify + write LICENSE/NOTICE, no multi-GB copy
python3 macos/tools/weights/archive_weights.py --stage        # also copy the weights into the staging tree
python3 macos/tools/weights/archive_weights.py --push-hf ORG   # stage + upload to hf.co/ORG/<repo> (needs a token)
```

The default run verifies every file against the manifest and hard-stops on any
mismatch — it will not archive bytes that disagree with the pin. It also writes
a `LICENSE` (Apache-2.0) and a `NOTICE` into each repo's tree: all three models
are Apache-2.0, but the `mlx-community` quant we download ships neither, so the
archive adds them (a modification notice for the 4-bit MLX conversion), making
our copy more compliant than the source. Cloudflare R2 is a print-only step
because `rclone`/`aws` aren't installed here — run the printed command where
they are.
