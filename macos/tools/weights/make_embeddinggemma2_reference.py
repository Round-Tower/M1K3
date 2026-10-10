"""EmbeddingGemma 2 reference vectors for M1K3's Swift port (Stream C, slice 1).

Embeds a fixed set of query/document strings with mlx-vlm (the implementation
mlx-community validated their conversions with) and writes token ids + vectors,
so the Swift port is checked against numbers, not vibes. Run:

    HF_HOME=<scratch dir> python -I make_embeddinggemma2_reference.py \\
        macos/Tests/M1K3MLXTests/Fixtures/embeddinggemma2-reference.json

in a venv with mlx-vlm @ 3d87e88402f307efbf68e568971aa887ee7d9ed0 (the revision
mlx-community validated with) + transformers. HF_HOME points at a scratch dir on
purpose: never the app's model cache (the 2026-07-16 pre-seed incident).

Signed: Kev + claude-opus-5-5, 2026-10-06, Confidence 0.8, Prior: none (new file;
GEMMA_1_1_PLAN Stream C, slice 1). Pinned by EmbeddingGemma2ReferenceTests.
Review: Kev + claude-fable-5.1, 2026-10-10 (#545 review) — `d-long` / `q-long`: a ~900-token
document so the Swift port's sliding-window mask (the one path the short cases never reach)
is checked against the reference too. Regenerated with the same pinned venv.
"""

import json
import sys
from pathlib import Path

import mlx.core as mx
from huggingface_hub import snapshot_download
from mlx_vlm.embedding_loader import load_embedding_model
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


def main(out: Path) -> None:
    info_path = snapshot_download(REPO, revision=REVISION)
    path = Path(info_path)
    sha = path.name  # snapshots/<sha>
    model = load_embedding_model(path)
    tok = AutoTokenizer.from_pretrained(path)

    rows, vecs = [], {}
    for case_id, role, text in CASES:
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
    doc = {
        "model": REPO, "modelRevision": sha,
        "generator": "mlx-vlm 3d87e88402f307efbf68e568971aa887ee7d9ed0, mlx " + mx.__version__,
        "pooling": "mean over attention mask, then L2 normalise (1_Pooling + 2_Normalize)",
        "prompts": {"query": QUERY, "document": DOCUMENT},
        "mrl512": "first 512 dims of the 768 vector, re-normalised",
        "cases": rows, "rankingChecks": checks,
    }
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=1))
    print("revision", sha)
    for c in checks:
        print(("OK  " if c["ok"] else "BAD ") + f'{c["query"]}: relevant {c["cosRelevant"]} vs off-topic {c["cosIrrelevant"]}')
    print("tokens:", {r["id"]: len(r["inputIDs"]) for r in rows})
    print("first ids:", rows[0]["inputIDs"][:8], "... last:", rows[0]["inputIDs"][-3:])


if __name__ == "__main__":
    main(Path(sys.argv[1]))
