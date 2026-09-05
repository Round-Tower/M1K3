# 0004. The brain catalogue ships in the binary; the site publishes evals the app never reads

Date: 2026-09-05
Status: ACCEPTED
Deciders: Kev + claude-fable-5.1 (challenger pass on the proposal, verified against source)

## Context

Models move faster than app releases. The 2026-09-05 landscape review proposed a
**remotely-configured brain catalogue**: a signed JSON on m1k3.app listing brains
per device class with eval scores and Hugging Face ids, fetched by the app, so a
new brain could be offered and hot-swapped without an app update. The draft
carried the right instincts (Ed25519 signature, full `weights-manifest.json`
pins per entry, consent-gated fetch, recommend-only) and was still wrong, for
reasons that only show up with the source open:

1. **It is a remote kill switch.** `WeightIntegrityScan.enforce` throws
   `WeightsStaleError` whenever the cached revision differs from the pin
   (`WeightIntegrityScan.swift`, the stale-not-tampered branch). Today a re-pin
   reaches users only inside a reviewed binary. A catalogue turns "publish a new
   revision for an installed brain" into every installed copy refusing to load
   on next launch and demanding a multi-gigabyte re-download, with nothing an
   offline user can do. No release note, no CI, no staged rollout, one typo.
2. **The expiry fallback is a downgrade attack.** "Bad or expired catalogue →
   ignore it, compiled pins win" means an id that was installed *from* the
   catalogue is no longer pinned at all once the catalogue is withheld
   (attacker, host outage, three months offline). `WeightIntegrity.Verdict
   .unpinned` is the permissive path by design. Withholding a signature is
   easier than forging one, and here it is rewarded.
3. **A periodic unauthenticated GET from every install is fleet telemetry.**
   The host logs IP, user agent and timestamp. "Zero device identifiers" is a
   client-side claim; the server still learns install counts and per-user
   cadence. For a product whose promise is "nothing leaves the device", that is
   the launch-day comment thread, not an architecture footnote.
4. **No revocation path.** A compiled-in public key means a key compromise is
   fixed by an app update, the exact dependency the catalogue exists to remove.

Meanwhile the problem the catalogue solves is one this pipeline does not have:
Xcode Cloud builds 283, 284 and 285 all went VALID inside one evening. Pins in
the binary already move at the speed of a merge.

## Decision

- **Model pins ship in the binary** (ADR 0002 stands unchanged). Promoting or
  adding a brain is a reviewed PR that re-pins `weights-manifest.json` and runs
  the gemma-4 native tool-call smoke in CI.
- **The site publishes evaluations as documentation the app never reads.**
  `brains.json` and a human page (`site/brains.html`, via
  `tools/eval/brains_page.py`) are generated from the on-device harness's
  output (dated runs, hardware, power mode, app commit, mlx-swift-lm revision,
  n). Readers decide with it; the app does not fetch it.
- **The catalogue's invariants are banked here, not built.** If a real trigger
  arrives (a shipped brain a whole device class cannot run, and TestFlight
  cannot fix it fast enough), any catalogue must be: recommend-only forever (it
  may add ids and ladder rows, never change the revision of an installed brain);
  fail-closed on absence (an id installed under a catalogue pin is never loaded
  unpinned); fetched only on an explicit user action, never on a timer; and
  disarmed by a compiled flag so a bad key needs no schema migration to escape.
- **Signing, if wanted, applies to the repo's own manifest**: sign
  `weights-manifest.json` at tag time and verify the generated `PinnedWeights`
  matches. Same crypto, no egress, no revocation problem.

## Consequences

- New brains keep costing an app release. That is the price of the privacy
  promise and of never being able to brick an installed brain from a server.
- The eval harness becomes the load-bearing artifact: its output is what the
  site publishes and what a promotion PR cites. Its correctness bugs (the
  per-tier override, model-id labels) are fixed in #212; provenance headers,
  Codable output and repeats follow.
- Family sniffs (`resolveToolCallFormat`, `usesVLMLoadPath`, quantized-KV
  allow-lists) stay in code where a wrong value is caught by CI, not delivered
  remotely where it is caught by users.
