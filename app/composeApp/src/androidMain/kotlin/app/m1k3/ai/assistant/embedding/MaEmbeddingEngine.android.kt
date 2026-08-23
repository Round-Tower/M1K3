package app.m1k3.ai.assistant.embedding

import android.content.Context
import app.m1k3.ai.assistant.ai.download.DownloadProgress
import app.m1k3.ai.assistant.ai.download.HttpModelDownloadManager
import app.m1k3.ai.assistant.ai.ma.MaBridge
import app.m1k3.ai.domain.embedding.EmbeddingModelSpec
import co.touchlab.kermit.Logger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * MaEmbeddingEngine — EmbeddingGemma-300m through the Ma / llama.cpp bridge.
 *
 * Replaces [MiniLmEmbeddingEngine], whose ONNX model was never bundled in
 * `assets/` — so on-device RAG was silently dead (every query degraded to
 * keyword LIKE). This engine runs Google's EmbeddingGemma as GGUF through the
 * SAME native engine and tokenizer the chat brains use: one runtime, one
 * tokenizer, real 768-dim retrieval.
 *
 * ## Model file
 * The GGUF (~318MB Q8_0) is downloaded on first load via the shared
 * [HttpModelDownloadManager] (single-flight, resume, integrity — the same path
 * the brains use) into `filesDir/models`. Until it's present, [loadModel]
 * fetches it; a caller can also pre-push it for a dev verify.
 *
 * ## Threading
 * One native context, not thread-safe per handle — [embed] serializes on a
 * [Mutex]. All native work is off the main thread (Dispatchers.IO).
 *
 * ## Vectors
 * The native side already L2-normalizes (cosine-ready), so [embed] returns the
 * vector verbatim — no second normalize pass.
 */
class MaEmbeddingEngine(
    private val context: Context,
    private val downloadManager: HttpModelDownloadManager,
) : EmbeddingEngine {
    private val logger = Logger.withTag(TAG)
    private val mutex = Mutex()

    private var handle: Long = 0L

    override val modelName: String = EmbeddingModelSpec.MODEL_ID
    override val embeddingDimensions: Int = EmbeddingModelSpec.DIMENSIONS
    override val maxTokens: Int = EmbeddingModelSpec.CONTEXT_TOKENS

    override var isLoaded: Boolean = false
        private set

    override suspend fun loadModel(): Result<Unit> =
        withContext(Dispatchers.IO) {
            mutex.withLock {
                if (isLoaded && handle != 0L) return@withContext Result.success(Unit)

                val path =
                    downloadManager.localPath(
                        EmbeddingModelSpec.FILENAME,
                        EmbeddingModelSpec.MIN_FILE_SIZE_MB,
                    ) ?: ensureDownloaded().getOrElse { return@withContext Result.failure(it) }

                val nativeLibDir = context.applicationInfo.nativeLibraryDir ?: ""
                logger.i { "Loading EmbeddingGemma: $path" }
                val h =
                    MaBridge.initEmbedding(
                        modelPath = path,
                        nCtx = EmbeddingModelSpec.CONTEXT_TOKENS,
                        nativeLibraryDir = nativeLibDir,
                        preferredCpuVariant = "",
                    )
                if (h == 0L) {
                    isLoaded = false
                    return@withContext Result.failure(
                        RuntimeException("EmbeddingGemma failed to load (file may be corrupt or incompatible)."),
                    )
                }
                handle = h
                isLoaded = true
                logger.i { "EmbeddingGemma loaded (dims=$embeddingDimensions, ctx=$maxTokens)" }
                Result.success(Unit)
            }
        }

    /**
     * Download the GGUF, blocking until Complete/Failed. Returns the local path.
     * Collected here (not exposed) so first-load is self-sufficient; a UI can
     * still drive [HttpModelDownloadManager.download] directly for progress.
     */
    private suspend fun ensureDownloaded(): Result<String> {
        var path: String? = null
        var lastError: String? = null
        downloadManager
            .download(
                id = EmbeddingModelSpec.MODEL_ID,
                displayName = EmbeddingModelSpec.DISPLAY_NAME,
                url = EmbeddingModelSpec.DOWNLOAD_URL,
                filename = EmbeddingModelSpec.FILENAME,
            ).collect { p ->
                when (p) {
                    is DownloadProgress.Complete -> path = p.filePath
                    is DownloadProgress.Failed -> lastError = p.error
                    else -> Unit
                }
            }
        return path?.let { Result.success(it) }
            ?: Result.failure(RuntimeException(lastError ?: "EmbeddingGemma download failed."))
    }

    override suspend fun unloadModel() {
        withContext(Dispatchers.IO) {
            mutex.withLock {
                if (handle != 0L) MaBridge.release(handle)
                handle = 0L
                isLoaded = false
                logger.i { "EmbeddingGemma unloaded" }
            }
        }
    }

    override suspend fun embed(
        text: String,
        taskType: EmbeddingTaskType,
    ): Result<FloatArray> =
        withContext(Dispatchers.IO) {
            if (!isLoaded || handle == 0L) {
                return@withContext Result.failure(IllegalStateException("Model not loaded. Call loadModel() first."))
            }
            if (text.isBlank()) {
                return@withContext Result.failure(IllegalArgumentException("Text cannot be blank"))
            }
            val prompt = EmbeddingModelSpec.renderPrompt(text, taskType)
            mutex.withLock {
                val vec = MaBridge.embed(handle, prompt)
                if (vec == null || vec.isEmpty()) {
                    Result.failure(RuntimeException("Embedding failed (native returned no vector)."))
                } else {
                    Result.success(vec)
                }
            }
        }

    override suspend fun embedBatch(
        texts: List<String>,
        taskType: EmbeddingTaskType,
    ): Result<List<FloatArray>> =
        withContext(Dispatchers.IO) {
            if (texts.isEmpty()) {
                return@withContext Result.failure(IllegalArgumentException("Text list cannot be empty"))
            }
            val out = ArrayList<FloatArray>(texts.size)
            for ((i, t) in texts.withIndex()) {
                val r = embed(t, taskType)
                r
                    .getOrElse { return@withContext Result.failure(it) }
                    .let(out::add)
            }
            Result.success(out)
        }

    companion object {
        private const val TAG = "MaEmbeddingEngine"
    }
}
