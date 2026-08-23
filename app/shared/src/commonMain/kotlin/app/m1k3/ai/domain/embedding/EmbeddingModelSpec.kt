package app.m1k3.ai.domain.embedding

/**
 * EmbeddingModelSpec — the on-device embedding model definition.
 *
 * Pure Kotlin (no platform deps) so the download URL, filename, dimensions and
 * the task-specific prompt rendering are all testable off-device. The platform
 * engine ([app.m1k3.ai.assistant.embedding.MaEmbeddingEngine]) reads the file
 * this spec names and runs it through the shared Ma/llama.cpp bridge in
 * embedding mode — the same engine and tokenizer the chat brains use, so there
 * is no second inference runtime on the device.
 *
 * ## Why EmbeddingGemma (2026-08-23)
 * The prior default (MiniLM-L3 ONNX) was never bundled in `assets/`, so RAG was
 * silently dead — every query degraded to keyword LIKE. EmbeddingGemma-300m is
 * Google's SOTA sub-500M embedder: 768-dim Matryoshka, 2048-token context, and
 * a Gemma SentencePiece tokenizer we already ship. Running it as GGUF through
 * Ma means one runtime, one tokenizer, real retrieval.
 *
 * ## Dimensions
 * We store the full 768. Rows carry their `embedding_model` id and the repo
 * filters any row whose id ≠ the live embedder, so the 384→768 change needs no
 * migration — stale MiniLM rows (if any) are simply ignored, not re-embedded.
 */
object EmbeddingModelSpec {
    /** Stable id stamped on every embedded row (the model-swap invalidation key). */
    const val MODEL_ID: String = "embeddinggemma-300m-q8_0"

    const val DISPLAY_NAME: String = "EmbeddingGemma (300M)"

    /** GGUF filename on disk (under filesDir/models), matching the HF repo file. */
    const val FILENAME: String = "embeddinggemma-300M-Q8_0.gguf"

    /** Public, no-auth HuggingFace GGUF (ggml-org conversion — llama.cpp-native). */
    const val DOWNLOAD_URL: String =
        "https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/$FILENAME"

    /** Full native width. Matryoshka would allow 512/256/128; we keep 768. */
    const val DIMENSIONS: Int = 768

    /** Context window we create for the embedding pass (model supports 2048). */
    const val CONTEXT_TOKENS: Int = 2048

    /** Q8_0 is ~318MB; guard truncated downloads well under that. */
    const val MIN_FILE_SIZE_MB: Int = 300

    /**
     * Render EmbeddingGemma's task-specific prompt around [content].
     *
     * EmbeddingGemma is trained with asymmetric prompts: a QUERY is embedded
     * differently from the DOCUMENT it should match. Using the right side of the
     * pair is worth several points of retrieval quality, so the caller's
     * [EmbeddingTaskType] picks the prompt — not an afterthought.
     *
     * The document side takes an optional [title] ("none" when absent, per the
     * model card). Query-like tasks ignore it.
     */
    fun renderPrompt(
        content: String,
        taskType: EmbeddingTaskType,
        title: String? = null,
    ): String {
        val text = content.trim()
        return when (taskType) {
            EmbeddingTaskType.QUERY ->
                "task: search result | query: $text"
            EmbeddingTaskType.CLASSIFICATION ->
                "task: classification | query: $text"
            EmbeddingTaskType.CLUSTERING ->
                "task: clustering | query: $text"
            EmbeddingTaskType.CODE ->
                "task: code retrieval | query: $text"
            // RETRIEVAL and DOCUMENT are the corpus side — the thing being stored.
            EmbeddingTaskType.RETRIEVAL, EmbeddingTaskType.DOCUMENT -> {
                val t = title?.trim().takeUnless { it.isNullOrEmpty() } ?: "none"
                "title: $t | text: $text"
            }
        }
    }
}
