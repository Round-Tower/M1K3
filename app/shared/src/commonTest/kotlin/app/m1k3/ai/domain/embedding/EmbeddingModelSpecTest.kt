package app.m1k3.ai.domain.embedding

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * EmbeddingGemma is trained on asymmetric prompts — the query side and the
 * document side render differently, and using the wrong one silently costs
 * retrieval quality. These pin the prompt shapes to the model card so a refactor
 * can't quietly drop the "task:"/"title:" framing that makes the model work.
 */
class EmbeddingModelSpecTest {
    @Test
    fun `query uses the search-result task prompt`() {
        assertEquals(
            "task: search result | query: where do I live",
            EmbeddingModelSpec.renderPrompt("where do I live", EmbeddingTaskType.QUERY),
        )
    }

    @Test
    fun `retrieval renders the document side with a none title when absent`() {
        assertEquals(
            "title: none | text: Kev lives in Ardmore.",
            EmbeddingModelSpec.renderPrompt("Kev lives in Ardmore.", EmbeddingTaskType.RETRIEVAL),
        )
    }

    @Test
    fun `document title is used when provided`() {
        assertEquals(
            "title: Bio | text: Kev lives in Ardmore.",
            EmbeddingModelSpec.renderPrompt(
                "Kev lives in Ardmore.",
                EmbeddingTaskType.DOCUMENT,
                title = "Bio",
            ),
        )
    }

    @Test
    fun `blank title falls back to none`() {
        assertEquals(
            "title: none | text: hi",
            EmbeddingModelSpec.renderPrompt("hi", EmbeddingTaskType.DOCUMENT, title = "   "),
        )
    }

    @Test
    fun `content is trimmed so prompt framing stays clean`() {
        assertEquals(
            "task: search result | query: hello",
            EmbeddingModelSpec.renderPrompt("  hello  ", EmbeddingTaskType.QUERY),
        )
    }

    @Test
    fun `classification clustering and code each get their own task`() {
        assertTrue(
            EmbeddingModelSpec.renderPrompt("x", EmbeddingTaskType.CLASSIFICATION)
                .startsWith("task: classification |"),
        )
        assertTrue(
            EmbeddingModelSpec.renderPrompt("x", EmbeddingTaskType.CLUSTERING)
                .startsWith("task: clustering |"),
        )
        assertTrue(
            EmbeddingModelSpec.renderPrompt("x", EmbeddingTaskType.CODE)
                .startsWith("task: code retrieval |"),
        )
    }

    @Test
    fun `spec constants match the shipped GGUF`() {
        // The filename must be the last path segment of the URL, or download
        // writes one name and load looks for another (the RAG-dead failure mode).
        assertTrue(EmbeddingModelSpec.DOWNLOAD_URL.endsWith(EmbeddingModelSpec.FILENAME))
        assertEquals(768, EmbeddingModelSpec.DIMENSIONS)
        assertTrue(EmbeddingModelSpec.MIN_FILE_SIZE_MB in 200..318)
    }
}
