# tools/perf

## display_off_ab.sh — is App Nap the display-off stall?

Decides the Open in `GenerationActivity.swift`. Two arms of the same long CHATEVAL generation
with the display forced off 30 s in: **A** hold on (shipping), **B** hold off
(`M1K3 -generationActivity NO`, a test-only launch argument). Prints a two-column verdict of
decode tok/s before/after display-off from the unified log, plus `pmset -g assertions`
snapshots.

    macos/tools/perf/display_off_ab.sh --dry-run          # the plan, runs nothing
    macos/tools/perf/display_off_ab.sh --app <Debug M1K3.app> --yes-away

Refuses unless: no live M1K3 is running, `:4242` is free, power is AC. Needs cached weights
(never `hf download` for it) and Kev's hands off the keyboard (input wakes the display).
Ran 2026-10-10 (#533); see `docs/GEMMA_1_1_PLAN.md`, the stall section, for why it was owed.

## energy_counter_probe.sh — what the app's own energy counter can see

The #696 Phase 1 probe. One small Swift program opens three 2 s windows (idle, a one-core CPU burn,
a Metal compute burn) and prints how far each moved this process's `RUSAGE_INFO_V6` `ri_energy_nj`.
It runs twice: as a plain process, then ad-hoc signed into an App Sandbox, after checking the
sandbox is on. No root, app or model; about 20 s.

    macos/tools/perf/energy_counter_probe.sh

2026-10-26, M1 Max: the counter moves without root and inside the sandbox, and the GPU window
does not move it, so it sees the CPU only. Quoted in `docs/ENERGY_MEASUREMENT.md`.
