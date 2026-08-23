package app.m1k3.ai.assistant.eval

/** The android model tier keys `tools/eval/android/run.py` sends via
 * `--es m1k3.eval.model`, and how they map onto [app.m1k3.ai.domain.ai.LlmModel].
 * Kept as plain strings (not the LlmModel sealed class) so this file has no
 * Android/androidMain dependency and stays commonTest-able. */
object EvalModelKey {
    const val MINI = "qwen35_0b8"
    const val LIL = "qwen35_2b"
    const val BIG = "gemma4_e2b"
}

/**
 * EvalRunRequest — a parsed, validated `adb shell am start` intent for the
 * eval harness. Pure so the extras-parsing logic (the part most likely to
 * silently drift from `run.py`'s extra names) is unit-testable without an
 * Android `Intent`.
 *
 * @param fixturesPath device-local path to the fixtures JSON (pushed by the
 *   Python driver before launch — see `tools/eval/android/run.py`).
 * @param outPath device-local path the harness writes its results JSON to.
 * @param model one of [EvalModelKey], or null = leave the currently-selected
 *   tier alone.
 * @param thinking overrides `ThinkingPolicy` for the whole run, or null =
 *   leave the per-model default.
 * @param cpuVariant a bare `libggml-cpu-android_<variant>.so` filename to
 *   try loading first (`CpuVariantOverride`), or null = native default order.
 */
data class EvalRunRequest(
    val fixturesPath: String,
    val outPath: String,
    val model: String?,
    val thinking: Boolean?,
    val cpuVariant: String?,
    /** Fixture ids to NOT run — already completed or hung on a prior launch of
     *  this cell. `run.py` accumulates results across launches and re-sends the
     *  growing skip set so a native hang (uncancellable in-process) can be
     *  stepped over instead of killing the whole cell. */
    val skip: Set<String> = emptySet(),
) {
    companion object {
        const val EXTRA_FIXTURES = "m1k3.eval.fixtures"
        const val EXTRA_OUT = "m1k3.eval.out"
        const val EXTRA_MODEL = "m1k3.eval.model"
        const val EXTRA_THINKING = "m1k3.eval.thinking"
        const val EXTRA_CPU_VARIANT = "m1k3.eval.cpu_variant"
        const val EXTRA_SKIP = "m1k3.eval.skip"

        /**
         * Builds a request from a `{extraName: value}` map (the androidMain
         * caller reads these off the real `Intent`'s string extras).
         *
         * @return null when the launch carries no eval extra VALUES — the
         *   harness must be a strict no-op on an ordinary launch. The
         *   androidMain caller populates every eval-extra KEY (from
         *   getStringExtra) with a null value on a normal launch, so this
         *   guards on a non-null value, never mere key presence. Otherwise
         *   requires both [EXTRA_FIXTURES] and [EXTRA_OUT]; missing either
         *   on an eval-intending launch (any eval extra has a value) throws
         *   rather than silently starting the app normally, so a typo'd
         *   `adb` command fails loudly instead of quietly not running.
         */
        fun fromExtras(extras: Map<String, String?>): EvalRunRequest? {
            val fixturesPath = extras[EXTRA_FIXTURES]
            val outPath = extras[EXTRA_OUT]
            val anyEvalExtra = extras.any { (k, v) -> k.startsWith("m1k3.eval.") && v != null }
            if (fixturesPath == null && outPath == null && !anyEvalExtra) return null
            requireNotNull(fixturesPath) { "$EXTRA_FIXTURES is required for an eval launch" }
            requireNotNull(outPath) { "$EXTRA_OUT is required for an eval launch" }

            val thinkingRaw = extras[EXTRA_THINKING]
            val thinking =
                when (thinkingRaw?.lowercase()) {
                    null -> null
                    "true" -> true
                    "false" -> false
                    else -> error("$EXTRA_THINKING must be true/false, got '$thinkingRaw'")
                }

            return EvalRunRequest(
                fixturesPath = fixturesPath,
                outPath = outPath,
                model = extras[EXTRA_MODEL],
                thinking = thinking,
                cpuVariant = extras[EXTRA_CPU_VARIANT],
                skip =
                    extras[EXTRA_SKIP]
                        ?.split(',')
                        ?.map { it.trim() }
                        ?.filter { it.isNotEmpty() }
                        ?.toSet()
                        ?: emptySet(),
            )
        }
    }
}
