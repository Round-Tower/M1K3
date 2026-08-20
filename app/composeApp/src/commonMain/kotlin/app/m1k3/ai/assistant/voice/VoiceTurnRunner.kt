package app.m1k3.ai.assistant.voice

import app.m1k3.ai.assistant.chat.ChatUiState
import app.m1k3.ai.assistant.chat.GenerationState
import app.m1k3.ai.assistant.chat.toUserMessage
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first

/**
 * Runs one voice-mode turn through the SAME `ChatScreenViewModel` path typed
 * chat uses — [updateInputText] + [sendMessage] are its two real actions,
 * `chat.updateInputText`/`chat.sendMessage`, so there is no second turn
 * mechanism to drift from the one already covered by the chat test suite.
 *
 * Whole-answer only (v1, mirrors the iOS shell) — no sentence streaming yet.
 *
 * A message-count guard, not a bare "wait for Complete/Failed": [uiState]
 * may already be sitting in a Complete/Failed state left over from the
 * PREVIOUS turn at the moment this one starts (sendMessage() only ever
 * SCHEDULES its state updates, it doesn't block until they land) — waiting
 * on generation state alone would resolve this turn off that stale answer.
 */
suspend fun runVoiceTurn(
    question: String,
    uiState: StateFlow<ChatUiState>,
    updateInputText: (String) -> Unit,
    sendMessage: () -> Unit,
): Result<String> {
    val startCount = uiState.value.messages.size
    updateInputText(question)
    sendMessage()
    val final =
        uiState.first { state ->
            state.messages.size > startCount &&
                (state.generationState is GenerationState.Complete || state.generationState is GenerationState.Failed)
        }
    return when (val gs = final.generationState) {
        is GenerationState.Complete -> {
            if (gs.finalText.isBlank()) {
                Result.failure(VoiceTurnFailure("The model had nothing to say."))
            } else {
                Result.success(gs.finalText)
            }
        }

        is GenerationState.Failed -> {
            Result.failure(VoiceTurnFailure(gs.error.toUserMessage()))
        }

        else -> {
            Result.failure(VoiceTurnFailure("No answer arrived."))
        }
    }
}
