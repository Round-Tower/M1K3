package app.m1k3.ai.domain.rag.services

import app.m1k3.ai.domain.rag.Intent

/**
 * M1K3 - Intent Classifier
 *
 * Classifies user queries into knowledge categories for intelligent
 * RAG retrieval. Uses keyword matching and pattern detection.
 *
 * Domain service - Pure Kotlin, no platform dependencies.
 *
 * **Philosophy:**
 * Simple, fast, local. No cloud API needed for intent detection.
 * Keyword-based classification is enough for 90% of queries.
 *
 * **Categories (20):**
 * Technical, Educational, Entertainment, Security, Support
 */
class IntentClassifier {

    /**
     * Classify user query into knowledge intent
     *
     * Uses keyword matching with case-insensitive comparison.
     * Returns the first matching intent, or GENERAL as fallback.
     *
     * @param query User's question or statement
     * @return Detected intent
     */
    fun classify(query: String): Intent {
        val normalizedQuery = query.lowercase().trim()

        // Check each intent's keywords
        for (intent in Intent.values()) {
            if (intent == Intent.GENERAL) continue // Skip catch-all

            // Check if any keyword matches
            for (keyword in intent.keywords) {
                if (matchesKeyword(normalizedQuery, keyword.lowercase())) {
                    return intent
                }
            }
        }

        // Fallback to general
        return Intent.GENERAL
    }

    /**
     * Check if query matches keyword with appropriate boundary rules.
     *
     * - Multi-word phrases: Use contains (e.g., "how are you", "thank you")
     * - Very short keywords (≤2 chars): Require exact word match (prevents "ai" matching "aid", "aim")
     * - Single words: Use word start boundary matching (allows suffixes like -ing, -ed, -s)
     */
    private fun matchesKeyword(query: String, keyword: String): Boolean {
        // Multi-word phrases can use simple contains
        if (keyword.contains(" ")) {
            return query.contains(keyword)
        }

        // Single words: check that keyword appears at word boundary
        // Split by non-alphanumeric characters and check each word
        val words = query.split(Regex("[^a-z0-9]+"))

        // Very short keywords (≤2 chars like "ai") require exact match
        // This prevents "ai" from matching "aid", "aim", "aisle"
        if (keyword.length <= 2) {
            return words.any { word -> word == keyword }
        }

        // Longer keywords: allow prefix matching (e.g., "crash" matches "crashing")
        return words.any { word ->
            word == keyword || word.startsWith(keyword)
        }
    }

    /**
     * Classify query with confidence score
     *
     * @param query User's question
     * @return Pair of (Intent, confidence 0.0-1.0)
     */
    fun classifyWithConfidence(query: String): Pair<Intent, Float> {
        val normalizedQuery = query.lowercase().trim()
        var bestIntent = Intent.GENERAL
        var maxMatches = 0

        // Count keyword matches for each intent (using same matching as classify())
        for (intent in Intent.values()) {
            if (intent == Intent.GENERAL) continue

            var matchCount = 0
            for (keyword in intent.keywords) {
                if (matchesKeyword(normalizedQuery, keyword.lowercase())) {
                    matchCount++
                }
            }

            if (matchCount > maxMatches) {
                maxMatches = matchCount
                bestIntent = intent
            }
        }

        // Calculate confidence based on match count
        val confidence = if (maxMatches == 0) {
            0.1f // Low confidence for general queries
        } else {
            (maxMatches.toFloat() / 3f).coerceIn(0.3f, 1.0f)
        }

        return Pair(bestIntent, confidence)
    }

    /**
     * Check if query requires knowledge retrieval
     *
     * @param intent Classified intent
     * @return true if RAG retrieval should be triggered
     */
    fun requiresKnowledgeRetrieval(intent: Intent): Boolean {
        return intent != Intent.CONVERSATIONAL && intent != Intent.GENERAL
    }

    /**
     * Get suggested retrieval limit based on intent
     *
     * @param intent Classified intent
     * @return Number of documents to retrieve (1-5)
     */
    fun getRetrievalLimit(intent: Intent): Int {
        return when (intent) {
            Intent.TROUBLESHOOTING, Intent.DEVICE_TECH -> 5 // More context for troubleshooting
            Intent.AI_ML -> 4 // Rich AI/ML educational content
            Intent.MATH, Intent.CODE_DEBUG -> 3 // Focused technical help
            Intent.TRIVIA -> 1 // Single fun fact
            Intent.CONVERSATIONAL, Intent.GENERAL -> 0 // No retrieval
            else -> 2 // Default: 2 relevant facts
        }
    }
}
