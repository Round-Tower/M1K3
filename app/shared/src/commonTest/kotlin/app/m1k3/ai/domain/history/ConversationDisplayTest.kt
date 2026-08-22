package app.m1k3.ai.domain.history

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * TDD Tests for conversation row display logic (finding: history rows
 * dropped tokens, pluralized "1 messages", and leaked the "Chat Session"
 * internal placeholder as a visible title).
 */
class ConversationDisplayTest {
    // ===== toDisplayTitle =====

    @Test
    fun `a real title passes through unchanged`() {
        assertEquals("What's the capital of Peru?", "What's the capital of Peru?".toDisplayTitle())
    }

    @Test
    fun `null title reads as New chat`() {
        val title: String? = null
        assertEquals("New chat", title.toDisplayTitle())
    }

    @Test
    fun `blank title reads as New chat`() {
        assertEquals("New chat", "   ".toDisplayTitle())
    }

    @Test
    fun `the internal placeholder never leaks to the user`() {
        assertEquals("New chat", UNTITLED_CONVERSATION_TITLE.toDisplayTitle())
    }

    // ===== pluralizeMessages =====

    @Test
    fun `zero messages is plural`() {
        assertEquals("0 messages", pluralizeMessages(0))
    }

    @Test
    fun `one message is singular`() {
        assertEquals("1 message", pluralizeMessages(1))
    }

    @Test
    fun `many messages is plural`() {
        assertEquals("42 messages", pluralizeMessages(42))
    }
}
