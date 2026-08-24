package app.m1k3.ai.domain.history

/**
 * The placeholder title a brand-new conversation is created with, before
 * the first user message renames it (see `ChatScreenViewModel.recordMessage`).
 * Pure display logic below never leaks this internal name to the user.
 */
const val UNTITLED_CONVERSATION_TITLE = "Chat Session"

/**
 * The name a conversation row shows. A `null`/blank title, or one that
 * never advanced past the internal placeholder, reads as "New chat" —
 * never the placeholder itself (finding: drop the "Chat Session" naming).
 */
fun String?.toDisplayTitle(): String = if (isNullOrBlank() || this == UNTITLED_CONVERSATION_TITLE) "New chat" else this

/**
 * "1 message" / "N messages" — a real English plural, not "1 messages".
 */
fun pluralizeMessages(count: Int): String = if (count == 1) "1 message" else "$count messages"
