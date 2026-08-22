package app.m1k3.ai.domain.chat.services

import app.m1k3.ai.domain.chat.format.ChatFormat
import app.m1k3.ai.domain.chat.format.MessageRole
import app.m1k3.ai.domain.tools.Tool
import app.m1k3.ai.domain.tools.ToolResult

/**
 * Default Chat Formatter - Builds prompts using ChatFormat specifications
 *
 * Pure Kotlin implementation with no external dependencies.
 *
 * **Prompt Structure (formats with system role):**
 * ```
 * [Tool Schema (if tools provided)]
 * [System Prompt]
 * [Message 1]
 * [Message 2]
 * ...
 * [Tool Results (if any)]
 * [Assistant Turn Start (for generation)]
 * ```
 *
 * **Prompt Structure (formats WITHOUT system role, e.g., Gemma3):**
 * ```
 * [Single User Turn containing:
 *   - System instructions
 *   - Tool schema (if any)
 *   - User message
 * ]
 * [Assistant Turn Start (for generation)]
 * ```
 *
 * @param format The ChatFormat to use for formatting
 */
class DefaultChatFormatter(
    override val format: ChatFormat,
    /**
     * When false, ChatML prompts pre-fill an empty `<think></think>` block in
     * the assistant turn — Qwen's documented soft switch for reasoning OFF.
     * See [app.m1k3.ai.domain.ai.ThinkingPolicy] for why Mini/Lil run this way.
     */
    private val thinking: Boolean = true,
) : ChatFormatter {

    override fun buildPrompt(
        systemPrompt: String,
        messages: List<ChatMessage>,
        tools: List<Tool>,
        toolResults: List<ToolResult>
    ): String = buildString {
        // 0. Prompt prefix (e.g., <bos> for Gemma3)
        val prefix = format.getPromptPrefix()
        if (prefix.isNotEmpty()) {
            append(prefix)
        }

        val effectiveSystemPrompt = systemPrompt.ifBlank {
            "You are M1k3, a pocket intelligence - always help the user complete their goal, and think step by step"
        }

        if (format.supportsSystemRole) {
            // Formats with system role: Use separate turns
            buildMultiTurnPrompt(effectiveSystemPrompt, messages, tools, toolResults)
        } else {
            // Formats without system role (Gemma3): Consolidate into single user turn
            buildConsolidatedPrompt(effectiveSystemPrompt, messages, tools, toolResults)
        }

        // Tool results (if any) - always after main content
        toolResults.forEach { result ->
            val resultText = formatToolResult(result)
            append(format.formatMessage(MessageRole.TOOL, resultText))
        }

        // Start assistant turn (for generation)
        append(getAssistantTurnStart())
    }

    /**
     * Build prompt with separate turns for system, tools, and messages.
     * Used by formats that support distinct system role (ChatML, Llama).
     */
    private fun StringBuilder.buildMultiTurnPrompt(
        systemPrompt: String,
        messages: List<ChatMessage>,
        tools: List<Tool>,
        toolResults: List<ToolResult>
    ) {
        // 1. Tool schema (if tools provided and format supports them)
        if (tools.isNotEmpty() && format.supportsTools) {
            append(format.formatToolSchema(tools))
        }

        // 2. System prompt
        append(format.formatMessage(MessageRole.SYSTEM, systemPrompt))

        // 3. Conversation messages
        messages.forEach { message ->
            append(format.formatMessage(message.role, message.content))
        }
    }

    /**
     * Build prompt with all content consolidated into a single user turn.
     * Used by formats without system role support (Gemma3, Simple).
     *
     * Structure:
     * ```
     * <start_of_turn>user
     * [System instructions]
     *
     * [Tool schema if any]
     *
     * [User message with context]
     * <end_of_turn>
     * ```
     */
    private fun StringBuilder.buildConsolidatedPrompt(
        systemPrompt: String,
        messages: List<ChatMessage>,
        tools: List<Tool>,
        toolResults: List<ToolResult>
    ) {
        val consolidatedContent = buildString {
            // 1. System instructions first (brief for small models)
            append(systemPrompt)
            appendLine()
            appendLine()

            // 2. Tool schema (if any) - simplified for small models
            if (tools.isNotEmpty() && format.supportsTools) {
                appendLine("You have tools. When a tool matches the request, you MUST call it.")
                tools.forEach { tool ->
                    append("- ${tool.id}: ${tool.description}")
                    if (tool.parameters.isNotEmpty()) {
                        val params = tool.parameters.joinToString(", ") { p ->
                            val req = if (p.required) "" else "?"
                            "${p.name}$req"
                        }
                        append(" ($params)")
                    }
                    appendLine()
                }
                appendLine("Example: {\"tool\": \"${tools.first().id}\", \"args\": {}}")
                appendLine()
            }

            // 3. User message(s)
            messages.forEach { message ->
                append(message.content)
            }
        }

        append(format.formatMessage(MessageRole.USER, consolidatedContent.trim()))
    }

    override fun formatToolResult(result: ToolResult): String = when (result) {
        is ToolResult.Success -> buildString {
            append("[Tool: ${result.toolId}] ")
            append(result.output)
            if (result.data != null) {
                append(" (data: ${result.data})")
            }
        }

        is ToolResult.Failure -> buildString {
            append("[Tool: ${result.toolId}] ")
            append("Error: ${result.error.displayMessage}")
        }

        is ToolResult.RequiresConfirmation -> buildString {
            append("[Tool: ${result.toolId}] ")
            append("Awaiting confirmation: ${result.confirmationPrompt}")
        }
    }

    override fun getStopTokens(): List<String> = format.getStopTokens()

    /**
     * Get the prefix that starts an assistant turn
     *
     * This is appended at the end to prompt the model to generate.
     */
    private fun getAssistantTurnStart(): String = when (format) {
        is ChatFormat.ChatML -> if (thinking) "<|im_start|>assistant\n" else "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        is ChatFormat.Llama -> "" // Llama generates after [/INST]
        is ChatFormat.Gemma3 -> "<start_of_turn>model\n"
        is ChatFormat.Gemma4 -> "<start_of_turn>model\n"
        is ChatFormat.FalconH1 -> "<|start_header_id|>assistant<|end_header_id|>\n"
        is ChatFormat.Simple -> ""
    }
}
