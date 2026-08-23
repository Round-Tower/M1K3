# Plan — the 3D Phosphor Fox companion (Android)

> Status: **planned, not started.** Scoped 2026-08-23 after the chat-UI redesign
> session. Kev's call: minimal real Filament, just the Fox (+ maybe a slimmed
> iOS spread later), models compressed for Android, Blender MCP in play. Do it
> as a dedicated pass — it has two landmines (below), so it's not an
> end-of-session bolt-on.

## Goal

Bring a real 3D companion — the **Phosphor Fox** — into the Android app's
avatar surfaces (empty-chat hero first, then full-screen voice mode), living
alongside the current alive 2D `PixelFaceAvatar` (which stays as the fallback
and the always-safe default).

Minimal set: the Fox only, to start. Not the 38-creature gallery, not the
picker, not the debug lab — all of which the reduction (`b3d4c461`, "one face
— the pixel face stays, 3D/WebView/gallery go") deliberately cut.

## Why not just restore SceneView

The reduction removed `io.github.sceneview:sceneview` (2.3.0). SceneView tops
out at **2.3.0** — 2024-era, built against Kotlin ~1.9 / Compose ~1.6. This
app's toolchain is now **Kotlin 2.4.10, AGP 9.3.1, Compose Multiplatform
1.11.1, compileSdk 36**. SceneView won't resolve/compile cleanly against that,
and there is no newer release tracking it (verified against Maven Central
2026-08-23: latest is 2.3.0).

**Approach instead: Filament core directly.** `com.google.android.filament`
+ `com.google.android.filament:gltfio-android` are actively maintained,
version-independent of Compose/Kotlin metadata, and are what SceneView wrapped
anyway. Render into a `SurfaceView`/`TextureView` hosted in an `AndroidView`,
drive the animator off a `Choreographer` frame callback. ~1 render class +
a small engine/loader holder, not the old 765-line `Avatar3DView`.

## Assets (already in the repo)

- **`site/vendor/Fox.glb`** — 163 KB, glTF-binary, Filament-ready. The classic
  Khronos Fox with Walk/Survey/Run animation clips. Copy into
  `composeApp/src/androidMain/assets/companions/fox.glb`.
- **`macos/tools/companion-pipeline/build_phosphor_fox.py`** — the styling
  pipeline (phosphor look). Reference for the orange-phosphor material if we
  want the Fox tinted to match M1K3.
- **`macos/Sources/M1K3Avatar/Companions/Fox/{Walk,Survey,Run}.usdz`** — the
  iOS animation set (Apple USDZ). Not directly usable on Android; the .glb is
  the Android source of truth. If we ever want the slimmed iOS spread on
  Android (Sparrow/Gecko too), convert USDZ→glTF via the Blender MCP.

## Crash-safety — reuse the hard-won lessons (do NOT rediscover)

From the deleted `SharedModelCache.kt` (recover: `git show
b3d4c461^:app/composeApp/src/androidMain/kotlin/app/m1k3/ai/assistant/avatar/SharedModelCache.kt`):

- **One shared `ModelLoader` per `Engine`, one `Model` per glb path, N cheap
  `ModelInstance`s.** Two independent `ModelLoader`s on the same `Engine`
  null-deref `libgltfio-jni.so` at 0x2a8 during concurrent tear-down (hero +
  toolbar race). Share the loader.
- **Destroy order: `ModelLoader.destroy()` → `Engine.destroy()`** — the loader
  holds engine-owned handles. Wire teardown into the Activity/last-surface
  dispose.
- The stale SceneView comment "Animation is not supported in new instances" is
  **wrong** — per-`FilamentInstance` animators work fine.

## Landmine — OOM when Filament co-inits with the LLM

Documented (app/.claude/project-memory.md, 2026-04): Filament + Qwen
co-initialising hit **7.08 GB RSS** on an 8 GB device and Android's LMK killed
the foreground app. The dot-matrix-hero workaround existed precisely to avoid
the 3D path during model load.

Guards for the Fox:
- **Do not instantiate Filament during LLM init.** Gate the 3D surface behind
  a memory-headroom check (`ActivityManager.MemoryInfo` / `availMem`), and only
  after the brain is resident.
- **Keep the 2D `PixelFaceAvatar` as the default + fallback.** 3D is an
  enhancement that degrades to 2D on low headroom, load failure, or older GPUs.
- Test on the Pixel 9a (8 GB, Tensor G4) with **Big (Gemma 4 E2B, ~6 GB)**
  resident — the worst case — and watch `dumpsys meminfo app.m1k3`.

## Build order (each step verified on-device before the next)

1. Add `com.google.android.filament` + `gltfio-android` + `filament-utils` to
   the catalog. Prove they **resolve + compile** against Kotlin 2.4.10 / CMP
   1.11.1 (this is the gate — if the deps are clean, the rest is mechanical).
2. Copy `fox.glb` into `androidMain/assets/companions/`. `Companion3DView`
   (AndroidView + SurfaceView + Filament Engine/loader) renders the Fox, plays
   the idle/survey clip, transparent background over the charcoal.
3. Reuse the `SharedModelCache` pattern for loader/instance lifecycle + a
   MainActivity-dispose teardown in the right order.
4. Wire into the **hero** first (empty chat), behind the memory-headroom gate,
   2D fallback on any failure. Verify no OOM with Big resident.
5. Then **voice mode** — the Fox reacts to `AvatarActivity`
   (listening/thinking/speaking) like the 2D face does today.
6. Blender MCP: compress/optimize the glb (draco/meshopt), and if we want the
   slimmed iOS spread, batch-convert the USDZ companions → glTF.

## Not in scope (deliberately)

The 38-creature gallery, the model picker, the debug lab, the THREE.js WebView
avatar — all cut in `b3d4c461` and staying cut. One companion, done well.
