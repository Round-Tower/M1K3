package app.m1k3.ai.domain.status

/**
 * Status information for display at the start of a new chat.
 *
 * @property greeting Time-based greeting (e.g., "Good afternoon!")
 * @property engineReady Whether the AI engine is ready
 * @property memoryCount Number of memories indexed
 * @property maxContextTokens Maximum context window size
 * @property deviceTierName Human-readable device tier
 */
data class ChatStatus(
    val greeting: String,
    val engineReady: Boolean,
    val memoryCount: Long,
    val maxContextTokens: Int,
    val deviceTierName: String,
)

/**
 * Builds chat status for display at the start of a new conversation.
 *
 * Assembles greeting, engine status, and memory stats into a displayable
 * format.
 */
class ChatStatusBuilder {
    fun getTimeBasedGreeting(hour: Int): String =
        when (hour) {
            in 5..11 -> "Good morning!"
            in 12..17 -> "Good afternoon!"
            else -> "Good evening!"
        }

    fun build(
        hour: Int,
        engineReady: Boolean,
        memoryCount: Long,
        maxContextTokens: Int,
        deviceTierName: String,
    ): ChatStatus =
        ChatStatus(
            greeting = getTimeBasedGreeting(hour),
            engineReady = engineReady,
            memoryCount = memoryCount,
            maxContextTokens = maxContextTokens,
            deviceTierName = deviceTierName,
        )

    fun formatStatusText(status: ChatStatus): String {
        val lines = mutableListOf<String>()

        lines.add(status.greeting)
        lines.add("")

        val engineStatus = if (status.engineReady) "Ready" else "Loading..."
        lines.add("Engine: $engineStatus | Memories: ${status.memoryCount}")
        lines.add("Context: ${formatNumber(status.maxContextTokens.toLong())} tokens (${status.deviceTierName})")

        return lines.joinToString("\n")
    }

    private fun formatNumber(n: Long): String =
        if (n >= 1000) {
            val thousands = n / 1000
            val remainder = n % 1000
            if (remainder == 0L) {
                "$thousands,000"
            } else {
                "$thousands,${remainder.toString().padStart(3, '0')}"
            }
        } else {
            n.toString()
        }
}
