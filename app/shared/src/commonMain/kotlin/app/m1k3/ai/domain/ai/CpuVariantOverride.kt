package app.m1k3.ai.domain.ai

/**
 * CpuVariantOverride — the eval harness's seam for forcing which
 * `libggml-cpu-android_<variant>.so` runtime-dispatch module `ma_core` tries
 * FIRST (see `ma_core.cpp`'s `load_cpu_backends_once`).
 *
 * Production never sets this: [MaInferenceBackend.init]'s own
 * `preferredCpuVariant` default ("") leaves the native side's built-in
 * most-capable-first order (`kAndroidCpuBackendVariants`) untouched. It
 * exists so `tools/eval/android` can reproduce a specific variant on demand
 * — the Pixel 9a day found android_armv9.0_1 (SVE2) producing broken logits
 * for Qwen3.5-0.8B while android_armv8.6_1 was fine on the same device; that
 * bug needs to be a fixture cell, not a one-off log read.
 *
 * Set before [LlamaCppEngine.initialize] runs — it's read once, at model
 * load, matching [ThinkingPolicy.override]'s contract.
 */
object CpuVariantOverride {
    /** Bare `.so` filename to try first, e.g. "libggml-cpu-android_armv9.0_1.so". */
    var preferred: String? = null
}
