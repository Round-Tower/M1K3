package app.m1k3.ai.assistant.design.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.jetbrains.compose.ui.tooling.preview.Preview
import androidx.compose.foundation.interaction.MutableInteractionSource
import app.m1k3.ai.assistant.design.effects.glassmorphic
import app.m1k3.ai.assistant.design.preview.PreviewFixtures
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaRadius
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography
import kotlin.time.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlin.time.ExperimentalTime

/**
 * M1K3 Bubble Components
 *
 * Message bubbles for chat conversations:
 * - MaChatBubbleUser: Orange-accented user messages (right-aligned)
 * - MaChatBubbleAI: Glassmorphic AI messages (left-aligned)
 *
 * Features:
 * - Streaming text support (updates during generation)
 * - Inference statistics display for AI messages
 * - Error state styling
 * - Timestamp display
 * - AMOLED-optimized colors
 */

/**
 * User message bubble
 *
 * Styled with M1K3 orange accent border and dark background.
 * Right-aligned for conversational clarity.
 *
 * @param text Message content
 * @param timestamp Unix timestamp (milliseconds)
 * @param modifier Optional modifier
 */
@Composable
fun MaChatBubbleUser(
    text: String,
    timestamp: Long,
    modifier: Modifier = Modifier
) {
    val bubbleShape = RoundedCornerShape(
        topStart = MaRadius.xl,
        topEnd = MaRadius.xl,
        bottomStart = MaRadius.xl,
        bottomEnd = MaRadius.xs  // Sharp corner on sender side
    )

    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = MaSpacing.base, vertical = MaSpacing.xs),
        horizontalArrangement = Arrangement.End
    ) {
        Column(
            horizontalAlignment = Alignment.End,
            modifier = Modifier
                .widthIn(max = 320.dp)
                .clip(bubbleShape)
                .background(MaColors.OrangeFaint)
                .border(
                    width = 1.dp,
                    color = MaColors.OrangeDim,
                    shape = bubbleShape
                )
                .padding(horizontal = MaSpacing.md, vertical = MaSpacing.md)
        ) {
            Text(
                text = text,
                style = MaTypography.bodyLarge,
                color = MaColors.textPrimary()
            )

            // Timestamp
            Text(
                text = formatTimestamp(timestamp),
                style = MaTypography.labelSmall,
                color = MaColors.textDisabled(),
                modifier = Modifier.padding(top = MaSpacing.xs)
            )
        }
    }
}

/**
 * AI message bubble
 *
 * Styled with glassmorphic liquid glass aesthetic.
 * Left-aligned with optional inference stats display.
 *
 * @param text Message content (supports streaming updates)
 * @param timestamp Unix timestamp (milliseconds)
 * @param inferenceStats Optional stats string (e.g., "42 tok/s • 256 tokens • 6.1s")
 * @param isError Whether message is an error (shows red accent)
 * @param ragSources Optional RAG sources (Phase 3)
 * @param modifier Optional modifier
 */
@Composable
fun MaChatBubbleAI(
    text: String,
    timestamp: Long,
    inferenceStats: String? = null,
    isError: Boolean = false,
    ragSources: String? = null,
    onSpeak: (() -> Unit)? = null,
    /** Renders an artifact (e.g. ArtifactView) — null for plain text responses */
    artifactContent: (@Composable () -> Unit)? = null,
    /** Renders the ThinkingPill above the bubble — passed as slot from androidMain ChatScreen */
    thinkingPill: (@Composable () -> Unit)? = null,
    /** Renders the ToolCallPill below thinking, above bubble — shows tool execution results */
    toolCallsPill: (@Composable () -> Unit)? = null,
    isStreaming: Boolean = false,
    modifier: Modifier = Modifier
) {
    val bubbleShape = RoundedCornerShape(
        topStart = MaRadius.xl,
        topEnd = MaRadius.xl,
        bottomStart = MaRadius.xs,  // Sharp corner on sender side
        bottomEnd = MaRadius.xl
    )

    val borderColor = if (isError) MaColors.Error.copy(alpha = 0.3f) else MaColors.borderSubtle()
    val bgColor = if (isError) MaColors.ErrorBg else MaColors.bgGlass()

    Row(
        modifier = modifier
            .fillMaxWidth(),
        horizontalArrangement = Arrangement.Start
    ) {
        Column(
            horizontalAlignment = Alignment.Start,
            modifier = Modifier
                .widthIn(max = 340.dp)
                .padding(horizontal = MaSpacing.sm, vertical = MaSpacing.xs)
        ) {
            // ThinkingPill slot — passed from ChatScreen (androidMain) so no platform crossing
            thinkingPill?.invoke()

            // ToolCallPill slot — shows tool execution results
            toolCallsPill?.invoke()

            Column(
                modifier = Modifier
                    .clip(bubbleShape)
                    .background(bgColor)
                    .border(
                        width = 1.dp,
                        color = borderColor,
                        shape = bubbleShape
                    )
            ) {
            Box(
                modifier = Modifier
                    .padding(horizontal = MaSpacing.md, vertical = MaSpacing.md)
            ) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(MaSpacing.sm)
                ) {
                    if (artifactContent != null) {
                        val strippedText = text.replace(
                            Regex("<artifact[^>]*>[\\s\\S]*?</artifact>", RegexOption.IGNORE_CASE), ""
                        ).trim()
                        if (strippedText.isNotEmpty()) {
                            // During streaming: plain Text (no markdown parse overhead)
                            // On complete: full MarkdownText
                            if (isStreaming) {
                                androidx.compose.material3.Text(
                                    text = strippedText,
                                    style = app.m1k3.ai.assistant.design.tokens.MaTypography.bodyLarge,
                                    color = if (isError) MaColors.Error else MaColors.textPrimary()
                                )
                            } else {
                                MarkdownText(text = strippedText, isError = isError)
                            }
                        }
                        artifactContent()
                    } else {
                        // Strip any remaining < *think *> blocks before display
                        val displayText = text.replace(
                            Regex("< *think *>[\\s\\S]*?</ *think *>", RegexOption.IGNORE_CASE), ""
                        ).trim()
                        if (isStreaming) {
                            androidx.compose.material3.Text(
                                text = displayText,
                                style = app.m1k3.ai.assistant.design.tokens.MaTypography.bodyLarge,
                                color = if (isError) MaColors.Error else MaColors.textPrimary()
                            )
                        } else {
                            MarkdownText(text = displayText, isError = isError)
                        }
                    }

                    // Timestamp
                    Text(
                        text = formatTimestamp(timestamp),
                        style = MaTypography.labelSmall,
                        color = MaColors.textDisabled(),
                        modifier = Modifier.padding(top = MaSpacing.xs)
                    )

                    // Inference statistics + speak button row
                    if (inferenceStats != null || onSpeak != null) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(MaSpacing.sm)
                        ) {
                            if (inferenceStats != null) {
                                Text(
                                    text = inferenceStats,
                                    style = MaTypography.labelSmall,
                                    color = MaColors.textDisabled(),
                                    fontWeight = FontWeight.Medium
                                )
                            }
                            if (onSpeak != null) {
                                Text(
                                    text = "\uD83D\uDD0A", // speaker icon
                                    style = MaTypography.labelSmall,
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(4.dp))
                                        .clickable(
                                            indication = null,
                                            interactionSource = remember { MutableInteractionSource() }
                                        ) { onSpeak() }
                                        .padding(horizontal = 4.dp, vertical = 2.dp)
                                )
                            }
                        }
                    }

                    // RAG status indicator with collapsible sources
                    if (ragSources != null) {
                        var isExpanded by remember { mutableStateOf(false) }
                        val factCount = ragSources.lines().count { it.isNotBlank() }

                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = MaSpacing.sm)
                        ) {
                            // RAG badge - clickable to expand sources
                            Row(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(MaRadius.sm))
                                    .background(MaColors.Orange.copy(alpha = 0.15f))
                                    .clickable { isExpanded = !isExpanded }
                                    .padding(horizontal = MaSpacing.sm, vertical = MaSpacing.xs),
                                horizontalArrangement = Arrangement.spacedBy(MaSpacing.xs),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = "• $factCount ${if (factCount == 1) "fact" else "facts"}",
                                    style = MaTypography.labelSmall,
                                    color = MaColors.textSecondary()
                                )
                                Text(
                                    text = if (isExpanded) "▲" else "▼",
                                    style = MaTypography.labelSmall,
                                    color = MaColors.textDisabled()
                                )
                            }

                            // Expandable sources list
                            AnimatedVisibility(
                                visible = isExpanded,
                                enter = expandVertically(),
                                exit = shrinkVertically()
                            ) {
                                Text(
                                    text = ragSources,
                                    style = MaTypography.labelSmall,
                                    color = MaColors.textSecondary(),
                                    modifier = Modifier.padding(
                                        start = MaSpacing.sm,
                                        top = MaSpacing.xs,
                                        end = MaSpacing.sm
                                    )
                                )
                            }
                        }
                    }
                }
            }
        } // close inner Column (clip/background/border)
    } // close outer Column (widthIn)
    } // close Row
} // close MaChatBubbleAI

/**
 * Format Unix timestamp to "HH:MM" format
 *
 * @param timestamp Unix timestamp in milliseconds
 * @return Formatted time string (e.g., "14:32")
 */
@OptIn(ExperimentalTime::class)
private fun formatTimestamp(timestamp: Long): String {
    val instant = Instant.fromEpochMilliseconds(timestamp)
    val localDateTime = instant.toLocalDateTime(TimeZone.currentSystemDefault())

    val hour = localDateTime.hour.toString().padStart(2, '0')
    val minute = localDateTime.minute.toString().padStart(2, '0')

    return "$hour:$minute"
}

/**
 * Usage Examples:
 * ```kotlin
 * // User message
 * MaChatBubbleUser(
 *     text = "What's the weather like?",
 *     timestamp = Clock.System.now().toEpochMilliseconds()
 * )
 *
 * // AI message
 * MaChatBubbleAI(
 *     text = "Based on current conditions...",
 *     timestamp = Clock.System.now().toEpochMilliseconds(),
 *     inferenceStats = "42 tok/s • 128 tokens • 3.0s"
 * )
 *
 * // Error message
 * MaChatBubbleAI(
 *     text = "⚠️ Model initialization failed",
 *     timestamp = Clock.System.now().toEpochMilliseconds(),
 *     isError = true
 * )
 *
 * // Streaming (updates in real-time)
 * var streamingText by remember { mutableStateOf("The sky is") }
 * MaChatBubbleAI(
 *     text = streamingText,  // Updates: "The sky is" → "The sky is blue"
 *     timestamp = Clock.System.now().toEpochMilliseconds()
 * )
 * ```
 */

// ============================================================
// Previews
// ============================================================

@Preview
@Composable
private fun MaChatBubbleUserPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base)
        ) {
            MaChatBubbleUser(
                text = PreviewFixtures.sampleShortText,
                timestamp = PreviewFixtures.sampleUserMessageTimestamp
            )
        }
    }
}

@Preview
@Composable
private fun MaChatBubbleUserLongTextPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base)
        ) {
            MaChatBubbleUser(
                text = PreviewFixtures.sampleLongText,
                timestamp = PreviewFixtures.sampleUserMessageTimestamp
            )
        }
    }
}

@Preview
@Composable
private fun MaChatBubbleAIPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base)
        ) {
            MaChatBubbleAI(
                text = "Hi there! How can I help you today?",
                timestamp = PreviewFixtures.sampleAiMessageTimestamp
            )
        }
    }
}

@Preview
@Composable
private fun MaChatBubbleAIWithStatsPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base)
        ) {
            MaChatBubbleAI(
                text = "Machine learning is a subset of artificial intelligence where systems learn and improve from experience without being explicitly programmed.",
                timestamp = PreviewFixtures.sampleAiMessageTimestamp,
                inferenceStats = PreviewFixtures.sampleInferenceStatsLong
            )
        }
    }
}

@Preview
@Composable
private fun MaChatBubbleAIWithRagPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base)
        ) {
            MaChatBubbleAI(
                text = "Based on the knowledge base, machine learning algorithms can be categorized into supervised, unsupervised, and reinforcement learning.",
                timestamp = PreviewFixtures.sampleAiMessageTimestamp,
                inferenceStats = PreviewFixtures.sampleInferenceStatsMedium,
                ragSources = PreviewFixtures.sampleRagSourceMultiple
            )
        }
    }
}

@Preview
@Composable
private fun MaChatBubbleAIErrorPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base)
        ) {
            MaChatBubbleAI(
                text = "⚠️ Model initialization failed. Please try again.",
                timestamp = PreviewFixtures.sampleAiMessageTimestamp,
                isError = true
            )
        }
    }
}

@Preview
@Composable
private fun MaChatBubbleConversationPreview() {
    MaTheme {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaColors.bgPrimary())
                .padding(MaSpacing.base),
            verticalArrangement = Arrangement.spacedBy(MaSpacing.base)
        ) {
            Text(
                "Sample Conversation:",
                style = MaTypography.labelSmall,
                color = MaColors.textSecondary(),
                modifier = Modifier.padding(bottom = MaSpacing.sm)
            )

            MaChatBubbleUser(
                text = "Hello! What is machine learning?",
                timestamp = PreviewFixtures.sampleUserMessageTimestamp
            )

            MaChatBubbleAI(
                text = "Machine learning is a subset of artificial intelligence where systems learn and improve from experience without being explicitly programmed.",
                timestamp = PreviewFixtures.sampleAiMessageTimestamp,
                inferenceStats = PreviewFixtures.sampleInferenceStatsLong,
                ragSources = PreviewFixtures.sampleRagSourceSingle
            )

            MaChatBubbleUser(
                text = "Tell me more!",
                timestamp = PreviewFixtures.sampleUserMessageTimestamp + 2000
            )

            MaChatBubbleAI(
                text = "There are three main types: supervised learning (with labeled data), unsupervised learning (finding patterns), and reinforcement learning (reward-based).",
                timestamp = PreviewFixtures.sampleAiMessageTimestamp + 2000,
                inferenceStats = PreviewFixtures.sampleInferenceStatsLong
            )
        }
    }
}
