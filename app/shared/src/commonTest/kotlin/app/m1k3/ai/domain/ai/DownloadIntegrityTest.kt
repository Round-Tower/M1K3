package app.m1k3.ai.domain.ai

import kotlin.test.Test
import kotlin.test.assertEquals

class DownloadIntegrityTest {
    @Test
    fun `within one percent short is complete`() {
        assertEquals(DownloadIntegrity.Verdict.COMPLETE, DownloadIntegrity.check(actualBytes = 995, expectedBytes = 1000))
        assertEquals(DownloadIntegrity.Verdict.COMPLETE, DownloadIntegrity.check(actualBytes = 1000, expectedBytes = 1000))
    }

    @Test
    fun `materially short is truncated`() {
        assertEquals(DownloadIntegrity.Verdict.TRUNCATED, DownloadIntegrity.check(actualBytes = 900, expectedBytes = 1000))
    }

    @Test
    fun `bigger than the server promised is corrupt not complete`() {
        // The Pixel (2026-08-21): two concurrent downloads appended into one .tmp and
        // a "≥99%" check happily accepted a 2x file.
        assertEquals(DownloadIntegrity.Verdict.OVERSIZE, DownloadIntegrity.check(actualBytes = 2000, expectedBytes = 1000))
    }

    @Test
    fun `unknown expected size cannot be judged`() {
        assertEquals(DownloadIntegrity.Verdict.COMPLETE, DownloadIntegrity.check(actualBytes = 123, expectedBytes = 0))
    }
}
