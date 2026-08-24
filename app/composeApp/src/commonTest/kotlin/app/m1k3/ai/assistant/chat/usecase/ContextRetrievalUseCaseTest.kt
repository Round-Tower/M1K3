package app.m1k3.ai.assistant.chat.usecase

import app.m1k3.ai.assistant.config.GenerationConstants
import app.m1k3.ai.assistant.mocks.MockDeviceInfoProvider
import app.m1k3.ai.assistant.mocks.TestPreferencesStore
import app.m1k3.ai.assistant.platform.PreferenceKeys
import app.m1k3.ai.domain.chat.EnrichedContext
import app.m1k3.ai.domain.passages.Passage
import app.m1k3.ai.domain.passages.Source
import app.m1k3.ai.domain.passages.repositories.PassageRepository
import app.m1k3.ai.domain.passages.usecases.RetrievePassagesUseCase
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Tests for ContextRetrievalUseCase.
 *
 * Tests context retrieval behavior with various configurations.
 * Integration with RAGManager/MemoryManager tested separately.
 */
class ContextRetrievalUseCaseTest {
    // ===== EnrichedContext Tests =====

    @Test
    fun `EnrichedContext hasContext returns true when hasRagContext is true`() {
        val context =
            EnrichedContext(
                context = "Some context",
                intentCategory = "SCIENCE",
                ragInfo = null,
                ragSources = null,
                ragConfidence = null,
                hasRagContext = true,
                hasMemoryContext = false,
            )
        assertTrue(context.hasContext)
    }

    @Test
    fun `EnrichedContext hasContext returns true when hasMemoryContext is true`() {
        val context =
            EnrichedContext(
                context = "Some context",
                intentCategory = "GENERAL",
                ragInfo = null,
                ragSources = null,
                ragConfidence = null,
                hasRagContext = false,
                hasMemoryContext = true,
            )
        assertTrue(context.hasContext)
    }

    @Test
    fun `EnrichedContext hasContext returns false when no context retrieved`() {
        val context =
            EnrichedContext(
                context = "",
                intentCategory = "GENERAL",
                ragInfo = null,
                ragSources = null,
                ragConfidence = null,
                hasRagContext = false,
                hasMemoryContext = false,
            )
        assertFalse(context.hasContext)
    }

    @Test
    fun `EnrichedContext isEmpty returns true for empty context`() {
        val context =
            EnrichedContext(
                context = "",
                intentCategory = "GENERAL",
                ragInfo = null,
                ragSources = null,
                ragConfidence = null,
                hasRagContext = false,
                hasMemoryContext = false,
            )
        assertTrue(context.isEmpty)
    }

    @Test
    fun `EnrichedContext isEmpty returns false for non-empty context`() {
        val context =
            EnrichedContext(
                context = "Some content",
                intentCategory = "SCIENCE",
                ragInfo = null,
                ragSources = null,
                ragConfidence = null,
                hasRagContext = true,
                hasMemoryContext = false,
            )
        assertFalse(context.isEmpty)
    }

    // ===== Use Case Preference Tests =====

    @Test
    fun `isRagEnabled returns true by default`() {
        // On-device grounding is the product; it defaults ON (was off only
        // while the embedder was unbundled and RAG was dead — 2026-08-23).
        val useCase =
            ContextRetrievalUseCase(
                deviceInfo = MockDeviceInfoProvider.midRange(),
                preferences = TestPreferencesStore(),
            )
        assertTrue(useCase.isRagEnabled())
    }

    @Test
    fun `isRagEnabled returns false when disabled in preferences`() {
        val prefs = TestPreferencesStore()
        prefs.setBoolean(PreferenceKeys.RAG_ENABLED, false)

        val useCase =
            ContextRetrievalUseCase(
                deviceInfo = MockDeviceInfoProvider.midRange(),
                preferences = prefs,
            )
        assertFalse(useCase.isRagEnabled())
    }

    @Test
    fun `isRagEnabled returns true when enabled in preferences`() {
        val prefs = TestPreferencesStore()
        prefs.setBoolean(PreferenceKeys.RAG_ENABLED, true)

        val useCase =
            ContextRetrievalUseCase(
                deviceInfo = MockDeviceInfoProvider.midRange(),
                preferences = prefs,
            )
        assertTrue(useCase.isRagEnabled())
    }

    // ===== Device-Adaptive Tests =====

    @Test
    fun `getMemoryTopK returns FLAGSHIP value for flagship device`() {
        val useCase =
            ContextRetrievalUseCase(
                deviceInfo = MockDeviceInfoProvider.flagship(),
                preferences = TestPreferencesStore(),
            )
        assertEquals(GenerationConstants.MemoryTopK.FLAGSHIP, useCase.getMemoryTopK())
    }

    @Test
    fun `getMemoryTopK returns HIGH_END value for high-end device`() {
        val useCase =
            ContextRetrievalUseCase(
                deviceInfo = MockDeviceInfoProvider.highEnd(),
                preferences = TestPreferencesStore(),
            )
        assertEquals(GenerationConstants.MemoryTopK.HIGH_END, useCase.getMemoryTopK())
    }

    @Test
    fun `getMemoryTopK returns MID_RANGE value for mid-range device`() {
        val useCase =
            ContextRetrievalUseCase(
                deviceInfo = MockDeviceInfoProvider.midRange(),
                preferences = TestPreferencesStore(),
            )
        assertEquals(GenerationConstants.MemoryTopK.MID_RANGE, useCase.getMemoryTopK())
    }

    @Test
    fun `getMemoryTopK returns BUDGET value for budget device`() {
        val useCase =
            ContextRetrievalUseCase(
                deviceInfo = MockDeviceInfoProvider.budget(),
                preferences = TestPreferencesStore(),
            )
        assertEquals(GenerationConstants.MemoryTopK.BUDGET, useCase.getMemoryTopK())
    }

    // ===== Context Retrieval Tests (without managers) =====

    @Test
    fun `retrieveContext returns empty context when no managers available`() =
        runTest {
            val useCase =
                ContextRetrievalUseCase(
                    deviceInfo = MockDeviceInfoProvider.midRange(),
                    preferences = TestPreferencesStore(),
                    memoryManager = null,
                )

            val result = useCase.retrieveContext("What is photosynthesis?")

            assertTrue(result.isEmpty)
            // Intent is now classified even when RAG is not available
            assertEquals("Science Facts", result.intentCategory)
            assertFalse(result.hasRagContext)
            assertFalse(result.hasMemoryContext)
            assertNull(result.ragInfo)
            assertNull(result.ragSources)
            assertNull(result.ragConfidence)
        }

    @Test
    fun `retrieveContext returns empty context when RAG disabled`() =
        runTest {
            val prefs = TestPreferencesStore()
            prefs.setBoolean(PreferenceKeys.RAG_ENABLED, false)

            val useCase =
                ContextRetrievalUseCase(
                    deviceInfo = MockDeviceInfoProvider.midRange(),
                    preferences = prefs,
                    memoryManager = null,
                )

            val result = useCase.retrieveContext("Test query")

            assertTrue(result.isEmpty)
            assertFalse(result.hasRagContext)
        }

    @Test
    fun `retrieveContext classifies conversational intent correctly`() =
        runTest {
            val useCase =
                ContextRetrievalUseCase(
                    deviceInfo = MockDeviceInfoProvider.midRange(),
                    preferences = TestPreferencesStore(),
                )

            val result = useCase.retrieveContext("Hello")

            // "Hello" is classified as CONVERSATIONAL, not GENERAL
            assertEquals("Casual Conversation", result.intentCategory)
        }

    // ===== EnrichedContext Field Validation Tests =====

    @Test
    fun `EnrichedContext stores all provided values`() {
        val context =
            EnrichedContext(
                context = "Test context",
                intentCategory = "CODE_DEBUG",
                ragInfo = "✅ CODE_DEBUG (80%) • 2 facts",
                ragSources = "source1; source2",
                ragConfidence = 0.8,
                hasRagContext = true,
                hasMemoryContext = true,
            )

        assertEquals("Test context", context.context)
        assertEquals("CODE_DEBUG", context.intentCategory)
        assertEquals("✅ CODE_DEBUG (80%) • 2 facts", context.ragInfo)
        assertEquals("source1; source2", context.ragSources)
        assertEquals(0.8, context.ragConfidence)
        assertTrue(context.hasRagContext)
        assertTrue(context.hasMemoryContext)
        assertTrue(context.hasContext)
        assertFalse(context.isEmpty)
    }

    @Test
    fun `EnrichedContext handles null optional values`() {
        val context =
            EnrichedContext(
                context = "",
                intentCategory = "GENERAL",
                ragInfo = null,
                ragSources = null,
                ragConfidence = null,
                hasRagContext = false,
                hasMemoryContext = false,
            )

        assertNull(context.ragInfo)
        assertNull(context.ragSources)
        assertNull(context.ragConfidence)
    }

    // ===== Memory TopK Scaling Tests =====

    @Test
    fun `getMemoryTopK scales correctly across device tiers`() {
        val flagship =
            ContextRetrievalUseCase(
                deviceInfo = MockDeviceInfoProvider.flagship(),
                preferences = TestPreferencesStore(),
            ).getMemoryTopK()

        val highEnd =
            ContextRetrievalUseCase(
                deviceInfo = MockDeviceInfoProvider.highEnd(),
                preferences = TestPreferencesStore(),
            ).getMemoryTopK()

        val midRange =
            ContextRetrievalUseCase(
                deviceInfo = MockDeviceInfoProvider.midRange(),
                preferences = TestPreferencesStore(),
            ).getMemoryTopK()

        val budget =
            ContextRetrievalUseCase(
                deviceInfo = MockDeviceInfoProvider.budget(),
                preferences = TestPreferencesStore(),
            ).getMemoryTopK()

        assertTrue(flagship > highEnd, "Flagship should have higher topK than high-end")
        assertTrue(highEnd > midRange, "High-end should have higher topK than mid-range")
        assertTrue(midRange > budget, "Mid-range should have higher topK than budget")
    }

    // ===== Passage Retrieval Tests =====

    private class StubPassageRepo(
        private val fixed: List<Passage>,
        private val throwOnSearch: Throwable? = null,
    ) : PassageRepository {
        override suspend fun saveSource(
            source: Source,
            passages: List<Passage>,
        ): Result<Unit> = Result.success(Unit)

        override suspend fun getSource(id: String): Source? = null

        override suspend fun getAllSources(): List<Source> = emptyList()

        override suspend fun deleteSource(id: String): Result<Unit> = Result.success(Unit)

        override suspend fun getPassages(sourceId: String): List<Passage> = emptyList()

        override suspend fun searchPassages(
            query: String,
            limit: Int,
        ): List<Passage> {
            throwOnSearch?.let { throw it }
            return if (query.isBlank() || limit <= 0) emptyList() else fixed.take(limit)
        }
    }

    private fun passage(
        id: String,
        sourceId: String,
        content: String,
        sequence: Int = 0,
        total: Int = 1,
    ) = Passage(
        id = id,
        sourceId = sourceId,
        sequence = sequence,
        content = content,
        tokenCount = content.length / 4,
        totalPassagesInSource = total,
    )

    @Test
    fun `retrieveContext uses passage retriever when RAG enabled`() =
        runTest {
            val prefs = TestPreferencesStore().apply { setBoolean(PreferenceKeys.RAG_ENABLED, true) }
            val repo =
                StubPassageRepo(
                    listOf(
                        passage("p0", "src-a", "Photosynthesis converts light to chemical energy."),
                        passage("p1", "src-a", "Chloroplasts are the organelles responsible.", sequence = 1, total = 2),
                    ),
                )
            val useCase =
                ContextRetrievalUseCase(
                    deviceInfo = MockDeviceInfoProvider.midRange(),
                    preferences = prefs,
                    passageRetriever = RetrievePassagesUseCase(repo),
                )

            val result = useCase.retrieveContext("What is photosynthesis?")

            assertTrue(result.hasRagContext, "Passage retriever should populate ragContext")
            assertTrue(result.context.contains("Photosynthesis"))
            assertTrue(result.context.contains("Chloroplasts"))
            assertNotNull(result.ragInfo)
            assertEquals("src-a", result.ragSources)
        }

    @Test
    fun `retrieveContext skips passage retriever when RAG disabled`() =
        runTest {
            val prefs = TestPreferencesStore().apply { setBoolean(PreferenceKeys.RAG_ENABLED, false) }
            val repo = StubPassageRepo(listOf(passage("p0", "src-a", "ignored content")))
            val useCase =
                ContextRetrievalUseCase(
                    deviceInfo = MockDeviceInfoProvider.midRange(),
                    preferences = prefs,
                    passageRetriever = RetrievePassagesUseCase(repo),
                )

            val result = useCase.retrieveContext("What is photosynthesis?")

            assertFalse(result.hasRagContext)
            assertNull(result.ragInfo)
        }

    @Test
    fun `retrieveContext grounds in documents by DEFAULT (RAG on out of the box)`() =
        runTest {
            // Grounding in the user's own documents is 100% on-device, so it is
            // ON by default — the killer feature must not hide behind a toggle
            // (the old default-off dated to when the embedder was never bundled
            // and RAG was dead). A fresh store sets nothing; retrieval must run.
            val prefs = TestPreferencesStore() // RAG_ENABLED unset → default
            val repo = StubPassageRepo(listOf(passage("p0", "src-a", "relevant content about photosynthesis")))
            val useCase =
                ContextRetrievalUseCase(
                    deviceInfo = MockDeviceInfoProvider.midRange(),
                    preferences = prefs,
                    passageRetriever = RetrievePassagesUseCase(repo),
                )

            val result = useCase.retrieveContext("What is photosynthesis?")

            assertTrue(result.hasRagContext, "RAG must ground by default with no pref set")
        }

    @Test
    fun `retrieveContext returns empty rag context when passage search yields nothing`() =
        runTest {
            val prefs = TestPreferencesStore().apply { setBoolean(PreferenceKeys.RAG_ENABLED, true) }
            val useCase =
                ContextRetrievalUseCase(
                    deviceInfo = MockDeviceInfoProvider.midRange(),
                    preferences = prefs,
                    passageRetriever = RetrievePassagesUseCase(StubPassageRepo(emptyList())),
                )

            val result = useCase.retrieveContext("What is photosynthesis?")

            assertFalse(result.hasRagContext)
            assertNull(result.ragInfo)
            assertNull(result.ragSources)
        }

    @Test
    fun `retrieveContext captures passage retrieval error instead of swallowing it`() =
        runTest {
            val prefs = TestPreferencesStore().apply { setBoolean(PreferenceKeys.RAG_ENABLED, true) }
            val repo = StubPassageRepo(fixed = emptyList(), throwOnSearch = RuntimeException("storage corrupt"))
            val useCase =
                ContextRetrievalUseCase(
                    deviceInfo = MockDeviceInfoProvider.midRange(),
                    preferences = prefs,
                    passageRetriever = RetrievePassagesUseCase(repo),
                )

            val result = useCase.retrieveContext("What is photosynthesis?")

            assertFalse(result.hasRagContext, "Failure still yields empty rag context so chat can continue")
            assertTrue(result.hasRetrievalErrors, "Error must be surfaced, not swallowed")
            assertTrue(
                result.retrievalErrors.any { it.startsWith("passages:") && it.contains("storage corrupt") },
                "Expected passages error diagnostic, got ${result.retrievalErrors}",
            )
        }

    @Test
    fun `retrieveContext skips passage retriever for conversational intent`() =
        runTest {
            val prefs = TestPreferencesStore().apply { setBoolean(PreferenceKeys.RAG_ENABLED, true) }
            val repo = StubPassageRepo(listOf(passage("p0", "src-a", "should not leak")))
            val useCase =
                ContextRetrievalUseCase(
                    deviceInfo = MockDeviceInfoProvider.midRange(),
                    preferences = prefs,
                    passageRetriever = RetrievePassagesUseCase(repo),
                )

            val result = useCase.retrieveContext("hello")

            assertFalse(result.hasRagContext, "Conversational intent should bypass retrieval")
        }
}
