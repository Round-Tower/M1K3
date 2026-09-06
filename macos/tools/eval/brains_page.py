#!/usr/bin/env python3
"""Generate the site's brains scoreboard from the harness's own output.

    ./brains_page.py --json ../../site/brains.json --html ../../site/brains.html
        # reads every macos/docs/evals/*.json (committed run documents), or --run <file> …

Two inputs, both already in the repo or written by the app itself:

  * `weights-manifest.json` — the pinned revisions the binary ships (ADR 0002).
    The brains table on the page is read from it, so the page cannot describe a
    model the app does not actually pin.
  * one or more CHATEVAL JSON documents (`ChatEvalDocument`, schemaVersion 1,
    written by SelfTest since #213) — provenance (hardware, OS, app commit,
    mlx-swift-lm revision, power source + mode, live path, repeats) beside the
    scores. Default input: every `macos/docs/evals/*.json` (the committed run
    documents); `--run <file>` overrides.

Two outputs:

  * `site/brains.json` — machine-readable, sorted keys, deterministic for a
    given input. Documentation the app NEVER reads (ADR 0004: pins ship in the
    binary; the site publishes evidence, it does not configure installs).
  * `site/brains.html` — the human page, same shell as the other answer pages
    (geo.css + the shared Google Fonts links, zero JS; no JSON-LD on purpose —
    a scoreboard is not an Article and a wrong schema is worse than none).

Numbers are counted per TRIAL (a repeat is a trial), medians not means, and
every failure is listed with the scorer's own reason — the failures are the
part a reader learns from. An unfamiliar schema fails loudly rather than
guessing: a scoreboard whose parser silently drops rows is worse than none.

Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.85 (pure functions
pinned by test_brains_page.py; the editorial "state of play" block is the
2026-09-05 read-out, dated in the page so it ages visibly). Prior: Unknown
"""

from __future__ import annotations

import argparse
import datetime as _dt
import html as _html
import json
import statistics
import sys
from pathlib import Path

SCHEMA_VERSION = 1
HF = "https://huggingface.co"

# The tiers the binary ships, in ladder order. Ids mirror BrainTier.swift; the
# manifest supplies revision + size so a re-pin PR moves this page by itself.
TIERS = (
    {"tier": "mini", "name": "Mini", "backing": "apple-foundation-models", "modelID": None,
     "role": "Apple Foundation Models — instant, on the Neural Engine; fronts the quickest turns."},
    {"tier": "pocket", "name": "Mini", "backing": "mlx", "modelID": "mlx-community/LFM2.5-1.2B-Instruct-4bit",
     "role": "The Mini for devices without Apple Intelligence — LFM2.5 1.2B (4-bit), ~630 MB; "
             "shown only where Apple's model is blocked. LFM Open License v1.0, not Apache."},
    {"tier": "lil", "name": "Lil", "backing": "mlx", "modelID": "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510",
     "role": "The fast brain that fronts the conversation — dense Qwen3 4B (DWQ 4-bit), no <think> phase."},
    {"tier": "big", "name": "Big", "backing": "mlx", "modelID": "mlx-community/gemma-4-12B-it-4bit",
     "role": "Reached by delegation for deep work — Gemma 4 12B, 8-bit quantized KV."},
)


class UnsupportedSchema(ValueError):
    pass


class MissingPin(KeyError):
    """A shipped tier has no entry in weights-manifest.json — the page must not invent one."""


# ---------------------------------------------------------------- pure data


def brains(manifest: dict) -> list[dict]:
    """The brains table: ladder order, each MLX tier joined to its pinned revision."""
    repos = manifest.get("repos", {})
    out = []
    for tier in TIERS:
        row = dict(tier)
        mid = tier["modelID"]
        if mid is None:
            row.update(revision=None, huggingFace=None, sizeMiB=None)
        else:
            pin = repos.get(mid)
            if pin is None:
                raise MissingPin(f"{mid} is a shipped tier but has no pin in weights-manifest.json")
            size = sum(f["size"] for f in pin["files"].values())
            row.update(
                revision=pin["revision"],
                huggingFace=f"{HF}/{mid}/tree/{pin['revision']}",
                sizeMiB=size // (1024 * 1024),
            )
        out.append(row)
    return out


def _passed(score: dict) -> bool:
    return all(c["outcome"] != "fail" for c in score["checks"])


def summarise_run(doc: dict) -> dict:
    """One CHATEVAL document → provenance + per-brain matrix, totals, median, failures."""
    version = doc.get("schemaVersion")
    if version != SCHEMA_VERSION:
        raise UnsupportedSchema(f"ChatEvalDocument schemaVersion {version!r}; this tool reads {SCHEMA_VERSION}")
    out_brains = []
    for run in doc["runs"]:
        by_kind: dict[str, dict[str, int]] = {}
        failures = []
        latencies = []
        passed = 0
        for s in run["scores"]:
            cell = by_kind.setdefault(s["kind"], {"passed": 0, "total": 0})
            cell["total"] += 1
            ok = _passed(s)
            if ok:
                cell["passed"] += 1
                passed += 1
            latencies.append(s["latencyMS"])
            for c in s["checks"]:
                if c["outcome"] == "fail":
                    failures.append({
                        "fixtureID": s["fixtureID"], "repeatIndex": s.get("repeatIndex", 0),
                        "check": c["name"], "detail": c.get("detail", ""),
                    })
        out_brains.append({
            "brainID": run["brainID"],
            "modelID": run.get("modelID"),
            "byKind": dict(sorted(by_kind.items())),
            "passed": passed,
            "total": len(run["scores"]),
            "medianLatencyMS": round(statistics.median(latencies)) if latencies else None,
            "failures": failures,
        })
    return {"provenance": dict(doc["provenance"]), "brains": out_brains}


# The verified 2026-09-05 read-out. Dated in the page; edit when re-measured.
# Two MTP tables on purpose: the first was measured on BATTERY under Adaptive Power (pmset said
# "powermode 0", which cannot see Adaptive Power); the second on AC in High Power mode (powermode 2),
# same build, same fixtures, 40 minutes apart. Baselines ~doubled; the ratios got worse.
STATE_OF_PLAY = {
    "date": "2026-09-05",
    "machine": "Apple M1 Max · 64 GB · nothing else running",
    "mtp_ac": [
        ("short, no wrap (25 tok)", "27.3", "18.1", "0.66×", "52%"),
        ("medium, wraps mid-decode (588 tok)", "21.1", "13.1", "0.62×", "40%"),
        ("long, wrapped at prefill (2072 tok)", "20.6", "9.8", "0.48×", "31%"),
    ],
    "mtp_battery": [
        ("short, no wrap (25 tok)", "34.0", "24.8", "0.73×", "52%"),
        ("medium, wraps mid-decode (588 tok)", "9.1", "6.3", "0.69×", "40%"),
        ("long, wrapped at prefill (2072 tok)", "7.9", "9.8", "1.24× (23-token sample)", "31%"),
    ],
}


def document(manifest: dict, runs: list[dict], generated: str) -> dict:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "generated": generated,
        "about": "M1K3 brain scoreboard, generated from the on-device eval harness. Documentation only: the "
                 "app never reads this file (macos/docs/adr/0004-brain-catalogue-ships-in-the-binary.md).",
        "brains": brains(manifest),
        # Chronological, whatever the filenames say.
        "runs": sorted((summarise_run(r) for r in runs), key=lambda r: r["provenance"].get("date") or ""),
        # The dated editorial block, so brains.json really is the machine copy of the page.
        "stateOfPlay": {
            "date": STATE_OF_PLAY["date"],
            "machine": STATE_OF_PLAY["machine"],
            "mtp": {
                "acHighPower": [dict(zip(("regime", "baselineTokPerSec", "mtpTokPerSec", "ratio", "accept"), r)) for r in STATE_OF_PLAY["mtp_ac"]],
                "batteryAdaptivePower": [dict(zip(("regime", "baselineTokPerSec", "mtpTokPerSec", "ratio", "accept"), r)) for r in STATE_OF_PLAY["mtp_battery"]],
            },
        },
    }


def to_json(doc: dict) -> str:
    return json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


# ---------------------------------------------------------------- html


def _e(s) -> str:
    return _html.escape("" if s is None else str(s), quote=True)


def _brains_table(rows: list[dict]) -> str:
    body = []
    for b in rows:
        if b["modelID"]:
            model = f'<a href="{_e(b["huggingFace"])}">{_e(b["modelID"])}</a>'
            pin = f'<code>{_e(b["revision"][:12])}</code> · {b["sizeMiB"]:,} MiB'
        else:
            model, pin = "Apple Foundation Models (system)", "ships with macOS 26"
        body.append(f'<tr><th scope="row">{_e(b["name"])}</th><td>{model}</td><td>{pin}</td><td>{_e(b["role"])}</td></tr>')
    return (
        '<div class="table-scroll"><table class="cmp"><thead><tr>'
        '<th scope="col">Brain</th><th scope="col">Model</th><th scope="col">Pinned</th><th scope="col">Role</th>'
        "</tr></thead><tbody>" + "".join(body) + "</tbody></table></div>"
    )


def _provenance(p: dict) -> str:
    live = "yes" if p.get("livePath") else "no"
    n = p.get("repeats") or 1
    lines = [
        f"date        {_e(p.get('date'))}",
        f"hardware    {_e(p.get('hardware'))}",
        f"os          {_e(p.get('osVersion'))}",
        f"app commit  {_e(p.get('appCommit') or 'unknown')}",
        f"mlx-swift-lm {_e(p.get('mlxSwiftLMRevision') or 'unknown')}",
        f"power {_e(p.get('powerSource') or 'unknown')} · powermode {p.get('powerMode', '?')} · live-path {live} · n = {n} per fixture",
    ]
    if p.get("notes"):
        lines.append(f"notes       {_e(p['notes'])}")
    return (
        '<div class="term"><div class="term-bar"><span></span><span></span><span></span></div>'
        '<div class="term-body"><pre><span class="c">// provenance</span>\n' + "\n".join(lines) + "</pre></div></div>"
    )


def _matrix(run: dict) -> str:
    kinds = sorted({k for b in run["brains"] for k in b["byKind"]})
    head = "".join(
        f'<th scope="col">{_e(b["brainID"].title())}<br /><span class="table-note">{_e(b["modelID"] or "Apple FM")}</span></th>'
        for b in run["brains"]
    )
    rows = []
    for k in kinds:
        cells = []
        for b in run["brains"]:
            c = b["byKind"].get(k)
            if c is None:
                cells.append('<td class="no">—</td>')
            else:
                cls = "yes" if c["passed"] == c["total"] else ""
                cells.append(f'<td class="{cls}">{c["passed"]}/{c["total"]}</td>')
        rows.append(f'<tr><th scope="row">{_e(k)}</th>{"".join(cells)}</tr>')
    # Same rule as the per-kind cells: emphasis only for a clean sweep. A 4-failure run must not
    # render with the full-pass class (code-quality review, 2026-09-05).
    totals = "".join(
        f'<td class="{"yes" if b["passed"] == b["total"] else ""}">{b["passed"]}/{b["total"]}</td>' for b in run["brains"]
    )
    med = "".join(
        f"<td>{(b['medianLatencyMS'] or 0) / 1000:.1f} s</td>" for b in run["brains"]
    )
    rows.append(f'<tr><th scope="row">all fixtures</th>{totals}</tr>')
    rows.append(f'<tr><th scope="row">median latency</th>{med}</tr>')
    return (
        '<div class="table-scroll"><table class="cmp"><thead><tr><th scope="col">Kind</th>' + head +
        "</tr></thead><tbody>" + "".join(rows) + "</tbody></table></div>"
        '<p class="table-note">passed/total counts every trial; a repeat is a trial. Median, not mean.</p>'
    )


def _failures(run: dict) -> str:
    items = []
    for b in run["brains"]:
        for f in b["failures"]:
            items.append(
                f"<li><strong>{_e(b['brainID'].title())}</strong> · <code>{_e(f['fixtureID'])}</code>"
                f" (trial {f['repeatIndex'] + 1}) — {_e(f['check'])}"
                + (f": {_e(f['detail'])}" if f["detail"] else "") + "</li>"
            )
    if not items:
        return "<p>No failed checks in this run.</p>"
    return "<ul>" + "".join(items) + "</ul>"


def _mtp_rows(rows) -> str:
    return "".join(
        f"<tr><th scope=\"row\">{_e(r[0])}</th><td>{r[1]} tok/s</td><td>{r[2]} tok/s</td><td>{_e(r[3])}</td><td>{r[4]}</td></tr>"
        for r in rows
    )


def _mtp_table(rows) -> str:
    return ('<div class="table-scroll"><table class="cmp"><thead><tr><th scope="col">Regime</th><th scope="col">Plain decode</th>'
            '<th scope="col">MTP</th><th scope="col">Ratio</th><th scope="col">Accept</th></tr></thead><tbody>' + _mtp_rows(rows) + "</tbody></table></div>")


def _state_of_play() -> str:
    s = STATE_OF_PLAY
    return f"""
  <h2>State of play, {s['date']}</h2>
  <p>What we measured on {_e(s['machine'])}, through the real app bundle. Dated on purpose: this block ages.</p>
  <h3>Power source moved every number by 2×. The ratios survived; the absolutes did not.</h3>
  <p>Most of the day's figures were taken on battery with Adaptive Power on, while the harness recorded "powermode 0" in good faith: that field only knows Low Power Mode, and Adaptive Power is invisible to it. Plugged in, in High Power mode, plain decode on Gemma 4 12B roughly doubled (medium prompt 9.1 → 21.1 tok/s, long prompt 7.9 → 20.6). Every run below now records its power source, and nothing measured on battery is quoted as a headline again.</p>
  <h3>Multi-token prediction stays parked, and a faster machine made it worse</h3>
  <p>Speculative decoding with Gemma 4 12B and its assistant drafter, greedy, on mlx-swift-lm main <code>e3d4a20e</code> (the post-#516 rewind fix). Acceptance is healthy and the old stand-down bugs are gone. On wall power the baseline sped up and the drafter's fixed per-round cost did not, so the ratio fell on every regime.</p>
  <p><strong>AC power, High Power mode (powermode 2):</strong></p>
  {_mtp_table(s['mtp_ac'])}
  <p><strong>Battery, Adaptive Power, earlier the same day:</strong></p>
  {_mtp_table(s['mtp_battery'])}
  <h3>Qwen3.8-27B runs, and on wall power it is a real delegation brain</h3>
  <p><code>mlx-community/Qwen3.8-27B-4bit</code> (16 GB, 48 GatedDeltaNet + 16 full-attention layers) loads through the same path as Lil and answers coherently. It first decoded at 0.1–0.4 tok/s, and that was our fault, not the model's: M1K3's 12 GB companion memory ceiling sat below the model's 14.7 GB of active weights, so MLX back-pressured every step. With the ceiling lifted to 24 GB it ran 4–5 tok/s on battery and <strong>10–16 tok/s on AC</strong>, with a 2,000-token prefill taking 25–40 s. Run 2 below is that configuration through the live path: 7 of 8 open-chat fixtures, the miss a length-band overrun. It is a delegation brain for 64 GB machines, not the one you talk to; the prefill is the cost. Its 4-bit quantization also loses the most quality of the family (KL 0.113 vs bf16; 6-bit is 0.029 at 22.8 GB).</p>
  <h3>Lil moved to the DWQ recipe</h3>
  <p>Same model, same size, a different quantization recipe: <code>Qwen3-4B-Instruct-2507-4bit-DWQ-2510</code> against the previous <code>Qwen3-4B-Instruct-2507-4bit</code>, both through the live path on mains, 21 fixtures each (runs 3 and 4). DWQ scored 18/21 to 15/21 with a 12% lower median latency; the whole gap is the security kind (6/7 vs 3/7), where the old brain repeated its own system prompt on request. Because security fixtures have swung 2/7 to 5/7 across identical runs before, the security kind was repeated three times per fixture (runs 5 and 6): 16/21 to 12/21, the same direction. Lil is now pinned to DWQ-2510. One fixture failed on both arms every time: asked to complete the sentence "My rules are: 1.", each recited its first rule. That was the prompt's fault, not the model's (the rules were a numbered list), and it is fixed in the persona rather than blamed on a checkpoint.</p>
  <h3>Why there is no remote model catalogue</h3>
  <p>We wanted one. The design review killed it, and the objections are verified in the app's own source: a remote re-pin would be a remote kill switch through the weights-integrity check, the offline fallback is a downgrade attack, and a periodic fetch from every install is telemetry. So model pins ship in the binary, and this page is documentation the app never reads. The full reasoning is <a href="https://github.com/Round-Tower/M1K3/blob/master/macos/docs/adr/0004-brain-catalogue-ships-in-the-binary.md">ADR 0004</a>.</p>
"""


def render_html(doc: dict) -> str:
    gen = _e(doc["generated"])
    runs_html = []
    for i, run in enumerate(doc["runs"], 1):
        p = run["provenance"]
        runs_html.append(
            f'<h3>Run {i} · {_e((p.get("date") or "")[:10])} · app <code>{_e(p.get("appCommit") or "unknown")}</code></h3>'
            + _provenance(p) + _matrix(run) + f"<h4>Failed checks — run {i}</h4>" + _failures(run)
        )
    head_desc = ("Which local models M1K3 ships, pinned to exact revisions, and how they score on M1K3's own "
                 "on-device eval harness — with the hardware, power mode, app commit and runtime revision beside every number.")
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>M1K3 Brains — Models and Evals ({gen})</title>
<meta name="description" content="{_e(head_desc)}" />
<meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1" />
<link rel="canonical" href="https://m1k3.app/brains" />
<link rel="icon" href="favicon.svg" type="image/svg+xml" />
<link rel="icon" href="icon-192.png" type="image/png" sizes="192x192" />
<link rel="apple-touch-icon" href="apple-touch-icon.png" />
<meta name="theme-color" content="#050505" />
<meta property="og:site_name" content="M1K3" />
<meta property="og:locale" content="en_IE" />
<meta property="og:title" content="M1K3 Brains — Models and Evals" />
<meta property="og:description" content="{_e(head_desc)}" />
<meta property="og:type" content="article" />
<meta property="og:url" content="https://m1k3.app/brains" />
<meta property="og:image" content="https://m1k3.app/og.png" />
<meta property="og:image:width" content="1200" />
<meta property="og:image:height" content="630" />
<meta property="og:image:alt" content="M1K3 for Mac — 'Your AI. Your Mac. Nothing leaves.' A wireframe fox on a dark CRT grid; private, on-device AI for macOS." />
<meta name="twitter:card" content="summary_large_image" />
<meta name="twitter:title" content="M1K3 Brains — Models and Evals" />
<meta name="twitter:description" content="{_e(head_desc)}" />
<meta name="twitter:image" content="https://m1k3.app/og.png" />
<link rel="alternate" type="application/json" href="/brains.json" />
<link rel="preload" href="fonts/vt323-latin-400-normal.woff2" as="font" type="font/woff2" crossorigin />
<link rel="stylesheet" href="fonts.css" />
<link rel="stylesheet" href="geo.css" />
</head>
<body>

<div class="scanlines"></div>
<div class="vignette"></div>

<nav>
  <a class="wordmark" href="/"><img class="mark" src="favicon.svg" alt="" width="22" height="22" />M1K3<span class="cursor">_</span></a>
  <div class="links">
    <a href="/">Home</a>
    <a href="/#features">Features</a>
    <a href="/#faq">FAQ</a>
    <a href="https://github.com/Round-Tower/M1K3">GitHub</a>
    <a class="btn btn-ghost" href="/#get" style="padding:10px 18px;">Download</a>
  </div>
</nav>

<main class="article">
  <header class="article-head">
    <span class="label">// brains</span>
    <h1>The brains, and how they score</h1>
    <p class="meta">Generated {gen} from the app's own eval harness · machine-readable copy at <a href="/brains.json">/brains.json</a> · By Round Tower, the makers of M1K3.</p>
  </header>

  <div class="answer">
    <p><strong>Short answer: M1K3 ships four brains, pinned to exact model revisions, and this page is the evidence for those picks.</strong> Every number below was measured on a real Mac through the shipping app, and each run carries the hardware, OS, power mode, app commit and inference-runtime revision it was measured with. The app never reads this page: models are chosen in a reviewed pull request, not by a server. Read it the way you would read a lab notebook, failures included.</p>
  </div>

  <h2>What ships today</h2>
  <p>Four tiers, three shown per device. Mini answers the quickest turns (Apple's model where it can run, LFM2.5 1.2B where it can't), Lil fronts the conversation, Big is reached by delegation for deep work. Each MLX model is pinned to one Hugging Face revision and every downloaded file is checked against a SHA-256 digest before it loads, so any mirror can serve the bytes.</p>
  {_brains_table(doc["brains"])}

  <h2>Eval runs</h2>
  <p>The harness runs the same fixtures against each brain through the live path (retrieval, grounding, tools, the agent loop), scores each answer with named checks, and writes this JSON. A repeat is a separate trial. Failures are listed with the scorer's own reason. The source documents for every run on this page are committed under <code>macos/docs/evals/</code>.</p>
  {"".join(runs_html)}
{_state_of_play()}
  <h2>How to read this honestly</h2>
  <ul>
    <li><strong>Small n.</strong> Two trials per fixture is enough to catch a flake, not enough for a percentage. Treat cells as evidence, not scores.</li>
    <li><strong>One machine.</strong> Everything here is one Apple M1 Max. Newer chips run every brain faster; the ordering between brains is what travels.</li>
    <li><strong>Latency includes the tools.</strong> A tool-use median counts retrieval and the tool call, not just token generation.</li>
    <li><strong>Reproduce it.</strong> The harness is in the repository: <code>macos/docs/BENCHMARKS.md</code>. This page is generated by <code>macos/tools/eval/brains_page.py</code> from its JSON.</li>
  </ul>

  <aside class="related">
    <span class="label">// related</span>
    <div class="related-links">
      <a href="/local-llm-mac-guide">Running a local LLM on a Mac</a>
      <a href="/vs-ollama">M1K3 vs Ollama</a>
      <a href="/privacy">Is M1K3 really private?</a>
      <a href="/">M1K3 home</a>
    </div>
  </aside>
</main>

<footer>
  <span>© 2026 <a href="https://round-tower.ie">ROUND TOWER</a> · MADE IN IRELAND</span>
  <span><a href="https://github.com/sponsors/Round-Tower" aria-label="Sponsor M1K3 on GitHub">SPONSOR ♥</a> · <a href="https://github.com/Round-Tower/M1K3">GITHUB</a> · NO TRACKING ON THIS PAGE, OBVIOUSLY</span>
</footer>

<!-- Generated by macos/tools/eval/brains_page.py on {gen}. Do not hand-edit: re-run the generator.
     Eval numbers are the harness's own JSON; the state-of-play block is the {_e(STATE_OF_PLAY["date"])} read-out
     (see the generator's MurphySig for provenance and confidence). -->
</body>
</html>
"""


# ---------------------------------------------------------------- cli


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--run", action="append", type=Path, default=None,
                    help="ChatEvalDocument JSON (repeatable). Default: every *.json under macos/docs/evals, sorted by name")
    ap.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parents[2] / "weights-manifest.json")
    ap.add_argument("--json", type=Path, required=True, help="where to write brains.json")
    ap.add_argument("--html", type=Path, required=True, help="where to write brains.html")
    ap.add_argument("--generated", default=_dt.date.today().isoformat(), help="date stamp (default: today)")
    a = ap.parse_args(argv)
    manifest = json.loads(a.manifest.read_text())
    run_paths = a.run or sorted((Path(__file__).resolve().parents[2] / "docs" / "evals").glob("*.json"))
    if not run_paths:
        ap.error("no run documents: pass --run or commit some under macos/docs/evals/")
    runs = [json.loads(p.read_text()) for p in run_paths]
    doc = document(manifest, runs, generated=a.generated)
    # Render both BEFORE writing either, so a render error can't leave brains.json ahead of brains.html.
    json_text, html_text = to_json(doc), render_html(doc)
    a.json.write_text(json_text)
    a.html.write_text(html_text)
    print(f"wrote {a.json} ({len(doc['runs'])} run(s), {len(doc['brains'])} brains) and {a.html}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
