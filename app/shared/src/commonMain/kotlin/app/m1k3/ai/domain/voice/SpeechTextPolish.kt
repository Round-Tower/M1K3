package app.m1k3.ai.domain.voice

/**
 * What TTS actually SPEAKS should never be the raw chat text — markdown
 * markers, code fences, citation-shaped links and bare URLs all read as
 * garbage aloud. Port of the Mac's `SpeechTextPolish.swift`: a pure text
 * transform so voice mode (and "speak replies aloud") can sanitize a turn's
 * answer before it reaches a [Speaker], regardless of which one.
 *
 * Deliberately conservative: it strips the *markup*, never the meaning — a
 * think-block is dropped whole (that's reasoning the user never asked to
 * hear), everything else keeps its words and loses only the punctuation that
 * exists for a reader's eyes.
 */
object SpeechTextPolish {
    private val thinkBlock =
        Regex("""< *think *>.*?< */ *think *>""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    private val fencedCode = Regex("""```.*?```""", RegexOption.DOT_MATCHES_ALL)
    private val inlineCode = Regex("""`([^`]+?)`""")
    private val markdownLink = Regex("""\[([^\]]+)]\([^)]+\)""")
    private val boldEmphasis = Regex("""\*\*(.+?)\*\*""")
    private val italicEmphasis = Regex("""\*(.+?)\*""")
    private val underlineEmphasis = Regex("""_(.+?)_""")

    // Host only: capture the domain, then swallow URL-safe path/query chars —
    // deliberately excluding sentence punctuation (. , ! ? ; :) so a trailing
    // full stop stays the SENTENCE's, not the URL's.
    private val bareUrl = Regex("""https?://([a-zA-Z0-9.-]+)(?:[\w/?=&%~+#-]*)""")
    private val blankLineRun = Regex("""\n{3,}""")
    private val horizontalWhitespaceRun = Regex("""[ \t]{2,}""")

    fun polish(raw: String): String {
        if (raw.isBlank()) return ""
        return raw
            .replace(thinkBlock, "")
            .replace(fencedCode, "")
            .replace(markdownLink, "$1")
            .replace(inlineCode, "$1")
            .replace(boldEmphasis, "$1")
            .replace(italicEmphasis, "$1")
            .replace(underlineEmphasis, "$1")
            .replace(bareUrl, "$1")
            .replace(blankLineRun, "\n\n")
            .replace(horizontalWhitespaceRun, " ")
            .trim()
    }
}
