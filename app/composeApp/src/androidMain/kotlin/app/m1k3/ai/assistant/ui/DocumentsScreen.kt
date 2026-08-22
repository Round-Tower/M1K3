package app.m1k3.ai.assistant.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.passages.DocumentsUiState
import app.m1k3.ai.assistant.passages.DocumentsViewModel
import app.m1k3.ai.assistant.ui.passages.ImportNoteDialog
import app.m1k3.ai.domain.passages.Source
import app.m1k3.ai.domain.passages.SourceKind
import app.m1k3.ai.domain.passages.repositories.PassageRepository
import app.m1k3.ai.domain.passages.usecases.ImportTextUseCase
import kotlinx.coroutines.launch
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import org.koin.compose.koinInject
import java.io.BufferedReader
import java.io.InputStreamReader
import androidx.compose.runtime.collectAsState as composeCollectAsState

/**
 * DocumentsScreen — list + manage user-imported notes and documents.
 *
 * Entry point for the personal-knowledge loop: import (paste or file pick),
 * browse existing sources, delete. What the user imports here is what the
 * chat's passage retrieval surfaces on the next turn.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun DocumentsScreen(
    onBack: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val importUseCase: ImportTextUseCase = koinInject()
    val repository: PassageRepository = koinInject()
    val scope = rememberCoroutineScope()
    val viewModel =
        remember {
            DocumentsViewModel(importUseCase, repository, scope)
        }
    val state by viewModel.state.composeCollectAsState()

    LaunchedEffect(Unit) { viewModel.load() }

    var showImportDialog by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf<Source?>(null) }
    val context = LocalContext.current

    val filePicker =
        rememberLauncherForActivityResult(
            contract = ActivityResultContracts.OpenDocument(),
        ) { uri: Uri? ->
            if (uri == null) return@rememberLauncherForActivityResult
            scope.launch {
                val (title, content, kind) = readTextFile(context, uri)
                if (content.isNotBlank()) {
                    viewModel.import(title, content, kind)
                }
            }
        }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Documents", fontWeight = FontWeight.Medium) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back")
                    }
                },
                colors =
                    TopAppBarDefaults.topAppBarColors(
                        containerColor = MaColors.bgPrimary(),
                    ),
            )
        },
        floatingActionButton = {
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                FloatingActionButton(
                    onClick = {
                        filePicker.launch(
                            arrayOf("text/plain", "text/markdown", "text/*"),
                        )
                    },
                    containerColor = MaColors.bgSecondary(),
                    contentColor = MaColors.textPrimary(),
                ) {
                    Icon(Icons.Default.UploadFile, contentDescription = "Pick file")
                }
                ExtendedFloatingActionButton(
                    onClick = { showImportDialog = true },
                    icon = { Icon(Icons.Default.Add, contentDescription = null) },
                    text = { Text("Paste note") },
                )
            }
        },
        containerColor = MaColors.bgPrimary(),
        modifier = modifier,
    ) { inner ->
        Box(
            modifier =
                Modifier
                    .fillMaxSize()
                    .padding(inner),
        ) {
            when {
                state.isEmpty -> {
                    EmptyState(Modifier.align(Alignment.Center))
                }

                else -> {
                    SourceList(
                        state = state,
                        onDelete = { source -> pendingDelete = source },
                    )
                }
            }
        }
    }

    pendingDelete?.let { source ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { androidx.compose.material3.Text("Delete \"${source.title}\"?") },
            text = {
                androidx.compose.material3.Text(
                    "This removes ${source.chunkCount} passage${if (source.chunkCount == 1) "" else "s"} from your personal knowledge. It cannot be undone.",
                )
            },
            confirmButton = {
                androidx.compose.material3.TextButton(
                    onClick = {
                        viewModel.delete(source.id)
                        pendingDelete = null
                    },
                ) {
                    androidx.compose.material3.Text(
                        "Delete",
                        color = androidx.compose.material3.MaterialTheme.colorScheme.error,
                    )
                }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { pendingDelete = null }) {
                    androidx.compose.material3.Text("Cancel")
                }
            },
        )
    }

    if (showImportDialog) {
        ImportNoteDialog(
            onDismiss = { showImportDialog = false },
            onFinished = { result ->
                result.onSuccess { viewModel.load() }
                result.onFailure { /* ImportTextUseCase already logged; VM error flow covers future cases */ }
            },
        )
    }
}

@Composable
private fun EmptyState(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            Icons.Default.Book,
            contentDescription = null,
            tint = MaColors.textSecondary(),
            modifier = Modifier.size(56.dp),
        )
        Text(
            "No documents yet",
            color = MaColors.textPrimary(),
            fontWeight = FontWeight.Medium,
        )
        Text(
            "Paste a note or pick a text/markdown file to ground replies in your own knowledge.",
            color = MaColors.textSecondary(),
        )
    }
}

@Composable
private fun SourceList(
    state: DocumentsUiState,
    onDelete: (Source) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding =
            androidx.compose.foundation.layout.PaddingValues(
                horizontal = MaSpacing.base,
                vertical = MaSpacing.sm,
            ),
        verticalArrangement = Arrangement.spacedBy(MaSpacing.sm),
    ) {
        items(items = state.sources, key = Source::id) { source ->
            SourceRow(source = source, onDelete = { onDelete(source) })
        }
        item { Spacer(Modifier.height(96.dp)) } // FAB clearance
    }
}

@Composable
private fun SourceRow(
    source: Source,
    onDelete: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(MaColors.bgSecondary())
                .padding(horizontal = MaSpacing.base, vertical = MaSpacing.sm),
    ) {
        Icon(
            Icons.Default.Book,
            contentDescription = null,
            tint = MaColors.textSecondary(),
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.size(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                source.title,
                color = MaColors.textPrimary(),
                fontWeight = FontWeight.Medium,
                maxLines = 1,
            )
            Text(
                "${source.kind.name.lowercase()} · ${source.chunkCount} passage${if (source.chunkCount == 1) "" else "s"} · ${formatImported(
                    source.importedAt,
                )}",
                color = MaColors.textSecondary(),
                maxLines = 1,
            )
        }
        IconButton(onClick = onDelete) {
            Icon(
                Icons.Default.Delete,
                contentDescription = "Delete ${source.title}",
                tint = MaColors.textSecondary(),
            )
        }
    }
}

private fun formatImported(epochMillis: Long): String {
    if (epochMillis <= 0L) return "—"
    val dt = Instant.fromEpochMilliseconds(epochMillis).toLocalDateTime(TimeZone.currentSystemDefault())
    return "${dt.year}-${dt.monthNumber.pad()}-${dt.dayOfMonth.pad()}"
}

private fun Int.pad(): String = toString().padStart(2, '0')

/**
 * Read the user-picked content URI as text. Best-effort MIME detection:
 * falls back to PLAIN_TEXT if the provider doesn't advertise a type.
 */
private fun readTextFile(
    context: android.content.Context,
    uri: Uri,
): Triple<String, String, SourceKind> {
    val resolver = context.contentResolver
    val mime = resolver.getType(uri).orEmpty().lowercase()
    val kind =
        if (mime.contains("markdown") || uri.lastPathSegment?.endsWith(".md", ignoreCase = true) == true) {
            SourceKind.MARKDOWN
        } else {
            SourceKind.TEXT
        }
    val content =
        resolver
            .openInputStream(uri)
            ?.use { stream ->
                BufferedReader(InputStreamReader(stream, Charsets.UTF_8)).use { it.readText() }
            }.orEmpty()
    val title =
        uri.lastPathSegment
            ?.substringAfterLast('/')
            ?.substringBeforeLast('.')
            ?.takeIf { it.isNotBlank() }
            ?: "Imported file"
    return Triple(title, content, kind)
}
