package app.m1k3.ai.domain.voice

/**
 * "Please" is the spoken submit button (Kev, 2026-08-13). Whole-word, trailing
 * position only: "pleased" never submits and a mid-sentence "please tell me…" is
 * ordinary politeness. An ACCELERATOR, never a requirement — silence endpointing
 * is unchanged when the word is absent.
 */
object PoliteEndpoint {
    const val UI_HINT = "End with “please” and M1K3 will take its turn"

    fun isSubmit(text: String): Boolean = lastWord(text) == "please"

    internal fun lastWord(text: String): String =
        text
            .split(' ', '\n', '\t')
            .lastOrNull { it.isNotBlank() }
            ?.lowercase()
            ?.trim { !it.isLetter() }
            ?: ""
}
