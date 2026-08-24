package app.m1k3.ai.assistant.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.design.haptics.HapticFeedbackType
import app.m1k3.ai.assistant.design.haptics.rememberHapticFeedback
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaFontFamilyCaption
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography
import app.m1k3.ai.assistant.history.HistoryViewModel
import app.m1k3.ai.assistant.history.collectAsState
import app.m1k3.ai.assistant.ui.components.*
import org.jetbrains.compose.ui.tooling.preview.Preview
import org.koin.androidx.compose.koinViewModel

/**
 * HistoryScreen - Conversation History Screen
 *
 * Comprehensive conversation management:
 * - Browse all conversations by project
 * - Search messages across conversations
 * - Export to JSON/Markdown
 * - Delete conversations
 *
 * **Architecture:**
 * - Uses HistoryViewModel for state management
 * - Delegates to extracted components (HistorySearchBar, ConversationCard, etc.)
 * - Minimal UI logic - ViewModel handles business logic
 *
 * Philosophy: Your data, your control - full transparency and portability
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(
    database: MaDatabase,
    projectId: String,
    onBackClick: () -> Unit = {},
    onConversationClick: (Long) -> Unit = {},
) {
    val haptics = rememberHapticFeedback()

    // HistoryViewModel - Single source of truth for history state
    val viewModel = koinViewModel<HistoryViewModel>()
    val state by viewModel.collectAsState()

    // Load conversations on first composition
    LaunchedEffect(projectId) {
        viewModel.loadConversations(projectId)
    }

    // Dialog states
    var showDeleteDialog by remember { mutableStateOf<Long?>(null) }
    var showExportDialog by remember { mutableStateOf<Long?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Conversations") },
                navigationIcon = {
                    IconButton(onClick = onBackClick) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                        )
                    }
                },
            )
        },
    ) { scaffoldPadding ->
        Box(modifier = Modifier.fillMaxSize().padding(scaffoldPadding)) {
            Column(
                modifier =
                    Modifier
                        .fillMaxSize()
                        .padding(MaSpacing.md),
            ) {
                // Search bar
                HistorySearchBar(
                    query = state.searchQuery,
                    onQueryChange = { viewModel.searchConversations(it) },
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .padding(bottom = MaSpacing.md),
                )

                // Error display
                state.error?.let { error ->
                    HistoryErrorCard(
                        message = error,
                        onDismiss = { viewModel.clearError() },
                        modifier = Modifier.padding(bottom = MaSpacing.md),
                    )
                }

                // Content: Loading, Search Results, or Conversation List
                HistoryContent(
                    isLoading = state.isLoading,
                    searchResults = state.searchResults,
                    conversations = state.conversations,
                    onConversationClick = onConversationClick,
                    onDeleteClick = { showDeleteDialog = it },
                    onExportClick = { showExportDialog = it },
                    onResultClick = { result ->
                        result.conversationId?.let { onConversationClick(it) }
                    },
                )
            }

            // Delete confirmation dialog
            showDeleteDialog?.let { conversationId ->
                DeleteConfirmationDialog(
                    conversation = state.conversations.find { it.id == conversationId },
                    onConfirm = {
                        viewModel.deleteConversation(conversationId)
                        showDeleteDialog = null
                    },
                    onDismiss = { showDeleteDialog = null },
                )
            }

            // Export dialog
            showExportDialog?.let { conversationId ->
                ExportDialog(
                    conversation = state.conversations.find { it.id == conversationId },
                    onExport = { format ->
                        val exported = viewModel.exportConversation(conversationId, format)
                        // TODO: Share exported content via Android share sheet
                        println("Exported: ${exported?.take(100)}...")
                        showExportDialog = null
                    },
                    onDismiss = { showExportDialog = null },
                )
            }
        }
    }
}

/**
 * HistoryTopBar - Top app bar for history screen.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistoryTopBar(
    conversationCount: Int,
    onBackClick: () -> Unit,
) {
    TopAppBar(
        title = {
            Column {
                Text(
                    "Conversation History",
                    style = MaTypography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = MaColors.textPrimary(),
                )
                Text(
                    "$conversationCount conversations",
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
        },
        navigationIcon = {
            IconButton(onClick = onBackClick) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = MaColors.textPrimary(),
                )
            }
        },
        colors =
            TopAppBarDefaults.topAppBarColors(
                containerColor = MaterialTheme.colorScheme.background,
            ),
    )
}

/**
 * HistoryContent - Main content area showing loading, search results, or conversations.
 */
@Composable
private fun HistoryContent(
    isLoading: Boolean,
    searchResults: List<app.m1k3.ai.assistant.history.SearchResult>?,
    conversations: List<app.m1k3.ai.assistant.history.ConversationInfo>,
    onConversationClick: (Long) -> Unit,
    onDeleteClick: (Long) -> Unit,
    onExportClick: (Long) -> Unit,
    onResultClick: (app.m1k3.ai.assistant.history.SearchResult) -> Unit,
) {
    when {
        isLoading -> {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator(color = MaColors.Orange)
            }
        }

        searchResults != null -> {
            SearchResultsList(
                results = searchResults,
                onResultClick = onResultClick,
            )
        }

        else -> {
            ConversationsList(
                conversations = conversations,
                onConversationClick = onConversationClick,
                onDeleteClick = onDeleteClick,
                onExportClick = onExportClick,
            )
        }
    }
}

// ============================================================
// Previews
// ============================================================

@Preview
@Composable
private fun HistoryScreenEmptyPreview() {
    MaTheme {
        Scaffold(
            topBar = {
                HistoryTopBar(
                    conversationCount = 0,
                    onBackClick = {},
                )
            },
        ) { paddingValues ->
            Box(
                modifier =
                    Modifier
                        .fillMaxSize()
                        .padding(paddingValues),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        "📭",
                        style = MaterialTheme.typography.displayLarge,
                    )
                    Spacer(modifier = Modifier.height(16.dp))
                    Text(
                        "No conversations yet",
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
            }
        }
    }
}

@Preview
@Composable
private fun HistoryScreenLoadingPreview() {
    MaTheme {
        Scaffold(
            topBar = {
                HistoryTopBar(
                    conversationCount = 0,
                    onBackClick = {},
                )
            },
        ) { paddingValues ->
            Box(
                modifier =
                    Modifier
                        .fillMaxSize()
                        .padding(paddingValues),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator(color = MaColors.Orange)
            }
        }
    }
}

@Preview
@Composable
private fun HistoryScreenWithConversationsPreview() {
    MaTheme {
        Scaffold(
            topBar = {
                HistoryTopBar(
                    conversationCount = 3,
                    onBackClick = {},
                )
            },
        ) { paddingValues ->
            Box(
                modifier =
                    Modifier
                        .fillMaxSize()
                        .padding(paddingValues),
            ) {
                Column(
                    modifier =
                        Modifier
                            .fillMaxSize()
                            .padding(MaSpacing.md),
                ) {
                    HistorySearchBar(
                        query = "",
                        onQueryChange = {},
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .padding(bottom = MaSpacing.md),
                    )

                    Text(
                        "Showing 3 conversations",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(bottom = MaSpacing.md),
                    )
                }
            }
        }
    }
}
