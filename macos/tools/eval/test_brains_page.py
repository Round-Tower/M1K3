"""Pins brains_page.py: the site's brains.json + brains.html are generated from the
harness's own JSON (ChatEvalDocument, schemaVersion 1) and the repo's pinned
weights manifest — never typed by hand. A scoreboard whose numbers can drift
from the run that produced them is worse than no scoreboard."""

import json

import brains_page as bp

MANIFEST = {
    "schemaVersion": 1,
    "repos": {
        "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510": {
            "revision": "c073725c8ac051eabad9d64f4dcd3019d1072559",
            "downloadBase": "llm",
            "files": {"model.safetensors": {"size": 2263022417, "sha256": "aa"}, "config.json": {"size": 938, "sha256": "bb"}},
        },
        "mlx-community/LFM2.5-1.2B-Instruct-4bit": {
            "revision": "dee2f8a2786e6648bb644a7ca40652842490034b",
            "downloadBase": "llm",
            "files": {"model.safetensors": {"size": 663000000, "sha256": "dd"}},
        },
        "mlx-community/gemma-4-12B-it-4bit": {
            "revision": "73bcf09092aa000000000000000000000000dead",
            "downloadBase": "llm",
            "files": {"model.safetensors": {"size": 6772000000, "sha256": "cc"}},
        },
        "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ": {
            "revision": "6c3ae70858513f1a78e9cdca3cae330d9075cd2a",
            "downloadBase": "embedder",
            "files": {"model.safetensors": {"size": 349000000, "sha256": "dd"}},
        },
    },
}


def score(fixture, kind, passed, latency, repeat=0, fail_check=None):
    # every real score carries skipped checks (follow-ups, ends-with-question); a skip is not a fail
    checks = [{"name": "non-empty", "outcome": "pass", "detail": "10 chars"},
              {"name": "follow-ups", "outcome": "skip", "detail": "0 offered"}]
    if fail_check:
        checks.append({"name": fail_check, "outcome": "fail", "detail": "expected datetime"})
    return {
        "fixtureID": fixture, "kind": kind, "latencyMS": latency, "repeatIndex": repeat,
        "answerPreview": "hello", "checks": checks,
    }


RUN = {
    "schemaVersion": 1,
    "provenance": {
        "date": "2026-09-05T12:35:34Z", "hardware": "Apple M1 Max · 64 GB", "osVersion": "macOS 26.4",
        "appCommit": "b7e61299", "mlxSwiftLMRevision": "c97539da", "powerMode": 2, "powerSource": "ac", "livePath": True,
        "repeats": 2, "notes": "machine quiet",
    },
    "runs": [
        {"brainID": "mini", "scores": [
            score("tool-datetime", "tool-use", True, 19846),
            score("tool-datetime", "tool-use", True, 9000, repeat=1),
            score("tool-search-doc", "tool-use", False, 30000, fail_check="calls search_knowledge"),
            score("tool-search-doc", "tool-use", True, 25000, repeat=1),
            score("open-hello", "open-chat", True, 1200),
        ]},
        {"brainID": "lil", "modelID": "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510", "scores": [
            score("tool-datetime", "tool-use", True, 4400),
        ]},
    ],
}


def test_brains_come_from_the_manifest_not_prose():
    brains = bp.brains(MANIFEST)
    by_tier = {b["tier"]: b for b in brains}
    assert [b["tier"] for b in brains] == ["mini", "pocket", "lil", "big"]
    assert by_tier["mini"]["backing"] == "apple-foundation-models" and by_tier["mini"]["modelID"] is None
    # pocket is the Mini for devices without Apple Intelligence — same name, its own pin.
    assert by_tier["pocket"]["name"] == "Mini" and by_tier["pocket"]["modelID"] == "mlx-community/LFM2.5-1.2B-Instruct-4bit"
    assert by_tier["pocket"]["revision"] == "dee2f8a2786e6648bb644a7ca40652842490034b"
    lil = by_tier["lil"]
    assert lil["modelID"] == "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510"
    assert lil["revision"] == "c073725c8ac051eabad9d64f4dcd3019d1072559"
    assert lil["huggingFace"] == "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510/tree/c073725c8ac051eabad9d64f4dcd3019d1072559"
    assert lil["sizeMiB"] == 2158  # every pinned file, not just the weights
    assert by_tier["big"]["sizeMiB"] == 6458
    # the embedder is not a brain
    assert all(b["modelID"] != "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ" for b in brains)


def test_summary_counts_every_trial_and_keeps_the_failures():
    doc = bp.summarise_run(RUN)
    assert doc["provenance"]["appCommit"] == "b7e61299"
    mini = doc["brains"][0]
    assert mini["brainID"] == "mini" and mini["modelID"] is None
    assert mini["byKind"]["tool-use"] == {"passed": 3, "total": 4}
    assert mini["byKind"]["open-chat"] == {"passed": 1, "total": 1}
    assert mini["passed"] == 4 and mini["total"] == 5
    assert mini["medianLatencyMS"] == 19846  # median of 5, not mean
    # even count rounds, never truncates
    two = bp.summarise_run(dict(RUN, runs=[{"brainID": "x", "scores": [score("a", "k", True, 1), score("a", "k", True, 2, 1)]}]))
    assert two["brains"][0]["medianLatencyMS"] == 2
    assert mini["failures"] == [
        {"fixtureID": "tool-search-doc", "repeatIndex": 0, "check": "calls search_knowledge", "detail": "expected datetime"}
    ]
    lil = doc["brains"][1]
    assert lil["modelID"] == "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510" and lil["total"] == 1


def test_a_skipped_check_counts_as_a_pass():
    run = {"brainID": "lil", "scores": [{
        "fixtureID": "f", "kind": "open-chat", "latencyMS": 5, "repeatIndex": 0, "answerPreview": "",
        "checks": [{"name": "follow-ups", "outcome": "skip", "detail": ""}],
    }]}
    doc = bp.summarise_run(dict(RUN, runs=[run]))
    assert doc["brains"][0]["passed"] == 1 and doc["brains"][0]["failures"] == []


def test_a_shipped_tier_without_a_pin_refuses_to_render():
    thin = {"schemaVersion": 1, "repos": {k: v for k, v in MANIFEST["repos"].items() if "gemma" not in k}}
    try:
        bp.brains(thin)
    except bp.MissingPin as e:
        assert "gemma-4-12B" in str(e)
    else:
        raise AssertionError("the page must never describe a brain the binary does not pin")


def test_unknown_schema_fails_loudly():
    bad = dict(RUN, schemaVersion=2)
    try:
        bp.summarise_run(bad)
    except bp.UnsupportedSchema as e:
        assert "2" in str(e)
    else:
        raise AssertionError("a schema we have never seen must not be silently reshaped")


def test_runs_are_ordered_by_date_not_input_order():
    later = dict(RUN, provenance=dict(RUN["provenance"], date="2026-09-06T09:00:00Z"))
    doc = bp.document(MANIFEST, [later, RUN], generated="2026-09-06")
    assert [r["provenance"]["date"][:10] for r in doc["runs"]] == ["2026-09-05", "2026-09-06"]


def test_document_is_deterministic_and_sorted():
    a = bp.document(MANIFEST, [RUN], generated="2026-09-05")
    b = bp.document(MANIFEST, [RUN], generated="2026-09-05")
    assert a == b
    text = bp.to_json(a)
    assert text == bp.to_json(b)
    assert json.loads(text)["schemaVersion"] == 1
    assert json.loads(text)["generated"] == "2026-09-05"
    assert text.index('"brains"') < text.index('"runs"')  # sorted keys
    assert json.loads(text)["stateOfPlay"]["mtp"]["batteryAdaptivePower"][0]["ratio"] == "0.73×"
    assert json.loads(text)["stateOfPlay"]["mtp"]["acHighPower"][2]["ratio"] == "0.48×"


def test_html_carries_provenance_and_stays_offline():
    html = bp.render_html(bp.document(MANIFEST, [RUN], generated="2026-09-05"))
    for needle in ("Apple M1 Max", "b7e61299", "c97539da", "power ac · powermode 2", "n = 2", "3/4", "tool-search-doc"):
        assert needle in html, needle
    # offline means offline: the type is self-hosted (site/fonts.css), never a Google Fonts request
    assert "fonts.googleapis.com" not in html and "fonts.gstatic.com" not in html
    assert 'href="fonts.css"' in html and "vt323-latin-400-normal.woff2" in html
    assert 'as="font" type="font/woff2" crossorigin' in html  # a font preload without crossorigin double-downloads
    # the phosphor mark rides beside the wordmark, same as every other page
    assert 'class="mark"' in html and 'src="favicon.svg"' in html
    # the read-out's editorial facts ride along, dated
    assert "Qwen3.8-27B" in html and "0.73" in html and "0.66" in html
    # a legacy run without powerSource renders as unknown, never as a guess
    legacy = dict(RUN, provenance={k: v for k, v in RUN["provenance"].items() if k != "powerSource"})
    assert "power unknown · powermode 2" in bp.render_html(bp.document(MANIFEST, [legacy], generated="2026-09-05"))
    # the same shell as the other answer pages (site/vs-ollama.html head): geo.css + the self-hosted fonts.css, no <script>
    assert "<script" not in html
    assert 'href="geo.css"' in html
    # the full-pass emphasis class is earned, not default: Mini is 4/5 here
    assert '<td class="">4/5</td>' in html and '<td class="yes">1/1</td>' in html
    assert '<th scope="row">tool-use</th>' in html
    assert "huggingface.co/mlx-community/gemma-4-12B-it-4bit/tree/73bcf09092aa" in html
    assert "Generated by" in html and "brains_page.py" in html


def test_cli_writes_both_files(tmp_path):
    (tmp_path / "m.json").write_text(json.dumps(MANIFEST))
    (tmp_path / "r.json").write_text(json.dumps(RUN))
    rc = bp.main(["--run", str(tmp_path / "r.json"), "--manifest", str(tmp_path / "m.json"),
                  "--json", str(tmp_path / "brains.json"), "--html", str(tmp_path / "brains.html"),
                  "--generated", "2026-09-05"])
    assert rc == 0
    out = json.loads((tmp_path / "brains.json").read_text())
    assert out["runs"][0]["brains"][0]["byKind"]["tool-use"] == {"passed": 3, "total": 4}
    assert "<title>M1K3 Brains" in (tmp_path / "brains.html").read_text()
