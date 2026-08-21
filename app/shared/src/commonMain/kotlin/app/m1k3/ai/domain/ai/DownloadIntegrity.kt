package app.m1k3.ai.domain.ai

/**
 * Is a finished weights download the file the server promised? Pure so the
 * network-bound manager can stay untested and this can't.
 *
 * Short by >1% → TRUNCATED (HTTP streams can end early without an IOException).
 * Longer than promised → OVERSIZE: that is never a successful download, it's two
 * writers on one file (seen live 2026-08-21 — a 2x .tmp passed the old ≥99% check
 * and was renamed into place).
 */
object DownloadIntegrity {
    enum class Verdict { COMPLETE, TRUNCATED, OVERSIZE }

    fun check(actualBytes: Long, expectedBytes: Long): Verdict {
        if (expectedBytes <= 0) return Verdict.COMPLETE
        if (actualBytes > expectedBytes) return Verdict.OVERSIZE
        if (actualBytes < expectedBytes * 99 / 100) return Verdict.TRUNCATED
        return Verdict.COMPLETE
    }
}
