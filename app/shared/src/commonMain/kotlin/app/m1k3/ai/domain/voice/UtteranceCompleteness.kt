package app.m1k3.ai.domain.voice

/**
 * Does a stable partial read like a finished thought? Sentence punctuation says
 * yes; a trailing comma, conjunction, preposition, article or filler says the
 * speaker is mid-clause and the endpointer should hold. Ported from the Mac's
 * `UtteranceCompleteness.swift` — keep the dangling set in step.
 */
object UtteranceCompleteness {
    fun looksComplete(text: String): Boolean {
        val trimmed = text.trim()
        val last = trimmed.lastOrNull() ?: return false
        if (last in ".!?") return true
        if (last == ',') return false
        return PoliteEndpoint.lastWord(trimmed) !in DANGLING
    }

    private val DANGLING =
        setOf(
            "and", "but", "or", "nor", "because", "although", "though",
            "while", "if", "unless", "since", "whereas", "plus",
            "to", "of", "in", "on", "at", "by", "for", "with", "from", "into",
            "onto", "upon", "about", "as", "than",
            "a", "an", "the", "my", "your", "our", "their",
            "um", "uh", "er", "erm", "hmm", "eh", "like",
        )
}
