package app.m1k3.ai.assistant.memory

import app.m1k3.ai.assistant.database.MemoryMetadata
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * MemoriesViewModel — state for the Memories screen: a live fact count and a
 * search-on-submit lookup over what M1K3 remembers, all on device.
 *
 * Search is TEXT search ([MemoryDataSource.searchMemoriesByContent]), not
 * semantic. [MemoryManager]'s semantic retrieval needs an EmbeddingRepository
 * + VectorSearchRepository, both wired per-conversation inside
 * ChatScreenViewModel's Koin factory. Memories is a standalone workspace room
 * with no conversation context to borrow those from, so this takes the
 * documented fallback path rather than manufacture a second embedder wiring
 * just for a read-only search screen.
 *
 * Pure Kotlin — takes a [CoroutineScope] rather than owning one, same shape as
 * [app.m1k3.ai.assistant.passages.DocumentsViewModel], so tests can inject a
 * [kotlinx.coroutines.test.TestScope] and Compose hosts can supply the
 * composition scope.
 */
class MemoriesViewModel(
    private val dataSource: MemoryDataSource,
    private val projectId: String,
    private val scope: CoroutineScope,
) {
    private val _state = MutableStateFlow(MemoriesUiState())
    val state: StateFlow<MemoriesUiState> = _state.asStateFlow()

    /** Loads the live memory count. Safe to call more than once (refresh). */
    fun load() {
        scope.launch {
            val count = dataSource.getMemoryCount(projectId)
            _state.update { it.copy(liveCount = count) }
        }
    }

    /**
     * Updates the in-progress query text WITHOUT searching — search only runs
     * on [submitSearch] (search-on-submit, not live-as-you-type). Clearing the
     * field back to blank also clears any stale results immediately.
     */
    fun updateQuery(text: String) {
        _state.update { it.copy(query = text) }
        if (text.isBlank()) {
            _state.update { it.copy(results = emptyList(), isSearching = false) }
        }
    }

    /** Runs the search for the current query. A blank query is a no-op (already cleared). */
    fun submitSearch() {
        val query = _state.value.query.trim()
        if (query.isEmpty()) {
            _state.update { it.copy(results = emptyList(), isSearching = false) }
            return
        }
        scope.launch {
            _state.update { it.copy(isSearching = true) }
            val hits = dataSource.searchMemoriesByContent(projectId, query)
            _state.update { it.copy(results = hits, isSearching = false) }
        }
    }
}

/**
 * UI state for [MemoriesViewModel].
 */
data class MemoriesUiState(
    val query: String = "",
    val liveCount: Long = 0,
    val results: List<MemoryMetadata> = emptyList(),
    val isSearching: Boolean = false,
) {
    /** True once the user has typed a non-blank query — gates the "no results" empty state. */
    val hasQuery: Boolean get() = query.isNotBlank()
}
