#!/usr/bin/env python3
"""Generate the Kokoro G2P dictionary from misaki's British English data.

Reads misaki's gb_gold.json + gb_silver.json (Apache 2.0), maps each IPA
pronunciation to Kokoro's canonical token IDs, and writes the compressed
dictionary that KokoroG2P+Bundled.swift loads at runtime.

Usage:
    python3 macos/tools/generate_g2p_dict.py

Requirements:
    pip install misaki kokoro-onnx

Output:
    macos/Sources/M1K3Kokoro/Resources/g2p-en-gb.deflate
"""
import json
import os
import struct
import zlib

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
OUTPUT = os.path.join(
    REPO_ROOT, "macos", "Sources", "M1K3Kokoro", "Resources", "g2p-en-gb.deflate"
)


def load_kokoro_vocab():
    """Load the canonical 114-token vocab from kokoro_onnx's config."""
    import kokoro_onnx
    config_path = os.path.join(os.path.dirname(kokoro_onnx.__file__), "config.json")
    with open(config_path) as f:
        return {ch: tid for ch, tid in json.load(f)["vocab"].items()}


def load_misaki_dicts():
    """Load misaki's GB gold + silver dictionaries."""
    import misaki
    data_dir = os.path.join(os.path.dirname(misaki.__file__), "data")
    with open(os.path.join(data_dir, "gb_gold.json")) as f:
        gold = json.load(f)
    with open(os.path.join(data_dir, "gb_silver.json")) as f:
        silver = json.load(f)
    return gold, silver


def phonemes_to_tokens(phonemes_str, vocab):
    """Map an IPA string to Kokoro token IDs via the canonical vocab."""
    return [vocab[ch] for ch in phonemes_str if ch in vocab]


def extract_phonemes(value):
    """Extract the primary phoneme string from a misaki dict entry."""
    if isinstance(value, dict):
        phonemes = value.get("DEFAULT") or value.get("None") or (next(iter(value.values()), None) if value else None)
        if isinstance(phonemes, list):
            return phonemes[0] if phonemes else None
        return phonemes
    if isinstance(value, list):
        return value[0] if value else None
    return value


def main():
    vocab = load_kokoro_vocab()
    gold, silver = load_misaki_dicts()

    seen = {}
    skipped = 0
    for source in [gold, silver]:
        for word, value in source.items():
            if word in seen:
                continue
            phonemes = extract_phonemes(value)
            if not phonemes or not isinstance(phonemes, str):
                skipped += 1
                continue
            tokens = phonemes_to_tokens(phonemes, vocab)
            if tokens:
                seen[word] = f"{word}\t{','.join(str(t) for t in tokens)}"

    lines = sorted(seen.values())
    raw = ("\n".join(lines) + "\n").encode("utf-8")

    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    compressed = compressor.compress(raw) + compressor.flush()
    output = struct.pack("<I", len(raw)) + compressed

    with open(OUTPUT, "wb") as f:
        f.write(output)

    print(f"Entries:    {len(lines)}")
    print(f"Skipped:    {skipped}")
    print(f"Raw:        {len(raw)} bytes ({len(raw)/1024/1024:.1f} MB)")
    print(f"Compressed: {len(output)} bytes ({len(output)/1024:.0f} KB)")
    print(f"Written:    {OUTPUT}")


if __name__ == "__main__":
    main()
