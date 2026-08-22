package app.m1k3.ai.assistant.eval

import android.util.Log
import app.m1k3.ai.assistant.chat.ChatScreenViewModel
import app.m1k3.ai.assistant.chat.EngineState
import app.m1k3.ai.assistant.chat.GenerationState
import app.m1k3.ai.domain.ai.NativeDiagnostics
import app.m1k3.ai.domain.ai.ThinkingPolicy
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Clock

private const val TAG = "M1K3Eval"

/**
 * EvalRunner — drives [ChatScreenViewModel] one fixture at a time, exactly
 * the way a person tapping the real chat screen would: `updateInputText` +
 * `sendMessage`, wait for the real turn to finish, read the real
 * [app.m1k3.ai.assistant.chat.ChatMessage] the real
 * [app.m1k3.ai.assistant.chat.usecase.ChatWithToolsUseCase] produced. This is
 * the fix for the Mac benchmark's own documented mistake — measuring a bare
 * `provider.generate` call instead of the production turn shape and
 * publishing numbers that meant something different than they claimed to.
 *
 * `EvalHarness` (Intent/Activity glue — not unit-testable without
 * Robolectric-driving a full DI graph) constructs [viewModel] via Koin's own
 * `viewModel { params -> ... }` registration
 * (`PlatformModule.android.kt`) so every dependency — engine, tools, prompt
 * builder — is the exact production singleton. This class only orchestrates.
 *
 * Verify-by-launch, same stance as the project's own SelfTest harnesses on
 * the Mac side: the thing under test IS the real async engine/tool/DB stack,
 * which a fake would have to reinvent to be worth anything.
 */
class EvalRunner(
    private val viewModel: ChatScreenViewModel,
) {
    suspend fun run(
        request: EvalRunRequest,
        onReport: (EvalRunReport) -> Unit = {},
    ): EvalRunReport {
        val fixtures = parseFixtures(readFile(request.fixturesPath))
        Log.i(TAG, "loaded ${fixtures.size} fixtures from ${request.fixturesPath}")

        if (!waitForEngineReady()) {
            val engineState = viewModel.uiState.value.engineState
            Log.e(TAG, "engine never reached Ready — state=$engineState")
            return EvalRunReport(
                run = buildMeta(request),
                results =
                    fixtures.map { fixture ->
                        errorResult(fixture, "engine never reached Ready (state=$engineState)", generateMs = 0)
                    },
            )
        }

        val meta = buildMeta(request)
        val toRun = fixtures.filter { it.id !in request.skip }
        val results = mutableListOf<EvalResult>()
        for ((index, fixture) in toRun.withIndex()) {
            Log.i(TAG, "[$index/${toRun.size}] ${fixture.id}")
            // Mark this fixture in-flight BEFORE running it. If it hangs
            // natively (uncancellable), the driver sees inProgress stuck here
            // while results doesn't grow, and steps over it.
            onReport(EvalRunReport(run = meta, results = results.toList(), inProgress = fixture.id))
            waitForClear()
            results += runFixture(fixture)
            // Persist after every fixture so a killed process keeps its work.
            onReport(EvalRunReport(run = meta, results = results.toList(), inProgress = null))
        }
        return EvalRunReport(run = meta, results = results, inProgress = null)
    }

    private fun buildMeta(request: EvalRunRequest): EvalRunMeta {
        val model = viewModel.uiState.value.currentModel
        return EvalRunMeta(
            model = model.id,
            thinkingRequested = request.thinking,
            thinkingEffective = ThinkingPolicy.enabled(model),
            cpuVariantRequested = request.cpuVariant,
            cpuVariantLoaded = NativeDiagnostics.lastLoadedCpuVariant,
            timestampMs = Clock.System.now().toEpochMilliseconds(),
        )
    }

    private suspend fun waitForEngineReady(): Boolean {
        viewModel.initializeEngine()
        // Gemma 4's first-run cold fetch can re-pull a torn-cache shard for
        // several minutes (project memory: "~6 min" on this exact device
        // class) — this is NOT a stuck run, it's the model loading.
        val terminal =
            withTimeoutOrNull(ENGINE_INIT_TIMEOUT_MS) {
                viewModel.uiState.first { it.engineState !is EngineState.Loading }
            }
        return terminal?.engineState is EngineState.Ready
    }

    private suspend fun waitForClear() {
        viewModel.clearConversation()
        withTimeoutOrNull(CLEAR_TIMEOUT_MS) {
            viewModel.uiState.first { it.messages.isEmpty() }
        }
    }

    private suspend fun runFixture(fixture: EvalFixture): EvalResult {
        val turnStart = Clock.System.now().toEpochMilliseconds()
        var firstTokenMs: Long? = null

        viewModel.updateInputText(fixture.prompt)
        viewModel.sendMessage()

        // See waitForTurnCompletion's KDoc: sendMessage() dispatches on
        // viewModelScope rather than updating generationState synchronously,
        // so a naive "wait for Complete/Failed" can match the PREVIOUS
        // fixture's still-terminal state before this turn has even started.
        val gen =
            waitForTurnCompletion(
                states = viewModel.uiState.map { it.generationState },
                turnStartTimeoutMs = TURN_START_TIMEOUT_MS,
                fixtureTimeoutMs = FIXTURE_TIMEOUT_MS,
                onStreaming = {
                    if (firstTokenMs == null) firstTokenMs = Clock.System.now().toEpochMilliseconds() - turnStart
                },
            )

        if (gen == null) {
            val elapsed = Clock.System.now().toEpochMilliseconds() - turnStart
            val state = viewModel.uiState.value.generationState
            Log.w(TAG, "${fixture.id}: never reached a terminal state (last seen: $state)")
            return errorResult(
                fixture,
                "never reached a terminal state (last seen: $state)",
                generateMs = elapsed,
                firstTokenMs = firstTokenMs,
            )
        }

        // The terminal state we just observed is reflected in the CURRENT
        // uiState — nothing further mutates it once generation is terminal.
        val terminal = viewModel.uiState.value

        return when (gen) {
            is GenerationState.Complete -> {
                val message = terminal.messages.lastOrNull()
                val answer = message?.text ?: gen.finalText
                val toolsCalled = message?.toolResults?.map { it.toolId } ?: emptyList()
                val verdict = EvalScorer.score(fixture, EvalTurnOutcome(answer = answer, toolsCalled = toolsCalled))
                EvalResult(
                    fixtureId = fixture.id,
                    kind = fixture.kind,
                    passed = verdict.passed,
                    failedChecks = verdict.failedChecks,
                    answer = answer,
                    thinking = message?.thinkingContent,
                    toolsCalled = toolsCalled,
                    chars = answer.length,
                    tokens = gen.stats.tokenCount,
                    generateMs = gen.stats.durationMs,
                    firstTokenMs = firstTokenMs,
                )
            }

            is GenerationState.Failed -> {
                val elapsed = Clock.System.now().toEpochMilliseconds() - turnStart
                errorResult(fixture, gen.error.toString(), generateMs = elapsed, firstTokenMs = firstTokenMs)
            }

            else -> {
                error("waited for a terminal generation state but got $gen")
            }
        }
    }

    private fun errorResult(
        fixture: EvalFixture,
        error: String,
        generateMs: Long,
        firstTokenMs: Long? = null,
    ) = EvalResult(
        fixtureId = fixture.id,
        kind = fixture.kind,
        passed = false,
        answer = "",
        chars = 0,
        tokens = 0,
        generateMs = generateMs,
        firstTokenMs = firstTokenMs,
        error = error,
    )

    private fun readFile(path: String): String = java.io.File(path).readText()

    companion object {
        const val ENGINE_INIT_TIMEOUT_MS = 10 * 60_000L
        const val CLEAR_TIMEOUT_MS = 10_000L
        const val TURN_START_TIMEOUT_MS = 15_000L
        const val FIXTURE_TIMEOUT_MS = 5 * 60_000L
    }
}
