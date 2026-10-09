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
**Owed: never run** (see `docs/GEMMA_1_1_PLAN.md`, the stall section).
