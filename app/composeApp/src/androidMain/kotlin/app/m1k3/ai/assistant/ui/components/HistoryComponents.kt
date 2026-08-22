package app.m1k3.ai.assistant.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.m1k3.ai.assistant.design.components.MaButtonPrimary
import app.m1k3.ai.assistant.design.components.MaButtonSecondary
import app.m1k3.ai.assistant.design.components.MaCard
import app.m1k3.ai.assistant.design.haptics.HapticFeedbackType
import app.m1k3.ai.assistant.design.haptics.rememberHapticFeedback
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaFontFamilyCaption
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography
import app.m1k3.ai.assistant.history.ConversationInfo
import app.m1k3.ai.assistant.history.ExportFormat
import app.m1k3.ai.assistant.history.SearchResult
import app.m1k3.ai.domain.history.pluralizeMessages
import app.m1k3.ai.domain.history.toDisplayTitle
import kotlinx.datetime.Instant
import org.jetbrains.compose.ui.tooling.preview.Preview

/**
 * HistorySearchBar - Search bar for filtering conversations.
 *
 * @param query Current search query
 * @param onQueryChange Callback when query changes
 * @param modifier Modifier for the container
 */
@Composable
fun HistorySearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    MaCard(modifier = modifier) {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(MaSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(MaSpacing.sm),
        ) {
            Icon(
                imageVector = Icons.Default.Search,
                contentDescription = "Search",
                tint = MaColors.TextSecondary,
                modifier = Modifier.size(20.dp),
            )

            BasicTextField(
                value = query,
                onValueChange = onQueryChange,
                modifier = Modifier.weight(1f),
                textStyle =
                    MaTypography.bodyMedium.copy(
                        color = MaColors.textPrimary(),
                    ),
                cursorBrush = SolidColor(MaColors.Orange),
                decorationBox = { innerTextField ->
                    if (query.isEmpty()) {
                        Text(
                            "Search conversations...",
                            style = MaTypography.bodyMedium,
                            color = MaColors.TextMuted,
                        )
                    }
                    innerTextField()
                },
            )

            if (query.isNotEmpty()) {
                IconButton(
                    onClick = { onQueryChange("") },
                    modifier = Modifier.size(24.dp),
                ) {
                    Icon(
                        imageVector = Icons.Default.Clear,
                        contentDescription = "Clear search",
                        tint = MaColors.textSecondary(),
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

/**
 * ConversationsList - List of conversations with empty state.
 *
 * @param conversations List of conversations to display
 * @param onConversationClick Callback when a conversation is clicked
 * @param onDeleteClick Callback when delete is requested
 * @param onExportClick Callback when export is requested
 */
@Composable
fun ConversationsList(
    conversations: List<ConversationInfo>,
    onConversationClick: (Long) -> Unit,
    onDeleteClick: (Long) -> Unit,
    onExportClick: (Long) -> Unit,
) {
    if (conversations.isEmpty()) {
        HistoryEmptyState(
            message = "No conversations yet",
            subtitle = "Start chatting to see your history here",
        )
    } else {
        LazyColumn(
            verticalArrangement = Arrangement.spacedBy(MaSpacing.sm),
        ) {
            items(conversations, key = { it.id }) { conversation ->
                ConversationCard(
                    conversation = conversation,
                    onClick = { onConversationClick(conversation.id) },
                    onDeleteClick = { onDeleteClick(conversation.id) },
                    onExportClick = { onExportClick(conversation.id) },
                )
            }
        }
    }
}

/**
 * ConversationCard - Individual conversation card with expand/collapse.
 *
 * @param conversation Conversation info to display
 * @param onClick Callback when card is clicked
 * @param onDeleteClick Callback when delete is requested
 * @param onExportClick Callback when export is requested
 */
@Composable
fun ConversationCard(
    conversation: ConversationInfo,
    onClick: () -> Unit,
    onDeleteClick: () -> Unit,
    onExportClick: () -> Unit,
) {
    val haptics = rememberHapticFeedback()
    var expanded by remember { mutableStateOf(false) }

    MaCard(
        onClick = {
            haptics.performHapticFeedback(HapticFeedbackType.LIGHT)
            onClick()
        },
    ) {
        Column(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(MaSpacing.md),
        ) {
            // Title and message count
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = conversation.title.toDisplayTitle(),
                        style = MaTypography.titleMedium,
                        fontWeight = FontWeight.Medium,
                        color = MaColors.textPrimary(),
                        maxLines = 2,
                    )

                    Spacer(modifier = Modifier.height(MaSpacing.xs))

                    // Token count is an engineering noun (doctrine principle 7)
                    // — it never belonged on a row about a conversation.
                    Text(
                        text = pluralizeMessages(conversation.messageCount),
                        style =
                            TextStyle(
                                fontFamily = MaFontFamilyCaption,
                                fontWeight = FontWeight.Normal,
                                fontSize = 12.sp,
                                lineHeight = 16.sp,
                                letterSpacing = 0.25.sp,
                            ),
                        color = MaColors.textSecondary(),
                    )
                }

                IconButton(
                    onClick = {
                        haptics.performHapticFeedback(HapticFeedbackType.LIGHT)
                        expanded = !expanded
                    },
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(
                        imageVector =
                            if (expanded) {
                                Icons.Default.KeyboardArrowUp
                            } else {
                                Icons.Default.KeyboardArrowDown
                            },
                        contentDescription = if (expanded) "Collapse" else "Expand",
                        tint = MaColors.textSecondary(),
                    )
                }
            }

            // Timestamp
            Spacer(modifier = Modifier.height(MaSpacing.xs))
            Text(
                text = formatHistoryTimestamp(conversation.lastMessageAt),
                style = MaTypography.bodySmall,
                color = MaColors.TextMuted,
            )

            // Expanded actions
            AnimatedVisibility(
                visible = expanded,
                enter = fadeIn(),
                exit = fadeOut(),
            ) {
                Column {
                    Spacer(modifier = Modifier.height(MaSpacing.md))

                    HorizontalDivider(
                        color = MaColors.BorderLight,
                        modifier = Modifier.padding(vertical = MaSpacing.sm),
                    )

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(MaSpacing.sm),
                    ) {
                        MaButtonSecondary(
                            text = "Export",
                            onClick = {
                                haptics.performHapticFeedback(HapticFeedbackType.LIGHT)
                                onExportClick()
                            },
                            modifier = Modifier.weight(1f),
                        )

                        MaButtonSecondary(
                            text = "Delete",
                            onClick = {
                                haptics.performHapticFeedback(HapticFeedbackType.LIGHT)
                                onDeleteClick()
                            },
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}

/**
 * SearchResultsList - List of search results with empty state.
 *
 * @param results List of search results to display
 * @param onResultClick Callback when a result is clicked
 */
@Composable
fun SearchResultsList(
    results: List<SearchResult>,
    onResultClick: (SearchResult) -> Unit,
) {
    if (results.isEmpty()) {
        HistoryEmptyState(
            message = "No results found",
            subtitle = "Try a different search term",
        )
    } else {
        LazyColumn(
            verticalArrangement = Arrangement.spacedBy(MaSpacing.sm),
        ) {
            items(results, key = { it.id }) { result ->
                SearchResultCard(
                    result = result,
                    onClick = { onResultClick(result) },
                )
            }
        }
    }
}

/**
 * SearchResultCard - Individual search result card.
 *
 * @param result Search result to display
 * @param onClick Callback when card is clicked
 */
@Composable
fun SearchResultCard(
    result: SearchResult,
    onClick: () -> Unit,
) {
    val haptics = rememberHapticFeedback()

    MaCard(
        onClick = {
            haptics.performHapticFeedback(HapticFeedbackType.LIGHT)
            onClick()
        },
    ) {
        Column(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(MaSpacing.md),
        ) {
            // Relevance score
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = result.role.uppercase(),
                    style = MaTypography.labelSmall,
                    fontWeight = FontWeight.Bold,
                    color = if (result.role == "user") MaColors.Orange else MaColors.TextSecondary,
                )

                Text(
                    text = "${(result.relevanceScore * 100).toInt()}% match",
                    style = MaTypography.labelSmall,
                    color = MaColors.TextMuted,
                )
            }

            Spacer(modifier = Modifier.height(MaSpacing.sm))

            // Content preview
            Text(
                text = result.content,
                style = MaTypography.bodyMedium,
                color = MaColors.TextPrimary,
                maxLines = 3,
            )

            Spacer(modifier = Modifier.height(MaSpacing.sm))

            // Timestamp
            Text(
                text = formatHistoryTimestamp(result.timestamp),
                style = MaTypography.bodySmall,
                color = MaColors.TextMuted,
            )
        }
    }
}

/**
 * DeleteConfirmationDialog - Confirmation dialog for deleting conversations.
 *
 * @param conversation Conversation to be deleted
 * @param onConfirm Callback when deletion is confirmed
 * @param onDismiss Callback when dialog is dismissed
 */
@Composable
fun DeleteConfirmationDialog(
    conversation: ConversationInfo?,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                "Delete Conversation?",
                style = MaTypography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
        },
        text = {
            Text(
                "\"${conversation?.title}\" and all ${conversation?.messageCount} messages will be permanently deleted.",
                style = MaTypography.bodyMedium,
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text("Delete", color = MaColors.Error)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel", color = MaColors.TextSecondary)
            }
        },
        containerColor = MaterialTheme.colorScheme.surface,
        textContentColor = MaterialTheme.colorScheme.onSurface,
    )
}

/**
 * ExportDialog - Export format selection dialog.
 *
 * @param conversation Conversation to be exported
 * @param onExport Callback with selected format
 * @param onDismiss Callback when dialog is dismissed
 */
@Composable
fun ExportDialog(
    conversation: ConversationInfo?,
    onExport: (ExportFormat) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                "Export Conversation",
                style = MaTypography.titleMedium,
                fontWeight = FontWeight.Bold,
            )
        },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(MaSpacing.sm),
            ) {
                Text(
                    "Choose export format for \"${conversation?.title}\":",
                    style = MaTypography.bodyMedium,
                )

                Spacer(modifier = Modifier.height(MaSpacing.sm))

                MaButtonPrimary(
                    text = "JSON (Machine-readable)",
                    onClick = { onExport(ExportFormat.JSON) },
                    modifier = Modifier.fillMaxWidth(),
                )

                MaButtonSecondary(
                    text = "Markdown (Human-readable)",
                    onClick = { onExport(ExportFormat.MARKDOWN) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel", color = MaColors.TextSecondary)
            }
        },
        containerColor = MaterialTheme.colorScheme.surface,
        textContentColor = MaterialTheme.colorScheme.onSurface,
    )
}

/**
 * HistoryErrorCard - Error display card with dismiss action.
 *
 * @param message Error message to display
 * @param onDismiss Callback when error is dismissed
 * @param modifier Modifier for the container
 */
@Composable
fun HistoryErrorCard(
    message: String,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    MaCard(modifier = modifier) {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(MaSpacing.md),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                modifier = Modifier.weight(1f),
                horizontalArrangement = Arrangement.spacedBy(MaSpacing.sm),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Default.Warning,
                    contentDescription = "Error",
                    tint = MaColors.Error,
                )
                Text(
                    text = message,
                    style = MaTypography.bodyMedium,
                    color = MaColors.Error,
                )
            }

            IconButton(onClick = onDismiss) {
                Icon(
                    imageVector = Icons.Default.Close,
                    contentDescription = "Dismiss",
                    tint = MaColors.Error,
                )
            }
        }
    }
}

/**
 * HistoryEmptyState - Empty state display for history screen.
 *
 * @param message Main message to display
 * @param subtitle Subtitle message
 * @param modifier Modifier for the container
 */
@Composable
fun HistoryEmptyState(
    message: String,
    subtitle: String,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(MaSpacing.sm),
        ) {
            Text(
                text = message,
                style = MaTypography.titleMedium,
                fontWeight = FontWeight.Medium,
                color = MaColors.textSecondary(),
            )
            Text(
                text = subtitle,
                style = MaTypography.bodyMedium,
                color = MaColors.TextMuted,
            )
        }
    }
}

/**
 * Format timestamp for display in history screen.
 *
 * @param timestampMs Timestamp in milliseconds
 * @return Formatted string (e.g., "Just now", "5 min ago", "2 days ago")
 */
fun formatHistoryTimestamp(timestampMs: Long): String {
    val instant = Instant.fromEpochMilliseconds(timestampMs)
    val now =
        kotlinx.datetime.Clock.System
            .now()

    val diffMs = now.toEpochMilliseconds() - timestampMs
    val diffMinutes = diffMs / 60000
    val diffHours = diffMinutes / 60
    val diffDays = diffHours / 24

    return when {
        diffMinutes < 1 -> {
            "Just now"
        }

        diffMinutes < 60 -> {
            "$diffMinutes min ago"
        }

        diffHours < 24 -> {
            "$diffHours hours ago"
        }

        diffDays < 7 -> {
            "$diffDays days ago"
        }

        else -> {
            // Format as date
            val date = instant.toString().substringBefore("T")
            date
        }
    }
}

// ============================================================
// Previews
// ============================================================

@Preview
@Composable
private fun HistorySearchBarPreview() {
    MaTheme {
        HistorySearchBar(
            query = "machine learning",
            onQueryChange = {},
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
        )
    }
}

@Preview
@Composable
private fun ConversationCardPreview() {
    MaTheme {
        ConversationCard(
            conversation =
                ConversationInfo(
                    id = 1,
                    projectId = "default",
                    title = "Discussing AI Ethics",
                    startedAt = System.currentTimeMillis() - 3600000,
                    lastMessageAt = System.currentTimeMillis(),
                    messageCount = 12,
                    tokenCount = 3400,
                    isArchived = false,
                ),
            onClick = {},
            onDeleteClick = {},
            onExportClick = {},
        )
    }
}

@Preview
@Composable
private fun ConversationsListEmptyPreview() {
    MaTheme {
        ConversationsList(
            conversations = emptyList(),
            onConversationClick = {},
            onDeleteClick = {},
            onExportClick = {},
        )
    }
}
