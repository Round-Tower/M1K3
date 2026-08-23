package app.m1k3.ai.assistant.rag

import app.m1k3.ai.domain.rag.Intent
import app.m1k3.ai.domain.rag.services.IntentClassifier
import kotlin.test.*

/**
 * Tests for IntentClassifier - Intent detection for RAG system
 *
 * Validates that queries are correctly classified into 20 knowledge categories.
 */
class IntentClassifierTest {

    private lateinit var classifier: IntentClassifier

    @BeforeTest
    fun setup() {
        classifier = IntentClassifier()
    }

    // ========================================
    // Technical Expertise Tests
    // ========================================

    @Test
    fun `classify mathematical queries as MATH`() {
        assertEquals(Intent.MATH, classifier.classify("Calculate 2 + 2"))
        assertEquals(Intent.MATH, classifier.classify("solve this equation"))
        assertEquals(Intent.MATH, classifier.classify("What is the formula for area of circle?"))
        assertEquals(Intent.MATH, classifier.classify("help me with trigonometry"))
    }

    @Test
    fun `classify code debugging queries as CODE_DEBUG`() {
        assertEquals(Intent.CODE_DEBUG, classifier.classify("My code has an error"))
        assertEquals(Intent.CODE_DEBUG, classifier.classify("debug this function"))
        assertEquals(Intent.CODE_DEBUG, classifier.classify("why is my program crashing?"))
        assertEquals(Intent.CODE_DEBUG, classifier.classify("there's a syntax error in Python"))
    }

    @Test
    fun `classify technical explanation queries as TECHNICAL_EXPLANATION`() {
        assertEquals(Intent.TECHNICAL_EXPLANATION, classifier.classify("How does the protocol work?"))
        assertEquals(Intent.TECHNICAL_EXPLANATION, classifier.classify("Explain what is a TCP protocol"))
        assertEquals(Intent.TECHNICAL_EXPLANATION, classifier.classify("What is cloud architecture?"))
    }

    // ========================================
    // Educational & General Knowledge Tests
    // ========================================

    @Test
    fun `classify historical queries as HISTORY`() {
        assertEquals(Intent.HISTORY, classifier.classify("Tell me about World War II"))
        assertEquals(Intent.HISTORY, classifier.classify("When did the Roman Empire fall?"))
        assertEquals(Intent.HISTORY, classifier.classify("ancient civilizations"))
    }

    @Test
    fun `classify science queries as SCIENCE`() {
        assertEquals(Intent.SCIENCE, classifier.classify("How does photosynthesis work?"))
        assertEquals(Intent.SCIENCE, classifier.classify("What is quantum physics?"))
        assertEquals(Intent.SCIENCE, classifier.classify("Explain the theory of evolution"))
    }

    @Test
    fun `classify geography queries as GEOGRAPHY`() {
        assertEquals(Intent.GEOGRAPHY, classifier.classify("Where is Mount Everest?"))
        assertEquals(Intent.GEOGRAPHY, classifier.classify("What is the capital of France?"))
        assertEquals(Intent.GEOGRAPHY, classifier.classify("Tell me about the Amazon river"))
    }

    @Test
    fun `classify movie queries as MOVIES_TV`() {
        assertEquals(Intent.MOVIES_TV, classifier.classify("Who directed Inception?"))
        assertEquals(Intent.MOVIES_TV, classifier.classify("Tell me about this TV series"))
        assertEquals(Intent.MOVIES_TV, classifier.classify("Best movies of 2024"))
    }

    @Test
    fun `classify music queries as MUSIC`() {
        assertEquals(Intent.MUSIC, classifier.classify("Who is the best jazz artist?"))
        assertEquals(Intent.MUSIC, classifier.classify("Tell me about this song"))
        assertEquals(Intent.MUSIC, classifier.classify("What instrument is used in classical music?"))
    }

    // ========================================
    // Advanced Expertise Tests
    // ========================================

    @Test
    fun `classify device troubleshooting as DEVICE_TECH`() {
        assertEquals(Intent.DEVICE_TECH, classifier.classify("My phone battery drains quickly"))
        assertEquals(Intent.DEVICE_TECH, classifier.classify("How do I reset my smartphone?"))
        assertEquals(Intent.DEVICE_TECH, classifier.classify("My device is overheating"))
        assertEquals(Intent.DEVICE_TECH, classifier.classify("Screen is cracked, what to do?"))
    }

    @Test
    fun `classify WiFi queries as WIFI_NETWORK`() {
        assertEquals(Intent.WIFI_NETWORK, classifier.classify("My WiFi is slow"))
        assertEquals(Intent.WIFI_NETWORK, classifier.classify("How to setup router?"))
        assertEquals(Intent.WIFI_NETWORK, classifier.classify("Internet connection issues"))
        assertEquals(Intent.WIFI_NETWORK, classifier.classify("What is my IP address?"))
    }

    @Test
    fun `classify security queries as SECURITY`() {
        assertEquals(Intent.SECURITY, classifier.classify("How to protect from phishing?"))
        assertEquals(Intent.SECURITY, classifier.classify("What is a strong password?"))
        assertEquals(Intent.SECURITY, classifier.classify("How to use VPN?"))
        assertEquals(Intent.SECURITY, classifier.classify("Is this website secure?"))
    }

    @Test
    fun `classify troubleshooting queries as TROUBLESHOOTING`() {
        assertEquals(Intent.TROUBLESHOOTING, classifier.classify("I have a problem with my app"))
        assertEquals(Intent.TROUBLESHOOTING, classifier.classify("How to fix this issue?"))
        assertEquals(Intent.TROUBLESHOOTING, classifier.classify("Something is broken"))
        assertEquals(Intent.TROUBLESHOOTING, classifier.classify("Not working properly"))
    }

    @Test
    fun `classify educational queries as EDUCATION`() {
        assertEquals(Intent.EDUCATION, classifier.classify("How to study effectively?"))
        assertEquals(Intent.EDUCATION, classifier.classify("Best learning methods"))
        assertEquals(Intent.EDUCATION, classifier.classify("Help me with my homework"))
        assertEquals(Intent.EDUCATION, classifier.classify("How to prepare for exam?"))
    }

    @Test
    fun `classify trivia queries as TRIVIA`() {
        assertEquals(Intent.TRIVIA, classifier.classify("Tell me an interesting fact"))
        assertEquals(Intent.TRIVIA, classifier.classify("What's a fun trivia?"))
        assertEquals(Intent.TRIVIA, classifier.classify("Did you know any amazing facts?"))
        assertEquals(Intent.TRIVIA, classifier.classify("Random quiz question"))
    }

    // ========================================
    // AI/ML Tests
    // ========================================

    @Test
    fun `classify AI and ML queries as AI_ML`() {
        assertEquals(Intent.AI_ML, classifier.classify("Tell me about artificial intelligence"))
        assertEquals(Intent.AI_ML, classifier.classify("What is machine learning?"))
        assertEquals(Intent.AI_ML, classifier.classify("How do neural networks work?"))
        assertEquals(Intent.AI_ML, classifier.classify("What is deep learning?"))
        assertEquals(Intent.AI_ML, classifier.classify("Tell me about ChatGPT"))
        assertEquals(Intent.AI_ML, classifier.classify("How does GPT work?"))
        assertEquals(Intent.AI_ML, classifier.classify("What is an LLM?"))
    }

    @Test
    fun `AI_ML intent retrieval limit is 4`() {
        assertEquals(4, classifier.getRetrievalLimit(Intent.AI_ML), "AI_ML should retrieve 4 docs")
    }

    @Test
    fun `short keyword 'ai' requires exact word match - no false positives`() {
        // Short keywords (≤2 chars like "ai") require exact word match
        // This prevents false positives from prefix matching

        // These SHOULD match AI_ML (true positives - exact word "ai")
        assertEquals(Intent.AI_ML, classifier.classify("Tell me about AI"))
        assertEquals(Intent.AI_ML, classifier.classify("What is AI?"))
        assertEquals(Intent.AI_ML, classifier.classify("AI is fascinating"))

        // These should NOT match AI_ML (false positive prevention)
        // "aid", "aim", "aisle" should not trigger AI_ML since "ai" requires exact match
        assertNotEquals(Intent.AI_ML, classifier.classify("I need first aid training"))
        assertNotEquals(Intent.AI_ML, classifier.classify("What should I aim for?"))
        assertNotEquals(Intent.AI_ML, classifier.classify("Walk down the aisle"))
    }

    @Test
    fun `short keyword matching is case insensitive`() {
        // "AI", "Ai", "ai" should all match the same way
        assertEquals(
            classifier.classify("Tell me about AI"),
            classifier.classify("Tell me about ai")
        )
        assertEquals(
            classifier.classify("What is AI?"),
            classifier.classify("What is Ai?")
        )
    }

    // ========================================
    // System & Fallback Tests
    // ========================================

    @Test
    fun `classify system queries as SYSTEM`() {
        assertEquals(Intent.SYSTEM, classifier.classify("Tell me about M1K3"))
        assertEquals(Intent.SYSTEM, classifier.classify("Tell me about yourself"))
        assertEquals(Intent.SYSTEM, classifier.classify("What can you do?"))
        assertEquals(Intent.SYSTEM, classifier.classify("What are your capabilities?"))
    }

    @Test
    fun `classify conversational queries as CONVERSATIONAL`() {
        assertEquals(Intent.CONVERSATIONAL, classifier.classify("Hello"))
        assertEquals(Intent.CONVERSATIONAL, classifier.classify("Hi there!"))
        assertEquals(Intent.CONVERSATIONAL, classifier.classify("Thank you"))
        assertEquals(Intent.CONVERSATIONAL, classifier.classify("Goodbye"))
        assertEquals(Intent.CONVERSATIONAL, classifier.classify("How are you?"))
    }

    @Test
    fun `classify unknown queries as GENERAL`() {
        assertEquals(Intent.GENERAL, classifier.classify("some text without keywords"))
        assertEquals(Intent.GENERAL, classifier.classify("xyzabc"))
        assertEquals(Intent.GENERAL, classifier.classify(""))
    }

    // ========================================
    // Confidence Scoring Tests
    // ========================================

    @Test
    fun `classifyWithConfidence returns high confidence for multiple keyword matches`() {
        val (intent, confidence) = classifier.classifyWithConfidence(
            "My phone device smartphone is broken and needs troubleshooting"
        )

        assertEquals(Intent.DEVICE_TECH, intent)
        assertTrue(confidence >= 0.8f, "Multiple keyword matches should yield high confidence, got $confidence")
    }

    @Test
    fun `classifyWithConfidence returns medium confidence for single keyword match`() {
        val (intent, confidence) = classifier.classifyWithConfidence("Tell me about tablets")

        assertEquals(Intent.DEVICE_TECH, intent)
        assertTrue(confidence in 0.3f..0.7f, "Single match should yield medium confidence, got $confidence")
    }

    @Test
    fun `classifyWithConfidence returns low confidence for general queries`() {
        val (intent, confidence) = classifier.classifyWithConfidence("xyza text")

        assertEquals(Intent.GENERAL, intent)
        assertEquals(0.1f, confidence, 0.01f, "General queries should have low confidence")
    }

    @Test
    fun `classifyWithConfidence confidence increases with more matches`() {
        val (_, conf1) = classifier.classifyWithConfidence("phone")
        val (_, conf2) = classifier.classifyWithConfidence("phone device")
        val (_, conf3) = classifier.classifyWithConfidence("phone device smartphone")

        assertTrue(conf1 < conf2, "Two keywords should have higher confidence than one")
        assertTrue(conf2 <= conf3, "Three keywords should have equal or higher confidence than two")
    }

    // ========================================
    // Retrieval Requirement Tests
    // ========================================

    @Test
    fun `requiresKnowledgeRetrieval returns false only for conversational queries`() {
        // Only pure chitchat skips retrieval. GENERAL (any substantive question
        // that didn't match a keyword intent) now grounds — see the true-case
        // test. On-device grounding is the product; don't make the user phrase
        // questions like a textbook to reach their own notes (2026-08-23).
        assertFalse(classifier.requiresKnowledgeRetrieval(Intent.CONVERSATIONAL))
    }

    @Test
    fun `requiresKnowledgeRetrieval returns true for knowledge queries`() {
        assertTrue(classifier.requiresKnowledgeRetrieval(Intent.GENERAL))
        assertTrue(classifier.requiresKnowledgeRetrieval(Intent.DEVICE_TECH))
        assertTrue(classifier.requiresKnowledgeRetrieval(Intent.SECURITY))
        assertTrue(classifier.requiresKnowledgeRetrieval(Intent.TRIVIA))
        assertTrue(classifier.requiresKnowledgeRetrieval(Intent.MATH))
    }

    // ========================================
    // Retrieval Limit Tests
    // ========================================

    @Test
    fun `getRetrievalLimit returns correct limits for different intents`() {
        assertEquals(5, classifier.getRetrievalLimit(Intent.TROUBLESHOOTING), "Troubleshooting needs 5 docs")
        assertEquals(5, classifier.getRetrievalLimit(Intent.DEVICE_TECH), "Device tech needs 5 docs")
        assertEquals(3, classifier.getRetrievalLimit(Intent.MATH), "Math needs 3 docs")
        assertEquals(3, classifier.getRetrievalLimit(Intent.CODE_DEBUG), "Code debug needs 3 docs")
        assertEquals(1, classifier.getRetrievalLimit(Intent.TRIVIA), "Trivia needs 1 doc")
        assertEquals(0, classifier.getRetrievalLimit(Intent.CONVERSATIONAL), "Conversational needs 0 docs")
        assertEquals(2, classifier.getRetrievalLimit(Intent.GENERAL), "General grounds with 2 docs")
        assertEquals(2, classifier.getRetrievalLimit(Intent.HISTORY), "Default should be 2 docs")
    }

    // ========================================
    // Edge Cases & Disambiguation Tests
    // ========================================

    @Test
    fun `distinguish device troubleshooting from device trivia`() {
        // Troubleshooting (contains "problem", "fix", etc.)
        val troubleshoot = classifier.classify("My phone has a problem")
        assertTrue(
            troubleshoot == Intent.DEVICE_TECH || troubleshoot == Intent.TROUBLESHOOTING,
            "Troubleshooting query should be DEVICE_TECH or TROUBLESHOOTING"
        )

        // Historical fact (with "when was" and "invented" keywords -> HISTORY)
        val historical = classifier.classify("When was the first smartphone invented?")
        assertEquals(Intent.HISTORY, historical, "Historical question should be HISTORY")
    }

    @Test
    fun `case insensitivity works correctly`() {
        assertEquals(
            classifier.classify("MY PHONE BATTERY DRAINS QUICKLY"),
            classifier.classify("my phone battery drains quickly")
        )
    }

    @Test
    fun `whitespace handling works correctly`() {
        assertEquals(
            classifier.classify("   my phone battery drains    "),
            classifier.classify("my phone battery drains")
        )
    }

    @Test
    fun `first matching intent wins for overlapping keywords`() {
        // "phone" appears in DEVICE_TECH, "technology" appears in TECHNOLOGY
        // DEVICE_TECH comes first in enum order
        val intent = classifier.classify("My phone is not working")

        // Should match DEVICE_TECH first (earlier in enum order)
        assertEquals(Intent.DEVICE_TECH, intent)
    }
}
