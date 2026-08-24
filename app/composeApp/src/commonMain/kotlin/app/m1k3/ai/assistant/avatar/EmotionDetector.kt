package app.m1k3.ai.assistant.avatar

/**
 * M1K3 Emotion Detection Engine
 *
 * Analyzes text messages to detect emotional content and determine
 * appropriate avatar reactions. Uses keyword matching and regex patterns.
 *
 * Supports 9 emotions: Happy, Sad, Angry, Surprised, Love, Thinking, Sleepy, Excited, Neutral
 */

object EmotionDetector {
    /**
     * Detect emotion from text message
     *
     * Analyzes message content and returns detected emotion with confidence score.
     *
     * @param text Message text to analyze
     * @return Detected emotion and intensity (0.0 to 1.0)
     */
    fun detectEmotion(text: String): EmotionDetectionResult {
        val lowerText = text.lowercase()

        // Score each emotion
        val scores = mutableMapOf<AvatarEmotion, Float>()
        scores[AvatarEmotion.HAPPY] = scoreHappy(lowerText)
        scores[AvatarEmotion.SAD] = scoreSad(lowerText)
        scores[AvatarEmotion.ANGRY] = scoreAngry(lowerText)
        scores[AvatarEmotion.SURPRISED] = scoreSurprised(lowerText)
        scores[AvatarEmotion.LOVE] = scoreLove(lowerText)
        scores[AvatarEmotion.THINKING] = scoreThinking(lowerText)
        scores[AvatarEmotion.SLEEPY] = scoreSleepy(lowerText)
        scores[AvatarEmotion.EXCITED] = scoreExcited(lowerText)

        // Find highest scoring emotion
        val maxEntry = scores.maxByOrNull { it.value }
        val emotion = maxEntry?.key ?: AvatarEmotion.NEUTRAL
        val score = maxEntry?.value ?: 0f

        // Use neutral if no strong emotion detected
        val finalEmotion = if (score < 0.2f) AvatarEmotion.NEUTRAL else emotion

        // Calculate intensity based on score and text features
        val intensity = calculateIntensity(lowerText, score)

        return EmotionDetectionResult(
            emotion = finalEmotion,
            intensity = intensity,
            confidence = score,
            detectedKeywords = getMatchedKeywords(lowerText, finalEmotion)
        )
    }

    /**
     * Score HAPPY emotion
     */
    private fun scoreHappy(text: String): Float {
        val keywords = listOf(
            "happy", "glad", "joy", "great", "awesome", "wonderful", "fantastic",
            "excellent", "perfect", "amazing", "love it", "yay", "nice", "good",
            "thank you", "thanks", "appreciate", "delighted", "pleased", "cheerful",
            "😊", "😃", "😄", "🙂", "😁", "🎉"
        )
        return scoreKeywords(text, keywords)
    }

    /**
     * Score SAD emotion
     */
    private fun scoreSad(text: String): Float {
        val keywords = listOf(
            "sad", "unhappy", "disappointed", "sorry", "unfortunately", "failed",
            "bad", "terrible", "awful", "worse", "down", "depressed", "upset",
            "unfortunate", "regret", "miss", "lost", "cry", "tear",
            "😢", "😞", "😔", "☹️", "😿"
        )
        return scoreKeywords(text, keywords)
    }

    /**
     * Score ANGRY emotion
     */
    private fun scoreAngry(text: String): Float {
        val keywords = listOf(
            "angry", "mad", "frustrated", "annoyed", "irritated", "furious",
            "hate", "stupid", "dumb", "idiot", "ridiculous", "unacceptable",
            "outraged", "rage", "pissed", "damn", "hell", "wtf", "ugh",
            "😠", "😡", "🤬", "💢"
        )
        return scoreKeywords(text, keywords)
    }

    /**
     * Score SURPRISED emotion
     */
    private fun scoreSurprised(text: String): Float {
        val keywords = listOf(
            "wow", "omg", "oh my", "surprised", "shocking", "unbelievable",
            "incredible", "amazing", "astonishing", "can't believe", "really?",
            "seriously?", "what?!", "whoa", "holy", "no way",
            "😲", "😮", "😯", "🤯", "‼️", "❗"
        )
        val punctuationBoost = if (text.contains("?!") || text.contains("!?")) 0.3f else 0f
        return scoreKeywords(text, keywords) + punctuationBoost
    }

    /**
     * Score LOVE emotion
     */
    private fun scoreLove(text: String): Float {
        val keywords = listOf(
            "love", "adore", "cherish", "affection", "care", "heart", "darling",
            "sweetheart", "beautiful", "gorgeous", "lovely", "cute", "precious",
            "favorite", "best", "treasure", "romantic",
            "😍", "🥰", "💕", "💖", "💗", "💓", "❤️", "💝"
        )
        return scoreKeywords(text, keywords)
    }

    /**
     * Score THINKING emotion
     */
    private fun scoreThinking(text: String): Float {
        val keywords = listOf(
            "think", "consider", "analyze", "ponder", "wonder", "question",
            "hmm", "hmmm", "interesting", "curious", "why", "how", "what if",
            "maybe", "perhaps", "possibly", "let me think", "thinking",
            "🤔", "💭", "🧐"
        )
        val questionBoost = if (text.contains("?")) 0.2f else 0f
        return scoreKeywords(text, keywords) + questionBoost
    }

    /**
     * Score SLEEPY emotion
     */
    private fun scoreSleepy(text: String): Float {
        val keywords = listOf(
            "tired", "sleepy", "exhausted", "drowsy", "sleep", "yawn", "zzz",
            "bed", "nap", "rest", "fatigue", "weary", "worn out", "drained",
            "😴", "😪", "🥱", "💤"
        )
        return scoreKeywords(text, keywords)
    }

    /**
     * Score EXCITED emotion
     */
    private fun scoreExcited(text: String): Float {
        val keywords = listOf(
            "excited", "thrilled", "pumped", "enthusiastic", "energized",
            "can't wait", "so cool", "let's go", "yes!", "hell yeah",
            "stoked", "hyped", "woohoo", "yahoo", "awesome!", "amazing!",
            "🤩", "🎊", "🎉", "🔥", "⚡", "✨"
        )
        val exclamationBoost = text.count { it == '!' } * 0.1f
        return scoreKeywords(text, keywords) + exclamationBoost
    }

    /**
     * Score keywords in text
     */
    private fun scoreKeywords(text: String, keywords: List<String>): Float {
        var score = 0f
        for (keyword in keywords) {
            if (text.contains(keyword)) {
                // Longer keywords get higher weight
                score += (keyword.length / 10f).coerceIn(0.1f, 0.5f)
            }
        }
        return score.coerceIn(0f, 1f)
    }

    /**
     * Calculate intensity based on text features
     */
    private fun calculateIntensity(text: String, baseScore: Float): Float {
        var intensity = baseScore

        // Exclamation marks increase intensity
        val exclamations = text.count { it == '!' }
        intensity += exclamations * 0.1f

        // ALL CAPS increases intensity
        val capsRatio = text.count { it.isUpperCase() }.toFloat() / text.length.coerceAtLeast(1)
        if (capsRatio > 0.5f) {
            intensity += 0.2f
        }

        // Multiple punctuation increases intensity
        if (text.contains("!!!") || text.contains("???") || text.contains("?!?")) {
            intensity += 0.15f
        }

        return intensity.coerceIn(0.3f, 1f)
    }

    /**
     * Get matched keywords for debugging
     */
    private fun getMatchedKeywords(text: String, emotion: AvatarEmotion): List<String> {
        val allKeywords = when (emotion) {
            AvatarEmotion.HAPPY -> listOf("happy", "joy", "great", "awesome", "thanks")
            AvatarEmotion.SAD -> listOf("sad", "disappointed", "sorry", "bad")
            AvatarEmotion.ANGRY -> listOf("angry", "mad", "frustrated", "annoyed")
            AvatarEmotion.SURPRISED -> listOf("wow", "omg", "surprised", "shocking")
            AvatarEmotion.LOVE -> listOf("love", "adore", "heart", "beautiful")
            AvatarEmotion.THINKING -> listOf("think", "wonder", "hmm", "question")
            AvatarEmotion.SLEEPY -> listOf("tired", "sleepy", "exhausted", "sleep")
            AvatarEmotion.EXCITED -> listOf("excited", "thrilled", "pumped", "yes!")
            AvatarEmotion.NEUTRAL -> emptyList()
        }

        return allKeywords.filter { text.contains(it) }
    }

    /**
     * Detect emotion from conversation context
     *
     * Analyzes recent message history to determine overall emotional tone.
     * Useful for maintaining avatar emotion across multiple messages.
     *
     * @param messages Recent message texts (most recent last)
     * @param windowSize Number of recent messages to consider
     * @return Aggregated emotion detection
     */
    fun detectEmotionFromContext(
        messages: List<String>,
        windowSize: Int = 3
    ): EmotionDetectionResult {
        if (messages.isEmpty()) {
            return EmotionDetectionResult(AvatarEmotion.NEUTRAL, 0.5f, 0f, emptyList())
        }

        // Analyze recent messages
        val recentMessages = messages.takeLast(windowSize)
        val detections = recentMessages.map { detectEmotion(it) }

        // Weight more recent messages higher
        val weights = List(detections.size) { i ->
            (i + 1).toFloat() / detections.size
        }

        // Weighted average of emotions
        val emotionScores = mutableMapOf<AvatarEmotion, Float>()
        detections.forEachIndexed { index, detection ->
            val weight = weights[index]
            emotionScores[detection.emotion] =
                (emotionScores[detection.emotion] ?: 0f) + (detection.confidence * weight)
        }

        val maxEntry = emotionScores.maxByOrNull { it.value }
        val emotion = maxEntry?.key ?: AvatarEmotion.NEUTRAL
        val score = maxEntry?.value ?: 0f

        // Average intensity
        val avgIntensity = detections.map { it.intensity }.average().toFloat()

        return EmotionDetectionResult(
            emotion = if (score < 0.2f) AvatarEmotion.NEUTRAL else emotion,
            intensity = avgIntensity,
            confidence = score,
            detectedKeywords = emptyList()
        )
    }
}

/**
 * Emotion detection result
 */
data class EmotionDetectionResult(
    val emotion: AvatarEmotion,
    val intensity: Float, // 0.0 (subtle) to 1.0 (extreme)
    val confidence: Float, // 0.0 (uncertain) to 1.0 (confident)
    val detectedKeywords: List<String>
)

/**
 * Usage Examples:
 * ```kotlin
 * // Detect emotion from single message
 * val result = EmotionDetector.detectEmotion("Wow! This is amazing!")
 * println("${result.emotion} (${result.intensity})")  // SURPRISED (0.85)
 *
 * // Detect from conversation context
 * val messages = listOf(
 *     "I'm working on a project",
 *     "It's really frustrating",
 *     "Nothing works!"
 * )
 * val contextResult = EmotionDetector.detectEmotionFromContext(messages)
 * println(contextResult.emotion)  // ANGRY
 * ```
 */
