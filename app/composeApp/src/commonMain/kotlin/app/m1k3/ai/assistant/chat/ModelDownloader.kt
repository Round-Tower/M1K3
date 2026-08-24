package app.m1k3.ai.assistant.chat

import app.m1k3.ai.domain.ai.LlmModel

/** Cancels an in-flight weights download. Idempotent. */
fun interface DownloadHandle {
    fun cancel()
}

/**
 * Starts downloading [LlmModel] weights, reporting [ModelDownloadState] as it
 * goes, and returns a [DownloadHandle] so the caller can abandon it — a second
 * brain picked mid-download must cancel the first, not race it.
 */
typealias ModelDownloader = (LlmModel, (ModelDownloadState) -> Unit) -> DownloadHandle
