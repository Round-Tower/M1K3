package app.m1k3.ai.domain.ai

import app.m1k3.ai.domain.chat.format.ChatFormat
import app.m1k3.ai.domain.chat.format.MessageRole
import app.m1k3.ai.domain.chat.services.ChatMessage
import app.m1k3.ai.domain.chat.services.DefaultChatFormatter
import app.m1k3.ai.domain.tools.Tool
import app.m1k3.ai.domain.tools.ToolCategory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * TDD coverage for [ChatMlPromptSplit] — proves it recovers exactly what
 * [DefaultChatFormatter] rendered for [ChatFormat.ChatML] (the format
 * [LlmModel.Qwen35_0B8] carries, which is what the Mini tier's llama.cpp
 * fallback — and therefore [app.m1k3.ai.domain.ai.ChatMlPromptSplit]'s only
 * real caller, the Gemini Nano engine — will actually receive).
 */
class ChatMlPromptSplitTest {
    private val formatter = DefaultChatFormatter(ChatFormat.ChatML)

    @Test
    fun `splits a plain system plus user turn`() {
        val rendered =
            formatter.buildPrompt(
                systemPrompt = "You are M1K3.",
                messages = listOf(ChatMessage(role = MessageRole.USER, content = "Hello there")),
            )

        val split = ChatMlPromptSplit.split(rendered)

        assertEquals("You are M1K3.", split.systemInstruction)
        assertEquals("Hello there", split.userContent)
    }

    @Test
    fun `joins a tool-schema system block with the persona system block`() {
        val tool =
            Tool(
                id = "get_battery_level",
                name = "Battery",
                description = "Reads battery level",
                parameters = emptyList(),
                category = ToolCategory.DEVICE_INFO,
            )
        val rendered =
            formatter.buildPrompt(
                systemPrompt = "You are M1K3.",
                messages = listOf(ChatMessage(role = MessageRole.USER, content = "What's my battery?")),
                tools = listOf(tool),
            )

        val split = ChatMlPromptSplit.split(rendered)

        // Both the tool-schema system block and the persona system block are
        // present, joined — never dropped, never duplicated.
        assertTrue(split.systemInstruction.contains("get_battery_level"))
        assertTrue(split.systemInstruction.contains("You are M1K3."))
        assertEquals("What's my battery?", split.userContent)
    }

    @Test
    fun `falls back to whole-string-as-user-content when no ChatML markers are present`() {
        val split = ChatMlPromptSplit.split("just some plain text, no markup")

        assertEquals("", split.systemInstruction)
        assertEquals("just some plain text, no markup", split.userContent)
    }

    @Test
    fun `never duplicates the system content across the two fields`() {
        val rendered =
            formatter.buildPrompt(
                systemPrompt = "UNIQUE_PERSONA_MARKER_712",
                messages = listOf(ChatMessage(role = MessageRole.USER, content = "hi")),
            )

        val split = ChatMlPromptSplit.split(rendered)
        val occurrences = Regex("UNIQUE_PERSONA_MARKER_712").findAll(split.systemInstruction + "\n" + split.userContent).count()

        assertEquals(1, occurrences)
    }
}
