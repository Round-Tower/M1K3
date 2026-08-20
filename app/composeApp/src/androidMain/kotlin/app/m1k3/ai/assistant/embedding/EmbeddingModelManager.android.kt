package app.m1k3.ai.assistant.embedding

import android.content.Context
import android.util.Log

/**
 * Embedding Model Manager - Model Selection
 *
 * Selects the embedding engine used for semantic search and RAG.
 *
 * Currently only MiniLM-L6-v2 (384 dimensions, 18MB, built-in) ships.
 * A dynamic-delivery "Embedding Gemma" tier was scaffolded via Google Play
 * split-install but never actually shipped a `:gemmaEmbedding` module — the
 * scaffolding (Play Core split-install calls + a reflective
 * `Class.forName("...gemma.GemmaEmbeddingEngine")` load, which pointed at a
 * package that never existed) was removed as dead code. [GemmaEmbeddingEngine]
 * itself lives on and is used directly by the memory subsystem
 * (see `SemanticMemoryManager`); it just isn't wired as a selectable tier here.
 */
class EmbeddingModelManager(
    private val context: Context,
) {
    companion object {
        private const val TAG = "EmbeddingModelManager"
        private const val PREFS_NAME = "embedding_preferences"
        private const val PREF_SELECTED_MODEL = "selected_model"

        const val MODEL_MINILM = "minilm"
    }

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /**
     * Get currently selected model preference
     */
    fun getSelectedModel(): String = prefs.getString(PREF_SELECTED_MODEL, MODEL_MINILM) ?: MODEL_MINILM

    /**
     * Set model preference
     */
    fun setSelectedModel(model: String) {
        prefs.edit().putString(PREF_SELECTED_MODEL, model).apply()
        Log.d(TAG, "Selected model: $model")
    }

    /**
     * Get the embedding engine to use.
     */
    fun getEmbeddingEngine(): EmbeddingEngine {
        Log.d(TAG, "Using MiniLM-L6 embedding engine (default)")
        return MiniLmEmbeddingEngine(context)
    }

    /**
     * Get model information
     */
    fun getModelInfo(model: String): ModelInfo =
        when (model) {
            MODEL_MINILM -> {
                ModelInfo(
                    id = MODEL_MINILM,
                    name = "MiniLM-L6-v2",
                    description = "Fast, excellent quality (default)",
                    dimensions = 384,
                    size = "18MB",
                    isBuiltIn = true,
                    isInstalled = true,
                    quality = ModelQuality.EXCELLENT,
                    speed = ModelSpeed.FAST,
                )
            }

            else -> {
                throw IllegalArgumentException("Unknown model: $model")
            }
        }

    /**
     * Get all available models
     */
    fun getAvailableModels(): List<ModelInfo> = listOf(getModelInfo(MODEL_MINILM))
}

/**
 * Model information
 */
data class ModelInfo(
    val id: String,
    val name: String,
    val description: String,
    val dimensions: Int,
    val size: String,
    val isBuiltIn: Boolean,
    val isInstalled: Boolean,
    val quality: ModelQuality,
    val speed: ModelSpeed,
)

enum class ModelQuality {
    GOOD,
    EXCELLENT,
    SUPERIOR,
}

enum class ModelSpeed {
    FAST,
    MEDIUM,
    SLOW,
}
