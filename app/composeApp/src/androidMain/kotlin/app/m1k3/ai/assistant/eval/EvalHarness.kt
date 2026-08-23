package app.m1k3.ai.assistant.eval

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.util.Log
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.lifecycleScope
import app.m1k3.ai.assistant.MainActivity
import app.m1k3.ai.assistant.chat.ChatScreenViewModel
import app.m1k3.ai.assistant.embedding.EmbeddingEngine
import app.m1k3.ai.assistant.platform.PreferenceKeys
import app.m1k3.ai.assistant.platform.PreferencesStoreInterface
import app.m1k3.ai.domain.ai.CpuVariantOverride
import app.m1k3.ai.domain.ai.LlmModel
import app.m1k3.ai.domain.ai.NativeDiagnostics
import app.m1k3.ai.domain.ai.ThinkingPolicy
import app.m1k3.ai.domain.embedding.EmbeddingTaskType
import kotlinx.coroutines.launch
import org.koin.android.ext.android.getKoin
import org.koin.androidx.viewmodel.ext.android.getViewModel
import org.koin.core.parameter.parametersOf
import kotlin.time.Clock

/**
 * EvalHarness — the `tools/eval/android` launch contract's Activity-side glue.
 *
 * ```
 * adb shell am start -n app.m1k3/.ai.assistant.MainActivity \
 *   --es m1k3.eval.fixtures <device-path> --es m1k3.eval.out <device-path> \
 *   [--es m1k3.eval.model qwen35_0b8|qwen35_2b|gemma4_e2b] \
 *   [--ez m1k3.eval.thinking true|false] \
 *   [--es m1k3.eval.cpu_variant libggml-cpu-android_<variant>.so]
 * ```
 *
 * An ordinary launch (no `m1k3.eval.*` extras) is a strict no-op —
 * [installFromIntent] returns false and [MainActivity] composes the normal
 * app exactly as before.
 *
 * ⚠️ Gated on [ApplicationInfo.FLAG_DEBUGGABLE], NOT this repo's
 * `app.m1k3.ai.assistant.utils.BuildConfig.DEBUG` — that's a same-named
 * placeholder object hardcoded `= true` (no `generate*BuildConfig` Gradle
 * task exists in this module, so there is no real per-build-type
 * BuildConfig). Gating on it here would have made the eval harness live in
 * every build, debug or release. FLAG_DEBUGGABLE reflects the actual AGP
 * `debuggable` build-type flag and can't silently ship active.
 *
 * Deliberately skips the normal `setContent { MaApp() }` when an eval run is
 * detected: driving a SECOND [ChatScreenViewModel] (this harness's own, under
 * a dedicated `EVAL_PROJECT_ID`) while the normal "default" one also boots
 * would load two models into memory at once. See
 * [EvalRunner] for why this is a real [ChatScreenViewModel] built through
 * Koin's own `viewModel { }` registration (`PlatformModule.android.kt`) —
 * same engine, tools, and prompt builder singletons production uses — rather
 * than a bare `engine.generate()` call.
 */
object EvalHarness {
    private const val TAG = "M1K3Eval"

    /** Never "default" — an eval run must not be able to touch a real user's chat history. */
    const val EVAL_PROJECT_ID = "eval"

    private fun isDebuggable(activity: MainActivity): Boolean = (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /**
     * @return true when this launch is an eval run. The caller MUST skip its
     * normal content in that case — see the class KDoc.
     */
    fun installFromIntent(
        activity: MainActivity,
        intent: Intent,
    ): Boolean {
        if (!isDebuggable(activity)) return false

        // Embed self-probe — a parallel path to the fixture eval, deliberately
        // NOT routed through EvalRunRequest (no fixtures/model contract to
        // satisfy): loads the embedder and checks a query embeds closer to a
        // matching document than an unrelated one. Verifies the whole native
        // embedding chain (JNI → pooling → decode → cosine) on device.
        if (maybeRunEmbedProbe(activity, intent)) return true

        // EXTRA_THINKING is sent as a boolean (`--ez`, not `--es` — run.py's
        // choice, matching Android's own am-start convention for flags), so
        // it can't be read via getStringExtra like the others: a String and
        // a Boolean are different typed slots in the Intent's Bundle, and
        // getStringExtra silently returns null for a boolean-typed extra
        // rather than throwing. Read it separately via hasExtra +
        // getBooleanExtra and restring it so EvalRunRequest.fromExtras keeps
        // one uniform String? contract.
        val extras =
            listOf(
                EvalRunRequest.EXTRA_FIXTURES,
                EvalRunRequest.EXTRA_OUT,
                EvalRunRequest.EXTRA_MODEL,
                EvalRunRequest.EXTRA_CPU_VARIANT,
            ).associateWith { intent.getStringExtra(it) } +
                mapOf(
                    EvalRunRequest.EXTRA_THINKING to
                        if (intent.hasExtra(EvalRunRequest.EXTRA_THINKING)) {
                            intent.getBooleanExtra(EvalRunRequest.EXTRA_THINKING, false).toString()
                        } else {
                            null
                        },
                )

        val request = EvalRunRequest.fromExtras(extras) ?: return false

        Log.i(TAG, "eval launch: $request")
        applyOverrides(activity, request)

        activity.setContent { EvalRunningPlaceholder() }

        val viewModel: ChatScreenViewModel = activity.getViewModel { parametersOf(EVAL_PROJECT_ID) }

        activity.lifecycleScope.launch {
            runAndWriteResults(activity, viewModel, request)
        }

        return true
    }

    /** Extra: `--ez m1k3.eval.embed_probe true` runs the embedding sanity probe. */
    private const val EXTRA_EMBED_PROBE = "m1k3.eval.embed_probe"

    /**
     * Loads the embedder and proves retrieval geometry on device: a query must
     * embed closer to a matching document than to an unrelated one (asymmetric
     * QUERY vs RETRIEVAL prompts, as EmbeddingGemma expects). Writes a one-line
     * JSON to `m1k3.eval.out` (if given) and logs it. Returns true iff it ran.
     */
    private fun maybeRunEmbedProbe(
        activity: MainActivity,
        intent: Intent,
    ): Boolean {
        if (!intent.getBooleanExtra(EXTRA_EMBED_PROBE, false)) return false
        val outPath = intent.getStringExtra(EvalRunRequest.EXTRA_OUT)

        activity.setContent { EvalRunningPlaceholder() }
        activity.lifecycleScope.launch {
            val result =
                try {
                    val engine = activity.getKoin().get<EmbeddingEngine>()
                    Log.i(TAG, "embed-probe: loading ${engine.modelName}…")
                    engine.loadModel().getOrThrow()

                    val query = engine.embed("where does the user live", EmbeddingTaskType.QUERY).getOrThrow()
                    val match =
                        engine
                            .embed(
                                "Kev lives in Ardmore, County Waterford, on the south coast of Ireland.",
                                EmbeddingTaskType.RETRIEVAL,
                            ).getOrThrow()
                    val unrelated =
                        engine
                            .embed(
                                "The mitochondria is the powerhouse of the cell.",
                                EmbeddingTaskType.RETRIEVAL,
                            ).getOrThrow()

                    val cosMatch = engine.cosineSimilarity(query, match)
                    val cosUnrelated = engine.cosineSimilarity(query, unrelated)
                    val pass = cosMatch > cosUnrelated
                    """{"probe":"embed","model":"${engine.modelName}","dim":${query.size},""" +
                        """"cos_match":$cosMatch,"cos_unrelated":$cosUnrelated,"pass":$pass}"""
                } catch (e: Exception) {
                    Log.e(TAG, "embed-probe failed", e)
                    """{"probe":"embed","error":"${e.message?.replace("\"", "'")?.take(300)}"}"""
                }

            Log.i(TAG, "embed-probe result: $result")
            outPath?.let {
                try {
                    java.io.File(it).writeText(result)
                } catch (e: Exception) {
                    Log.e(TAG, "embed-probe: failed to write $it", e)
                }
            }
            activity.finish()
        }
        return true
    }

    private fun applyOverrides(
        activity: MainActivity,
        request: EvalRunRequest,
    ) {
        request.model?.let { modelKey ->
            val tier =
                when (modelKey) {
                    EvalModelKey.MINI -> {
                        "mini"
                    }

                    EvalModelKey.LIL -> {
                        "lil"
                    }

                    EvalModelKey.BIG -> {
                        "big"
                    }

                    else -> {
                        error(
                            "unknown ${EvalRunRequest.EXTRA_MODEL} '$modelKey' — " +
                                "expected one of ${EvalModelKey.MINI}/${EvalModelKey.LIL}/${EvalModelKey.BIG}",
                        )
                    }
                }
            // Read fresh at ChatScreenViewModel construction time
            // (PlatformModule.android.kt's resolveSelectedModel) — must be set
            // BEFORE getViewModel below, which is why this runs first.
            activity.getKoin().get<PreferencesStoreInterface>().setString(PreferenceKeys.SELECTED_M1K3_TIER, tier)
        }
        request.thinking?.let { ThinkingPolicy.override = it }
        request.cpuVariant?.let { CpuVariantOverride.preferred = it }
    }

    private suspend fun runAndWriteResults(
        activity: MainActivity,
        viewModel: ChatScreenViewModel,
        request: EvalRunRequest,
    ) {
        // Write after EVERY fixture (atomic rename) so a process the driver kills
        // for a native hang still leaves its completed results + the in-flight
        // fixture id behind. tools/eval/android/run.py resumes past it.
        val out = java.io.File(request.outPath)
        val tmp = java.io.File(request.outPath + ".tmp")

        fun write(report: EvalRunReport) {
            try {
                tmp.writeText(report.toJson())
                tmp.renameTo(out)
            } catch (e: Exception) {
                Log.e(TAG, "failed to write results to ${request.outPath}", e)
            }
        }

        val report =
            try {
                EvalRunner(viewModel).run(request, onReport = ::write)
            } catch (e: Exception) {
                Log.e(TAG, "eval run crashed", e)
                crashReport(request, e)
            }

        write(report)
        Log.i(TAG, "wrote ${report.results.size} result(s) to ${request.outPath}")
        activity.finish()
    }

    private fun crashReport(
        request: EvalRunRequest,
        error: Exception,
    ) = EvalRunReport(
        run =
            EvalRunMeta(
                model = request.model ?: LlmModel.default.id,
                thinkingRequested = request.thinking,
                thinkingEffective = ThinkingPolicy.enabled(LlmModel.default),
                cpuVariantRequested = request.cpuVariant,
                cpuVariantLoaded = NativeDiagnostics.lastLoadedCpuVariant,
                timestampMs = Clock.System.now().toEpochMilliseconds(),
            ),
        results =
            listOf(
                EvalResult(
                    fixtureId = "(run crashed before any fixture completed)",
                    kind = "crash",
                    passed = false,
                    answer = "",
                    chars = 0,
                    tokens = 0,
                    generateMs = 0,
                    error = error.stackTraceToString().take(4000),
                ),
            ),
    )
}

@Composable
private fun EvalRunningPlaceholder() {
    MaterialTheme {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("M1K3 eval running…")
        }
    }
}
