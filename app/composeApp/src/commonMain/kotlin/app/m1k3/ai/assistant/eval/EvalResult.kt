package app.m1k3.ai.assistant.eval

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** One fixture's outcome — everything `tools/eval/android/scorecard.py` and
 * a human reading the raw JSON need to understand what happened, without
 * re-running the device. */
@Serializable
data class EvalResult(
    val fixtureId: String,
    val kind: String,
    val passed: Boolean,
    val failedChecks: List<String> = emptyList(),
    val answer: String,
    val thinking: String? = null,
    val toolsCalled: List<String> = emptyList(),
    val chars: Int,
    val tokens: Int,
    val generateMs: Long,
    val firstTokenMs: Long? = null,
    /** Non-null when the turn errored (GenerationState.Failed) instead of scoring normally. */
    val error: String? = null,
)

/** The matrix cell this run covers — one process launch = one cell (see
 * `run.py`'s per-cell relaunch, which also gives `ma_core`'s once-per-process
 * CPU-backend load a clean slate for [cpuVariantLoaded] to mean anything). */
@Serializable
data class EvalRunMeta(
    val model: String,
    val thinkingRequested: Boolean?,
    val thinkingEffective: Boolean,
    val cpuVariantRequested: String?,
    val cpuVariantLoaded: String?,
    val timestampMs: Long,
)

@Serializable
data class EvalRunReport(
    val run: EvalRunMeta,
    val results: List<EvalResult>,
)

private val evalReportJson =
    Json {
        prettyPrint = true
        encodeDefaults = true
    }

fun EvalRunReport.toJson(): String = evalReportJson.encodeToString(EvalRunReport.serializer(), this)

fun parseEvalRunReport(json: String): EvalRunReport = evalReportJson.decodeFromString(EvalRunReport.serializer(), json)
