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
import app.m1k3.ai.assistant.platform.PreferenceKeys
import app.m1k3.ai.assistant.platform.PreferencesStoreInterface
import app.m1k3.ai.domain.ai.CpuVariantOverride
import app.m1k3.ai.domain.ai.LlmModel
import app.m1k3.ai.domain.ai.NativeDiagnostics
import app.m1k3.ai.domain.ai.ThinkingPolicy
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

        val extras =
            listOf(
                EvalRunRequest.EXTRA_FIXTURES,
                EvalRunRequest.EXTRA_OUT,
                EvalRunRequest.EXTRA_MODEL,
                EvalRunRequest.EXTRA_THINKING,
                EvalRunRequest.EXTRA_CPU_VARIANT,
            ).associateWith { intent.getStringExtra(it) }

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
        val report =
            try {
                EvalRunner(viewModel).run(request)
            } catch (e: Exception) {
                Log.e(TAG, "eval run crashed", e)
                crashReport(request, e)
            }

        try {
            java.io.File(request.outPath).writeText(report.toJson())
            Log.i(TAG, "wrote ${report.results.size} result(s) to ${request.outPath}")
        } catch (e: Exception) {
            // The Python driver's fallback is watching for PROCESS EXIT, not
            // just the file — a missing file with the process gone still
            // reads as "this cell failed", just without detail.
            Log.e(TAG, "failed to write results to ${request.outPath}", e)
        }

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
