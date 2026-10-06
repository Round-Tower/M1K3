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
]

# Relevance the vectors must respect (a smoke check, not a benchmark).
MUST_RANK = [
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
