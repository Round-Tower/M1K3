# Companion pipeline — GLB → USDZ-per-clip → RealityKit

Turns a rigged, animated GLB into the per-clip USDZ assets M1K3's 3D companions
load. Productionised out of `scratch/usdz-probe/` (which proved it on 9 models /
67 clips). The `/add-companion` skill drives this end-to-end; this README is the
ground truth it leans on.

## The one-paragraph why

macOS's system OpenUSD glTF reader keeps only the **first** animation clip, and
clip **names die** in the USD round-trip. So we export **one USDZ per clip** and
treat the **filename as the clip identity**. At runtime M1K3 loads one mesh +
N clip files and **cross-binds** each animation onto a single rig
(`CompanionAvatarView` / `scratch/usdz-probe`). One mesh + N clip files is the
architecture.

## Convert

```bash
/Applications/Blender.app/Contents/MacOS/Blender -b -P export_clips.py -- \
  "<model.glb>" "<outdir>" <Clip1,Clip2,...>
```

- **Blender 4.4+ is the converter** — the system `usdcat` is NOT a substitute
  (it keeps only clip 1). The script handles Blender 4.4 slotted actions.
- Omit the clip list to export every action in the file.
- Exit code is non-zero only if *nothing* exported; a partial run (some named
  clips absent) still writes what it found and succeeds.

### Clip dialects

M1K3 maps an `AvatarState` to a gait, then a dialect maps the gait to a clip
name (`ClipMapper` / `CompanionDialect`). Export at least the clips the dialect
names:

| Dialect      | Clips to export                                      | Source                                   |
|--------------|------------------------------------------------------|------------------------------------------|
| `quaternius` | `Idle_A,Idle_B,Walk,Run,Jump,Fear,Sit,Clicked`       | `app/3d/Quirky-Series-FREE-Animals.../Animations/<Name>_Animations.glb` |
| `fox`        | `Survey,Walk,Run`                                    | Khronos Fox (`site/vendor/Fox.glb`); also PhosphorFox — same rig/clips, wireframe lattice baked in by `build_phosphor_fox.py` |
| `aquatic`    | quaternius set + `Swim,Fly` (move→Swim, react→Fly)   | Quirky pack swimmers (Inkfish)           |
| `avian`      | quaternius set + `Swim,Fly` (move→Fly, react→Jump)   | Quirky pack birds (Sparrow)              |

Extra clips are harmless (just bytes — M1K3 only *plays* the gait-mapped subset).
`Sit`/`Clicked` are exported for forward-looking gaits but not yet played.

## Verify

- **Quick Look** each `.usdz` (Finder → space) — confirms mesh, materials,
  and that the animation plays. Needs a GUI session.
- **Headless RealityKit playback — the REQUIRED gate:** `rkprobe --tick
  <files...>` plays each file's own animation in a headless `RealityRenderer`
  and reports `MOVES` or `FROZEN` from actual joint deltas. This is ground
  truth: animation *presence*, durations, AND `controller.isValid` all passed
  on files that render frozen (the `Rig`-name trap below). Every clip must
  say `MOVES` before wiring in.
- **Headless RealityKit load + inventory:** `scratch/usdz-probe/out/rkprobe`
  (`swift run -c release rkprobe <files...>`) — lists animations + durations.
  **Read the durations:** every clip identical at ~0.42 s is the
  compressed-take trap (below).
- **Headless image preview:** `./preview_usdz.swift <files...> [-o outdir]
  [--size N] [--time T]` — renders each clip to a PNG (mesh + materials) with
  no screen needed. CAVEAT: SceneKit's offscreen snapshot does not evaluate
  skinned animation, so `--time` shows the bind pose for rigged models —
  look, not motion (use `rkprobe --tick` for motion). Works from a terminal,
  SSH, CI, or a locked Mac. The checks are complementary — preview shows the
  look, `--tick` proves the motion, Quick Look shows the motion to a human.

## Wire into the app

1. Copy the `.usdz` files to `macos/Sources/M1K3Avatar/Companions/<Name>/`.
   They're **package resources** (`Package.swift` `resources: [.copy("Companions")]`)
   — Xcode re-resolves on its own, **no xcodegen** needed.
2. Add a `CompanionSpec.<name>` (id = the folder name) and append it to
   `CompanionSpec.all`. The Settings picker auto-detects it via
   `CompanionAssets.isInstalled` — no picker wiring.
3. `swift test --filter CompanionTests` — `everyEmittedClipIsBundled` fails loudly
   if the spec's clips don't cover every gait the dialect can emit.

## Gotchas (hard-won — do not rediscover)

- **RealityKit will NOT bind skeletal animation to a SkelRoot prim named
  exactly `Rig`** — the mesh loads, `availableAnimations` is populated,
  `playAnimation` returns a valid controller, and the joints never move.
  Case-sensitive: `rig`, `TheRig`, `Armature`, `root` all animate; only `Rig`
  freezes (controlled A/B 2026-07-11, USD byte-identical modulo the name).
  The Quirky Series pack names every armature object `Rig`, so every Quirky
  companion hit this — including the 2026-06-21 Gecko drop, whose real cause
  was this, not the conversion. `export_clips.py` now auto-renames `Rig` →
  `Armature` before export. If a future source model ships frozen despite
  `--tick` passing at export time, suspect another reserved name.
- **The Quirky pack's takes are compressed — export with `--retime 4`.** Every
  clip in the Quirky Series FREE pack is an 11-frame / 0.417 s take with the
  full motion cycle squeezed inside (GLB, FBX, and the Unity meta all agree;
  both pack downloads identical). Played as-is it reads as broken on-device —
  this was the REAL cause of the 2026-06-21 "Gecko doesn't animate" drop,
  root-caused 2026-07-10. `--retime 4` stretches takes to ~1.67 s (tune by
  eye at ⌘⇧V). Khronos Fox has real per-clip durations — no retime.
- **Z-up → Y-up:** models import Z-up (Blender) and load standing on their nose
  in RealityKit. The correction is **in the view**
  (`CompanionAvatarView.blenderZUpCorrection`, −90° about X), not baked into the
  asset — uniform across companions because they share this export. A Y-up source
  (some Sketchfab exports) would need that constant per-spec.
- **Filename = clip identity.** Clip names become generic in USD; never rely on
  the in-USD animation name.
- **Size:** ~1.3 MB per Quaternius model (8 clips, mesh+texture duplicated per
  file); Fox ~390 KB. If it ever matters: USD composition (one mesh layer +
  per-clip animation layers + `usdzip`) is the optimisation, not yet needed.
- **New app-target *files*** (e.g. splitting `CompanionAvatarView.swift` out of
  `AvatarView.swift`) DO need `xcodegen` — and Xcode must be quit first (it
  desyncs an open project). Adding *assets* to the package does not.

Signed: Kev + claude-opus-4-8, 2026-06-12, Confidence 0.85 (converter re-proven
end-to-end on Gecko during productionisation; wire-in steps match the shipped Fox).
Prior: Kev + claude-fable-5 (scratch/usdz-probe/README.md).
