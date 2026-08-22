package app.m1k3.ai.assistant.ai.ondevice

import android.content.Context
import app.m1k3.ai.assistant.utils.Logger
import app.m1k3.ai.domain.ai.SystemBrainAvailability
import app.m1k3.ai.domain.ai.SystemBrainProbe
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

private val logger = Logger.withTag("AndroidSystemBrainProbe")

/**
 * AndroidSystemBrainProbe — ML Kit GenAI's Prompt API (Gemini Nano / AICore)
 * as a [SystemBrainProbe]. Android's half of the platform system model for
 * [app.m1k3.ai.domain.ai.M1K3Tier.Mini].
 *
 * `context` is unused today (`Generation.getClient()` resolves the app
 * context internally, same as every other ML Kit surface in this repo) but
 * kept on the constructor for parity with every other platform provider here
 * and because a future release-track/ModelConfig probe will likely want it.
 *
 * SDK ground truth (verified against the `genai-prompt`/`genai-common`
 * 1.0.0-beta4 AARs directly — `javap` over the decompiled classes, not
 * secondhand docs — 2026-08-22): `checkStatus()` and `download()` live on
 * [GenerativeModel]; `@FeatureStatus` is a 4-value int annotation
 * (UNAVAILABLE/DOWNLOADABLE/DOWNLOADING/AVAILABLE); `download()` returns
 * `Flow<DownloadStatus>` whose sealed shape is `DownloadStarted(bytesToDownload)`
 * / `DownloadProgress(totalBytesDownloaded)` / `DownloadCompleted` /
 * `DownloadFailed(GenAiException)` — no built-in percent, so this class
 * derives one from the started/progress pair.
 */
class AndroidSystemBrainProbe(
    @Suppress("unused") private val context: Context,
) : SystemBrainProbe {
    /** Lazily created, reused across calls — one client per probe instance. */
    private val client: GenerativeModel by lazy { Generation.getClient() }

    override suspend fun availability(): SystemBrainAvailability =
        try {
            val status = client.checkStatus()
            logger.i { "checkStatus: $status (AVAILABLE=${FeatureStatus.AVAILABLE} DOWNLOADABLE=${FeatureStatus.DOWNLOADABLE} DOWNLOADING=${FeatureStatus.DOWNLOADING})" }
            when (status) {
                FeatureStatus.AVAILABLE -> SystemBrainAvailability.Available
                FeatureStatus.DOWNLOADABLE -> SystemBrainAvailability.Downloadable()
                FeatureStatus.DOWNLOADING -> SystemBrainAvailability.Downloading()
                else -> SystemBrainAvailability.Unavailable("feature status: unavailable")
            }
        } catch (e: Exception) {
            logger.w(e) { "checkStatus() failed: ${e.message}" }
            SystemBrainAvailability.Unavailable("checkStatus threw: ${e::class.simpleName}")
        }

    override fun download(): Flow<SystemBrainAvailability> =
        flow {
            var bytesToDownload = 0L
            try {
                client.download().collect { status ->
                    when (status) {
                        is DownloadStatus.DownloadStarted -> {
                            bytesToDownload = status.bytesToDownload
                            emit(SystemBrainAvailability.Downloading(percent = 0))
                        }

                        is DownloadStatus.DownloadProgress -> {
                            val percent =
                                if (bytesToDownload > 0) {
                                    ((status.totalBytesDownloaded * 100) / bytesToDownload).toInt().coerceIn(0, 100)
                                } else {
                                    null
                                }
                            emit(SystemBrainAvailability.Downloading(percent = percent))
                        }

                        is DownloadStatus.DownloadCompleted -> {
                            emit(SystemBrainAvailability.Available)
                        }

                        is DownloadStatus.DownloadFailed -> {
                            logger.w { "download failed: ${status.e.errorCode}" }
                            emit(SystemBrainAvailability.Unavailable("download failed: code ${status.e.errorCode}"))
                        }

                        // DownloadStatus is sealed (confirmed by the compiler's
                        // exhaustiveness check, though `javap` shows it as a
                        // plain abstract class) — a future SDK bump adding a
                        // new subtype is a COMPILE ERROR here, not a silent gap.
                    }
                }
            } catch (e: Exception) {
                logger.w(e) { "download() threw: ${e.message}" }
                emit(SystemBrainAvailability.Unavailable("download threw: ${e::class.simpleName}"))
            }
        }
}
