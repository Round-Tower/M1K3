# Power receipts, 2026-10-27: the raw evidence

Six `tools/eval/power_run.zsh` runs (Lil, Big and Mini, two each), taken by Kev on an M1 Max 64 GB,
on AC, with the 1.3.0 (541) app. For each run:

- `<brain>-run<N>.log.gz`: `powermetrics --samplers cpu_power,gpu_power -i 500`, gzipped. Power only:
  the tasks sampler was off, so no process names.
- `<brain>-run<N>-ttft.log`: `log show` of `app.m1k3` category `ttft` over the run (Mini logs none).
- `<brain>-run<N>-windows.json`: the idle window and each turn's start, end, question and answer
  length. The answers' text is left out: `m1k3 ask` answers can draw on the owner's notes.

Re-derive the receipts and rates in `docs/evals/` (run from `macos/`):

    R=docs/evals/2026-10-27-power-raw
    python3 tools/eval/power_receipt.py report --log $R/lil-run1.log.gz --turns $R/lil-run1-windows.json
    python3 tools/eval/power_receipt.py rates --log $R/lil-run1.log.gz --turns $R/lil-run1-windows.json \
      --ttft $R/lil-run1-ttft.log

The method and the figures are in `docs/ENERGY_MEASUREMENT.md`.
