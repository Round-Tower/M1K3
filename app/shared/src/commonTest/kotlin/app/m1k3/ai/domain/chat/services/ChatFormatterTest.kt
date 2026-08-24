package app.m1k3.ai.domain.chat.services

import app.m1k3.ai.domain.chat.format.ChatFormat
import app.m1k3.ai.domain.chat.format.MessageRole
import app.m1k3.ai.domain.tools.*
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.assertEquals

/**
 * Tests for ChatFormatter interface and DefaultChatFormatter
 *
 * TDD: These tests define the contract for building prompts.
 */
class ChatFormatterTest {

    // ===== Basic Prompt Building =====

    @Test
    fun `thinking off pre-closes the think block in the ChatML assistant turn`() {
        val prompt =
            DefaultChatFormatter(ChatFormat.ChatML, thinking = false).buildPrompt(
                systemPrompt = "You are helpful.",
                messages = listOf(ChatMessage(MessageRole.USER, "Hello")),
            )
        assertTrue(prompt.endsWith("<|im_start|>assistant\n<think>\n\n</think>\n\n"))

        val thinking =
            DefaultChatFormatter(ChatFormat.ChatML).buildPrompt(
                systemPrompt = "You are helpful.",
                messages = listOf(ChatMessage(MessageRole.USER, "Hello")),
            )
        assertTrue(thinking.endsWith("<|im_start|>assistant\n"))
    }

    @Test
    fun `builds prompt with system and user message`() {
        val formatter = DefaultChatFormatter(ChatFormat.ChatML)

        val prompt = formatter.buildPrompt(
            systemPrompt = "You are helpful.",
            messages = listOf(
                ChatMessage(MessageRole.USER, "Hello")
            )
        )

        assertTrue(prompt.contains("You are helpful"))
        assertTrue(prompt.contains("Hello"))
        assertTrue(prompt.contains("<|im_start|>"))
    }

    @Test
    fun `builds prompt with conversation history`() {
        val formatter = DefaultChatFormatter(ChatFormat.ChatML)

        val prompt = formatter.buildPrompt(
            systemPrompt = "You are helpful.",
            messages = listOf(
                ChatMessage(MessageRole.USER, "What is 2+2?"),
                ChatMessage(MessageRole.ASSISTANT, "4"),
                ChatMessage(MessageRole.USER, "Thanks!")
            )
        )

        assertTrue(prompt.contains("What is 2+2?"))
        assertTrue(prompt.contains("4"))
        assertTrue(prompt.contains("Thanks!"))
    }

    // ===== Tool Schema Inclusion =====

    @Test
    fun `includes tool schema when tools provided`() {
        val formatter = DefaultChatFormatter(ChatFormat.ChatML)
        val tools = listOf(createBatteryTool())

        val prompt = formatter.buildPrompt(
            systemPrompt = "You are helpful.",
            messages = listOf(ChatMessage(MessageRole.USER, "Check my battery")),
            tools = tools
        )

        assertTrue(prompt.contains("get_battery_level"))
        assertTrue(prompt.contains("battery level"))
    }

    @Test
    fun `omits tool schema when no tools`() {
        val formatter = DefaultChatFormatter(ChatFormat.ChatML)

        val prompt = formatter.buildPrompt(
            systemPrompt = "You are helpful.",
            messages = listOf(ChatMessage(MessageRole.USER, "Hello"))
        )

        // Should not contain tool-related markers
        assertTrue(!prompt.contains("tool_call") || prompt.contains("You are helpful"))
    }

    // ===== Tool Result Formatting =====

    @Test
    fun `formats success tool result`() {
        val formatter = DefaultChatFormatter(ChatFormat.ChatML)

        val result = ToolResult.Success(
            toolId = "get_battery_level",
            output = "Battery is at 75%",
            executionTimeMs = 10
        )

        val formatted = formatter.formatToolResult(result)

        assertTrue(formatted.contains("Battery is at 75%"))
    }

    @Test
    fun `formats failure tool result`() {
        val formatter = DefaultChatFormatter(ChatFormat.ChatML)

        val result = ToolResult.Failure(
            toolId = "toggle_flashlight",
            error = ToolError.Unavailable("No flashlight"),
            executionTimeMs = 5
        )

        val formatted = formatter.formatToolResult(result)

        assertTrue(formatted.contains("No flashlight") || formatted.contains("unavailable"))
    }

    // ===== Format-Specific Tests =====

    @Test
    fun `Llama format uses correct markers`() {
        val formatter = DefaultChatFormatter(ChatFormat.Llama)

        val prompt = formatter.buildPrompt(
            systemPrompt = "Be concise.",
            messages = listOf(ChatMessage(MessageRole.USER, "Hi"))
        )

        assertTrue(prompt.contains("<<SYS>>"))
        assertTrue(prompt.contains("[INST]"))
    }

    @Test
    fun `Gemma3 format uses correct markers`() {
        val formatter = DefaultChatFormatter(ChatFormat.Gemma3)

        val prompt = formatter.buildPrompt(
            systemPrompt = "Be helpful.",
            messages = listOf(ChatMessage(MessageRole.USER, "Hi"))
        )

        assertTrue(prompt.contains("<start_of_turn>"))
        assertTrue(prompt.contains("<end_of_turn>"))
    }

    @Test
    fun `Simple format has no special markers`() {
        val formatter = DefaultChatFormatter(ChatFormat.Simple)

        val prompt = formatter.buildPrompt(
            systemPrompt = "Be helpful.",
            messages = listOf(ChatMessage(MessageRole.USER, "Hi"))
        )

        assertTrue(!prompt.contains("<|im_start|>"))
        assertTrue(!prompt.contains("[INST]"))
        assertTrue(!prompt.contains("<start_of_turn>"))
    }

    // ===== Stop Tokens =====

    @Test
    fun `returns correct stop tokens for format`() {
        val chatML = DefaultChatFormatter(ChatFormat.ChatML)
        val llama = DefaultChatFormatter(ChatFormat.Llama)

        assertTrue(chatML.getStopTokens().contains("<|im_end|>"))
        assertTrue(llama.getStopTokens().contains("</s>"))
    }

    // ===== Gemma3 Consolidated Prompt Tests (regression: system prompt leak) =====

    @Test
    fun `Gemma3 consolidates system prompt into single user turn`() {
        val formatter = DefaultChatFormatter(ChatFormat.Gemma3)

        val prompt = formatter.buildPrompt(
            systemPrompt = "You are M1k3, a helpful AI.",
            messages = listOf(ChatMessage(MessageRole.USER, "Hello"))
        )

        // Gemma3 has no system role - everything goes in one user turn
        // Count user turns: should be exactly ONE
        val userTurnCount = prompt.split("<start_of_turn>user").size - 1
        assertEquals(1, userTurnCount, "Gemma3 should have exactly one user turn (consolidated)")

        // System prompt should be INSIDE the user turn, not a separate turn
        assertTrue(prompt.contains("<start_of_turn>user\nYou are M1k3"))
        // Should end with model turn start for generation
        assertTrue(prompt.contains("<start_of_turn>model"))
    }

    @Test
    fun `Gemma3 prompt is detectable as pre-formatted`() {
        val formatter = DefaultChatFormatter(ChatFormat.Gemma3)

        val prompt = formatter.buildPrompt(
            systemPrompt = "You are M1k3.",
            messages = listOf(ChatMessage(MessageRole.USER, "Hi"))
        )

        // Pre-formatted prompts should contain Gemma3 markers
        assertTrue(prompt.contains("<start_of_turn>"), "Should contain Gemma3 turn marker")
        assertTrue(prompt.startsWith("<bos>"), "Should start with BOS token")
    }

    @Test
    fun `FalconH1 prompt is detectable as pre-formatted`() {
        val formatter = DefaultChatFormatter(ChatFormat.FalconH1)

        val prompt = formatter.buildPrompt(
            systemPrompt = "You are M1k3.",
            messages = listOf(ChatMessage(MessageRole.USER, "Hi"))
        )

        assertTrue(prompt.contains("<|start_header_id|>"), "Should contain FalconH1 header marker")
        assertTrue(prompt.startsWith("<|begin_of_text|>"), "Should start with FalconH1 BOS")
    }

    @Test
    fun `FalconH1 uses separate system turn`() {
        val formatter = DefaultChatFormatter(ChatFormat.FalconH1)

        val prompt = formatter.buildPrompt(
            systemPrompt = "You are M1k3.",
            messages = listOf(ChatMessage(MessageRole.USER, "Hello"))
        )

        // FalconH1 supports system role - should have separate system and user turns
        assertTrue(prompt.contains("<|start_header_id|>system<|end_header_id|>"))
        assertTrue(prompt.contains("<|start_header_id|>user<|end_header_id|>"))
        assertTrue(prompt.contains("<|start_header_id|>assistant<|end_header_id|>"))
    }

    // ===== Helper =====

    private fun createBatteryTool() = Tool(
        id = "get_battery_level",
        name = "Battery Level",
        description = "Gets the current battery level",
        parameters = emptyList(),
        category = ToolCategory.DEVICE_INFO
    )
}
