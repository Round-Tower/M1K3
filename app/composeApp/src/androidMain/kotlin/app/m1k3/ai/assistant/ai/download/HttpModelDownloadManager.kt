package app.m1k3.ai.assistant.ai.download

import android.content.Context
import app.m1k3.ai.domain.ai.LlmModel
import app.m1k3.ai.domain.ai.ModelDownloadManager
import co.touchlab.kermit.Logger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * HTTP-based ModelDownloadManager for downloading GGUF models.
 *
 * Downloads model files from HuggingFace to internal storage.
 * Supports progress tracking and resumable downloads.
 *
 * @param context Android context for internal storage access
 */
class HttpModelDownloadManager(
    private val context: Context,
) : ModelDownloadManager {
    private val logger = Logger.withTag("HttpModelDownloadManager")
    private val modelsDir: File get() = File(context.filesDir, "models").also { it.mkdirs() }

    override fun isModelAvailable(modelId: String): Boolean {
        val model = LlmModel.findById(modelId) ?: return false
        val file = File(modelsDir, model.filename)
        val minBytes = model.minFileSizeMb.toLong() * 1024 * 1024
        return file.exists() && file.length() >= minBytes
    }

    override fun getModelPath(modelId: String): String? {
        val model = LlmModel.findById(modelId) ?: return null
        val file = File(modelsDir, model.filename)
        return if (file.exists() && file.length() > 0) file.absolutePath else null
    }

    override fun deleteModel(modelId: String): Boolean {
        val model = LlmModel.findById(modelId) ?: return false
        val file = File(modelsDir, model.filename)
        return if (file.exists()) {
            logger.i { "Deleting model $modelId (${file.length() / 1_000_000}MB)" }
            file.delete()
        } else {
            false
        }
    }

    /**
     * Download a model from HuggingFace with progress reporting.
     *
     * @param model The LlmModel to download
     * @return Flow emitting DownloadProgress updates
     */
    fun download(model: LlmModel): Flow<DownloadProgress> =
        flow {
            val targetFile = File(modelsDir, model.filename)
            val tempFile = File(modelsDir, "${model.filename}.tmp")

            // Capture existing bytes BEFORE opening any connection
            val existingBytes = if (tempFile.exists()) tempFile.length() else 0L

            logger.i { "Downloading ${model.displayName} (already on disk: ${existingBytes / 1_000_000}MB)" }
            emit(DownloadProgress.Starting(model.id))

            try {
                val conn = followRedirects(getDownloadUrl(model), tempFile)
                val isResume = conn.responseCode == 206 && existingBytes > 0

                // For a 206 response the server sends only the remaining bytes,
                // so totalBytes = server content-length + already on disk.
                // For a 200 (server ignored Range) start fresh.
                val totalBytes = conn.contentLengthLong + if (isResume) existingBytes else 0L
                var downloadedBytes = if (isResume) existingBytes else 0L

                logger.i { "Response ${conn.responseCode}, server bytes: ${conn.contentLengthLong / 1_000_000}MB, resume: $isResume" }

                conn.inputStream.use { input ->
                    // CRITICAL: append when resuming so prior bytes are not overwritten
                    java.io.FileOutputStream(tempFile, isResume).use { output ->
                        val buf = ByteArray(65536)
                        var n: Int
                        while (input.read(buf).also { n = it } != -1) {
                            output.write(buf, 0, n)
                            downloadedBytes += n
                            val pct = if (totalBytes > 0) (downloadedBytes * 100L / totalBytes).toInt() else 0
                            emit(DownloadProgress.InProgress(model.id, downloadedBytes, totalBytes, pct))
                        }
                    }
                }

                // Validate completeness before declaring success.
                // HTTP streams can end early without an IOException — the loop exits
                // normally but the file is truncated. Check we got ≥99% of expected bytes.
                val actualBytes = tempFile.length()
                if (totalBytes > 0 && actualBytes < totalBytes * 99 / 100) {
                    logger.e { "Truncated download: got ${actualBytes / 1_000_000}MB of ${totalBytes / 1_000_000}MB" }
                    // Keep as .tmp so next attempt resumes from this point
                    emit(
                        DownloadProgress.Failed(
                            model.id,
                            "Download incomplete (${actualBytes / 1_000_000}MB of ${totalBytes / 1_000_000}MB). Tap retry to resume.",
                        ),
                    )
                    return@flow
                }

                tempFile.renameTo(targetFile)
                logger.i { "Download complete: ${targetFile.length() / 1_000_000}MB" }
                emit(DownloadProgress.Complete(model.id, targetFile.absolutePath))
            } catch (e: Exception) {
                logger.e(e) { "Download failed: ${e.message}" }
                emit(DownloadProgress.Failed(model.id, e.message ?: "Download failed"))
            }
        }.flowOn(Dispatchers.IO)

    /**
     * Follow HTTP redirects manually, including cross-host redirects.
     *
     * Java's HttpURLConnection.instanceFollowRedirects does NOT follow
     * redirects across different hosts (e.g., huggingface.co → xethub.hf.co).
     * HuggingFace uses cross-host 302s to CDN, so we handle it manually.
     */
    private fun followRedirects(
        initialUrl: String,
        tempFile: File,
        maxRedirects: Int = 5,
    ): HttpURLConnection {
        var url = initialUrl
        var redirectCount = 0

        while (redirectCount < maxRedirects) {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 30_000
            connection.readTimeout = 60_000
            connection.instanceFollowRedirects = false // We handle redirects ourselves

            // Support resume
            if (tempFile.exists() && tempFile.length() > 0) {
                connection.setRequestProperty("Range", "bytes=${tempFile.length()}-")
            }

            connection.connect()
            val responseCode = connection.responseCode

            if (responseCode in 300..399) {
                val location = connection.getHeaderField("Location")
                connection.disconnect()

                if (location == null) {
                    throw java.io.IOException("Redirect without Location header")
                }

                logger.d { "Following redirect ($responseCode) → ${location.take(80)}..." }
                url = location
                redirectCount++
            } else if (responseCode in 200..299) {
                logger.i { "Connected: $responseCode, content-length: ${connection.contentLengthLong}" }
                return connection
            } else {
                connection.disconnect()
                throw java.io.IOException("HTTP $responseCode: ${connection.responseMessage}")
            }
        }

        throw java.io.IOException("Too many redirects ($maxRedirects)")
    }

    /**
     * Get the HuggingFace download URL for a model.
     */
    private fun getDownloadUrl(model: LlmModel): String =
        when (model) {
            // Active tiers — public, no HuggingFace auth required
            is LlmModel.Qwen35_0B8 -> {
                "https://huggingface.co/bartowski/Qwen_Qwen3.5-0.8B-GGUF/resolve/main/${model.filename}"
            }

            is LlmModel.Qwen3_0B6 -> {
                "https://huggingface.co/bartowski/Qwen_Qwen3-0.6B-GGUF/resolve/main/${model.filename}"
            }

            is LlmModel.Qwen35_2B -> {
                "https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF/resolve/main/${model.filename}"
            }

            is LlmModel.Qwen3_1B7 -> {
                "https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/${model.filename}"
            }

            is LlmModel.Gemma4_E2B -> {
                "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/${model.filename}"
            }

            // Superseded — kept for reference, still downloadable
            is LlmModel.Qwen25_1B5 -> {
                "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/${model.filename}"
            }

            is LlmModel.SmolLM2_360M -> {
                "https://huggingface.co/bartowski/SmolLM2-360M-Instruct-GGUF/resolve/main/${model.filename}"
            }

            // Legacy — Gemma 3 requires HF auth (401 without token)
            is LlmModel.Gemma3_270M -> {
                "https://huggingface.co/bartowski/gemma-3-270m-it-GGUF/resolve/main/${model.filename}"
            }

            is LlmModel.Gemma3_1B -> {
                "https://huggingface.co/bartowski/gemma-3-1b-it-GGUF/resolve/main/${model.filename}"
            }

            else -> {
                "https://huggingface.co/models/${model.filename}"
            }
        }
}

/**
 * Download progress state.
 */
sealed class DownloadProgress {
    abstract val modelId: String

    data class Starting(
        override val modelId: String,
    ) : DownloadProgress()

    data class InProgress(
        override val modelId: String,
        val bytesDownloaded: Long,
        val totalBytes: Long,
        val progressPercent: Int,
    ) : DownloadProgress()

    data class Complete(
        override val modelId: String,
        val filePath: String,
    ) : DownloadProgress()

    data class Failed(
        override val modelId: String,
        val error: String,
    ) : DownloadProgress()
}
