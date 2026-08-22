package app.m1k3.ai.assistant.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.database.MemoryMetadata
import app.m1k3.ai.assistant.memory.MemoriesViewModel
import app.m1k3.ai.assistant.memory.MemoryDataSource
import kotlin.time.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import org.koin.compose.koinInject

/**
 * MemoriesScreen — search what M1K3 remembers, on device.
 *
 * Read-only for v1 (no delete) — capture happens through chat auto-distillation,
 * not a form here. Matches the shape of the iOS/visionOS MemoriesScreen: a live
 * fact count, a search-on-submit lookup, and rows of memory text over a caption.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MemoriesScreen(
    onBack: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val dataSource: MemoryDataSource = koinInject()
    val scope = rememberCoroutineScope()
    val viewModel = remember { MemoriesViewModel(dataSource, "default", scope) }
    val state by viewModel.state.collectAsState()
    val focusManager = LocalFocusManager.current

    LaunchedEffect(Unit) { viewModel.load() }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Memories") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { scaffoldPadding ->
        Column(
            modifier =
                Modifier
                    .fillMaxSize()
                    .padding(scaffoldPadding),
        ) {
            OutlinedTextField(
                value = state.query,
                onValueChange = viewModel::updateQuery,
                label = { Text("Recall a memory") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions =
                    KeyboardActions(
                        onSearch = {
                            viewModel.submitSearch()
                            focusManager.clearFocus()
                        },
                    ),
                modifier = Modifier.fillMaxWidth().padding(16.dp),
            )

            when {
                !state.hasQuery && state.liveCount == 0L -> {
                    EmptyMessage(
                        "Nothing here yet — memories build up as you chat, all on your device.",
                    )
                }

                !state.hasQuery -> {
                    EmptyMessage("Search what M1K3 remembers — all on your device.")
                }

                state.results.isEmpty() && !state.isSearching -> {
                    EmptyMessage("No memories match \"${state.query}\".")
                }

                else -> {
                    LazyColumn(modifier = Modifier.fillMaxSize()) {
                        items(state.results, key = { it.id }) { memory ->
                            MemoryRow(memory)
                            HorizontalDivider()
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MemoryRow(memory: MemoryMetadata) {
    ListItem(
        headlineContent = { Text(memory.content) },
        supportingContent = { Text(formatLearnedOn(memory.created_at)) },
    )
}

@Composable
private fun EmptyMessage(text: String) {
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private fun formatLearnedOn(epochMillis: Long): String {
    if (epochMillis <= 0L) return "—"
    val dt = Instant.fromEpochMilliseconds(epochMillis).toLocalDateTime(TimeZone.currentSystemDefault())
    return "Learned ${dt.year}-${dt.monthNumber.pad()}-${dt.dayOfMonth.pad()}"
}

private fun Int.pad(): String = toString().padStart(2, '0')
