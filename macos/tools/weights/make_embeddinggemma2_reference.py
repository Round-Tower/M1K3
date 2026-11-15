"""EmbeddingGemma 2 reference vectors for M1K3's Swift port (Stream C, slice 1).

Embeds a fixed set of query/document strings with mlx-vlm (the implementation
mlx-community validated their conversions with) and writes token ids + vectors,
so the Swift port is checked against numbers, not vibes. Run:

    HF_HOME=<scratch dir> python -I make_embeddinggemma2_reference.py \\
        macos/Tests/M1K3MLXTests/Fixtures/embeddinggemma2-reference.json

in a venv with mlx-vlm @ 3d87e88402f307efbf68e568971aa887ee7d9ed0 (the revision
mlx-community validated with) + transformers. HF_HOME points at a scratch dir on
purpose: never the app's model cache (the 2026-07-16 pre-seed incident).

One command that builds that venv (the 1.2 GB checkpoint lands in $HF_HOME, default
~/.cache/huggingface, which is not the app's cache):

    uv run --with "mlx-vlm @ git+https://github.com/Blaizzy/mlx-vlm@3d87e88402f307efbf68e568971aa887ee7d9ed0" \\
        --with "mlx==0.32.3" --with "transformers>=5.18" --with pillow --with numpy \\
        python -I make_embeddinggemma2_reference.py <out.json>

Images (#836): the twelve drawings of make_embeddinggemma2_images.py (rendered into a temp folder
on each run), preprocessed the way the checkpoint's Gemma4ImageProcessor does
(aspect-preserving size, antialiased bicubic, 0...1 pixels), then run through mlx-vlm's vision
tower. The image prompt is NONE: the model card says prefixes apply to text only, so an image is
`<bos><boi><image>*n<eoi><eos>`. The EAP Transformers wheel that ships `EmbeddingGemma2Processor`
is not needed: the processor's arithmetic is reproduced here and pinned by the Swift test.

Signed: Kev + claude-opus-5-5, 2026-10-06, Confidence 0.8, Prior: none (new file;
GEMMA_1_1_PLAN Stream C, slice 1). Pinned by EmbeddingGemma2ReferenceTests.
Review: Kev + claude-fable-5.1, 2026-10-10 (#545 review) — `d-long` / `q-long`: a ~900-token
document so the Swift port's sliding-window mask (the one path the short cases never reach)
is checked against the reference too. Regenerated with the same pinned venv.
Review: Kev + claude-opus-5.5, 2026-11-15 (#836) — image cases (`images`, `imageRankingChecks`) and a
caption/query text case per image, appended after the existing text cases (the text rows are untouched).
"""

import base64
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

import mlx.core as mx
import numpy as np
from huggingface_hub import snapshot_download
from mlx_vlm.embedding_loader import load_embedding_model
from PIL import Image
from transformers import AutoTokenizer

REPO = "mlx-community/embeddinggemma-2-8bit"
REVISION = "7505ef2f8ddef45efef6d060865f27989b3c9cec"  # pinned: the fixture names it
QUERY = "task: search result | query: "
DOCUMENT = "title: none | text: "

# ~900 tokens: a plausible knowledge-store note, varied enough not to collapse.
LONG_DOCUMENT = " ".join(
    f"Section {i}. {t}" for i, t in enumerate([
        "The knowledge store keeps one vector per chunk and records the embedder fingerprint beside it.",
        "When the fingerprint changes, the store re-indexes every chunk on the next launch, deferred under heat.",
        "A fingerprint is the model id, the Matryoshka width and the kernel generation of the MLX pin.",
        "Vectors from different fingerprints are never compared; the reindex policy treats them as a different space.",
        "Chunks are about twelve hundred characters and embed title-prefixed unless the content already leads with its title.",
        "Queries embed with the retrieval instruction, documents embed bare, and the floors were derived from that asymmetry.",
        "The grounding gate admits a chunk when its cosine clears the chunk floor and a memory when it clears the memory floor.",
        "Short facts sit lower in the cone than chunks, which is why the two floors differ and are measured separately.",
        "A re-embed of the corpus runs in batches with a per-embed memory reclaim so the peak stays flat during ingest.",
        "The embedder loads once through a single-flight loader so a launch warm and a first query share one container.",
        "Call recordings are retained for ninety days and their summaries are embedded like any other document.",
        "Spotlight donations exclude photo memories and anything withheld from the MCP list, search and get tools.",
        "The hybrid search merges a vector lane and a full-text lane with reciprocal rank fusion before the gate.",
        "A reindex shows real download progress when the model fetches on first use instead of an indefinite spinner.",
        "Pricing notes, meeting minutes and plant maintenance logs all pass through the same chunker and the same embedder.",
        "The hydraulic seal on the conveyor failed under load last Tuesday and the replacement part arrived on Thursday.",
        "The last bus to Dungarvan leaves Waterford at a quarter to ten and the harbour tides peak twice a day.",
        "Nothing in this pipeline leaves the device; the private cloud paths are consented separately and never see the store.",
    ] * 3)
)

CASES = [
    ("q-pricing", "query", "what did we decide about the Pro price?"),
    ("d-pricing", "document", "Pricing v2: Free is €0, Pro is €8 a month, Team is €20 a month per seat."),
    ("q-retention", "query", "how long do we keep call recordings?"),
    ("d-retention", "document", "Call recordings are retained for 90 days, after which they are deleted automatically."),
    ("q-seal", "query", "why did the conveyor stop?"),
    ("d-seal", "document", "The hydraulic seal on the conveyor failed under load and was replaced on Tuesday."),
    ("d-offtopic", "document", "The harbour tides peak twice daily; the spring tide is highest after a new moon."),
    ("q-code", "query", "function that sums invoice amounts from a CSV"),
    ("d-code", "document", "def parse_invoice(path):\n    with open(path) as f:\n        return sum(float(r['amount']) for r in csv.DictReader(f))"),
    ("q-ga", "query", "cathain a bhíonn an bus deireanach go Dún Garbhán?"),
    ("d-de", "document", "Der letzte Bus nach Dungarvan fährt um 21:45 Uhr in Waterford ab."),
    ("d-empty-ish", "document", "ok"),
    # Longer than the 512-token sliding window, so the Swift port's local mask
    # (|i-j| <= 512, both sides) is exercised; every other case fits inside it.
    ("d-long", "document", LONG_DOCUMENT),
    ("q-long", "query", "what happens to the stored vectors when the embedder changes?"),
]

# Relevance the vectors must respect (a smoke check, not a benchmark).
MUST_RANK = [
    ("q-long", "d-long", "d-offtopic"),
    ("q-pricing", "d-pricing", "d-offtopic"),
    ("q-retention", "d-retention", "d-offtopic"),
    ("q-seal", "d-seal", "d-offtopic"),
    ("q-code", "d-code", "d-offtopic"),
]


# Image path constants: config.json / processor_config.json of the pinned revision.
PATCH, POOL, MAX_SOFT = 16, 3, 280
BOS, EOS, BOI, EOI, IMAGE_TOKEN = 2, 1, 255999, 258882, 258880


def target_size(height: int, width: int) -> tuple[int, int]:
    """Gemma4ImageProcessor's aspect-preserving size (same arithmetic as the Swift port)."""
    side = POOL * PATCH
    factor = (MAX_SOFT * POOL * POOL * PATCH * PATCH / max(height * width, 1)) ** 0.5
    th, tw = int(factor * height / side), int(factor * width / side)
    if th == 0:
        th, tw = 1, max(min(int(width / max(height, 1)), MAX_SOFT), 1)
    elif tw == 0:
        tw, th = 1, max(min(int(height / max(width, 1)), MAX_SOFT), 1)
    return th * side, tw * side


def load_images() -> tuple[Path, list]:
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location("eg2_images", here / "make_embeddinggemma2_images.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # *.png is gitignored: the drawings are rendered fresh (deterministic) and travel in the
    # fixture as base64, so nothing but the script has to be committed.
    folder = Path(tempfile.mkdtemp(prefix="eg2-images-"))
    module.main(folder)
    return folder, module.IMAGES


def embed_image(model, path: Path):
    """(768 vector, th, tw, soft tokens) for one image, as the model's processor + mlx-vlm do it."""
    return embed_pil(model, Image.open(path).convert("RGB"))


def noise_pixels(width: int, height: int) -> np.ndarray:
    """A high-frequency, 4032x3024-class stress image from integer arithmetic only, so the Swift stage builds the
    SAME bytes without shipping a 30 MB PNG: per-pixel hash noise (full entropy, aliasing-hostile) under a zone-plate
    chirp. uint32 wraparound is the contract on both sides (Swift: `&*`)."""
    x = np.arange(width, dtype=np.uint32)[None, :]
    y = np.arange(height, dtype=np.uint32)[:, None]
    out = np.empty((height, width, 3), np.uint8)
    for c in range(3):
        mixed = (x * np.uint32(73856093)) ^ (y * np.uint32(19349663)) ^ np.uint32((c * 83492791) & 0xFFFFFFFF)
        noise = (mixed * np.uint32(2654435761)) >> np.uint32(24)
        chirp = ((x * x * np.uint32(c + 1) + y * y * np.uint32(3)) >> np.uint32(9)) & np.uint32(255)
        out[:, :, c] = ((noise >> np.uint32(2)) + ((chirp * np.uint32(3)) >> np.uint32(2))).astype(np.uint8)
    return out


def embed_pil(model, image):
    th, tw = target_size(image.height, image.width)
    resized = image.resize((tw, th), Image.BICUBIC)  # Pillow's antialiased bicubic (a = -0.5)
    pixels = np.asarray(resized, dtype=np.float32).transpose(2, 0, 1)[None] / 255.0
    soft = (th // PATCH) * (tw // PATCH) // (POOL * POOL)
    ids = [BOS, BOI] + [IMAGE_TOKEN] * soft + [EOI, EOS]
    arr = mx.array([ids])
    result = model(arr, attention_mask=mx.ones_like(arr), pixel_values=mx.array(pixels))
    v = result.text_embeds[0].astype(mx.float32)
    mx.eval(v)
    return v, th, tw, soft


def main(out: Path) -> None:
    image_dir, image_specs = load_images()
    info_path = snapshot_download(REPO, revision=REVISION)
    path = Path(info_path)
    sha = path.name  # snapshots/<sha>
    model = load_embedding_model(path)
    tok = AutoTokenizer.from_pretrained(path)

    # One query and one caption per image, appended so the earlier text rows are untouched.
    image_cases = []
    for image_id, _file, _size, caption, query in image_specs:
        image_cases += [(f"q-img-{image_id}", "query", query), (f"d-img-{image_id}", "document", caption)]

    rows, vecs = [], {}
    for case_id, role, text in CASES + image_cases:
        prompted = (QUERY if role == "query" else DOCUMENT) + text
        ids = tok(prompted, add_special_tokens=True)["input_ids"]
        arr = mx.array([ids])
        result = model(arr, attention_mask=mx.ones_like(arr))
        v = result.text_embeds[0].astype(mx.float32)
        mx.eval(v)
        full = [round(float(x), 6) for x in v.tolist()]
        t512 = v[:512] / mx.linalg.norm(v[:512])
        rows.append({
            "id": case_id, "role": role, "text": text, "prompted": prompted,
            "inputIDs": ids, "embedding768": full,
            "embedding512": [round(float(x), 6) for x in t512.tolist()],
        })
        vecs[case_id] = v

    def cos(a, b):
        return float((vecs[a] * vecs[b]).sum())

    checks = []
    for q, good, bad in MUST_RANK:
        g, b = cos(q, good), cos(q, bad)
        checks.append({"query": q, "relevant": good, "irrelevant": bad, "cosRelevant": round(g, 4),
                       "cosIrrelevant": round(b, 4), "ok": g > b})
    images, image_vecs = [], {}
    for image_id, file, _size, _caption, _query in image_specs:
        path = image_dir / file
        v, th, tw, soft = embed_image(model, path)
        image_vecs[image_id] = v
        t512 = v[:512] / mx.linalg.norm(v[:512])
        images.append({
            "id": image_id, "file": file, "width": Image.open(path).width, "height": Image.open(path).height,
            "targetHeight": th, "targetWidth": tw, "softTokens": soft,
            "queryCase": f"q-img-{image_id}", "captionCase": f"d-img-{image_id}",
            "pngBase64": base64.b64encode(path.read_bytes()).decode(),
            "embedding768": [round(float(x), 6) for x in v.tolist()],
            "embedding512": [round(float(x), 6) for x in t512.tolist()],
        })

    # A noisy, high-frequency 4032x3024 frame (what a real photo stresses that flat drawings do not).
    procedural = []
    for image_id, w, h in [("noise4032", 4032, 3024)]:
        v, th, tw, soft = embed_pil(model, Image.fromarray(noise_pixels(w, h)))
        t512 = v[:512] / mx.linalg.norm(v[:512])
        procedural.append({
            "id": image_id, "formula": "noise-chirp-v1", "width": w, "height": h,
            "targetHeight": th, "targetWidth": tw, "softTokens": soft,
            "embedding768": [round(float(x), 6) for x in v.tolist()],
            "embedding512": [round(float(x), 6) for x in t512.tolist()],
        })

    # Text->image: each query against its own picture and against the hardest other picture.
    image_checks, matrix = [], {}
    for image_id, *_ in image_specs:
        q = vecs[f"q-img-{image_id}"]
        scores = {other: float((q * image_vecs[other]).sum()) for other, *_ in image_specs}
        matrix[image_id] = scores
        hardest = max((o for o in scores if o != image_id), key=scores.get)
        image_checks.append({"query": f"q-img-{image_id}", "relevant": image_id, "irrelevant": hardest,
                             "cosRelevant": round(scores[image_id], 4), "cosIrrelevant": round(scores[hardest], 4),
                             "ok": scores[image_id] > scores[hardest]})

    doc = {
        "model": REPO, "modelRevision": sha,
        "generator": "mlx-vlm 3d87e88402f307efbf68e568971aa887ee7d9ed0, mlx " + mx.__version__,
        "pooling": "mean over attention mask, then L2 normalise (1_Pooling + 2_Normalize)",
        "prompts": {"query": QUERY, "document": DOCUMENT},
        "mrl512": "first 512 dims of the 768 vector, re-normalised",
        "cases": rows, "rankingChecks": checks,
        "imagePrompt": {
            "version": "image-v2",
            "template": "<bos><start_of_image><image_soft_token>*n<end_of_image><eos>",
            "prefix": "",
            "note": "the model card: task prefixes apply to text only; pass images without any prefix",
            "ids": {"bos": BOS, "boi": BOI, "image": IMAGE_TOKEN, "eoi": EOI, "eos": EOS},
            "preprocessing": "aspect-preserving size (max 280 soft tokens, patch 16, pool 3); Pillow BICUBIC resize "
                             "(horizontal pass, round to uint8, vertical pass); 0...1. Any change bumps image-v2.",
        },
        "images": images, "imageRankingChecks": image_checks,
        "proceduralImages": procedural,
    }
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=1))
    print("revision", sha)
    top1 = sum(1 for c in image_checks if c["ok"])
    print(f"image checks: {top1}/{len(image_checks)} queries rank their picture above the hardest other")
    for c in image_checks:
        print(("OK  " if c["ok"] else "BAD ") + f'{c["query"]}: {c["cosRelevant"]} vs {c["irrelevant"]} {c["cosIrrelevant"]}')
    print("image tokens:", {i["id"]: (i["targetWidth"], i["targetHeight"], i["softTokens"]) for i in images})
    for c in checks:
        print(("OK  " if c["ok"] else "BAD ") + f'{c["query"]}: relevant {c["cosRelevant"]} vs off-topic {c["cosIrrelevant"]}')
    print("tokens:", {r["id"]: len(r["inputIDs"]) for r in rows})
    print("first ids:", rows[0]["inputIDs"][:8], "... last:", rows[0]["inputIDs"][-3:])


if __name__ == "__main__":
    main(Path(sys.argv[1]))
