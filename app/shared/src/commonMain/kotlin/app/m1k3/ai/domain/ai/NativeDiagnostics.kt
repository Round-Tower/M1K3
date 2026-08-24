package app.m1k3.ai.domain.ai

/**
 * NativeDiagnostics — process-lifetime facts `ma_core` reports back about
 * itself that don't belong on [MaInferenceBackend.init]'s return value
 * (which is per-context) because they're about the backend registry, which
 * `ma_core.cpp`'s `load_cpu_backends_once` loads exactly ONCE per process.
 *
 * [lastLoadedCpuVariant] is set by [LlamaCppEngine] right after a successful
 * [MaInferenceBackend.init], from [MaInferenceBackend.lastLoadedCpuVariant].
 * `tools/eval/android`'s runner reads it once per fixture and records it in
 * the result JSON — the CPU-variant column the SVE2-broken-logits bug needs
 * to be provable from, not just logcat.
 */
object NativeDiagnostics {
    /** Bare `.so` filename of the CPU backend variant that registered, or
     * null before any model has initialized / on a non-Android build. */
    var lastLoadedCpuVariant: String? = null
}
