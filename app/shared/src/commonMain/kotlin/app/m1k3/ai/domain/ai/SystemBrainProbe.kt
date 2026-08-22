package app.m1k3.ai.domain.ai

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf

/**
 * SystemBrainProbe — asks the platform whether it has its own on-device model.
 *
 * Domain interface — pure Kotlin, no platform dependencies. The Android
 * implementation (`AndroidSystemBrainProbe`, composeApp/androidMain) wraps ML
 * Kit GenAI's Prompt API (`GenerativeModel.checkStatus()` / `.download()`).
 * iOS/desktop bind [StubSystemBrainProbe] until/unless a platform-native model
 * is worth wiring there too.
 *
 * UI-facing: onboarding/Settings can call [availability] to decide what to
 * show for the Mini tier ("uses your phone's built-in AI" vs "557MB
 * download"), and [download] to drive a progress indicator when the platform
 * model needs fetching.
 */
interface SystemBrainProbe {
    /** Current status. Cheap enough to call on a UI-adjacent path; not memoized here — callers cache if needed. */
    suspend fun availability(): SystemBrainAvailability

    /**
     * Trigger (or observe an in-progress) platform-model download. Emits
     * [SystemBrainAvailability] transitions as the download proceeds, ending
     * on [SystemBrainAvailability.Available] or [SystemBrainAvailability.Unavailable].
     * A no-op probe (nothing to download) emits a single terminal value.
     */
    fun download(): Flow<SystemBrainAvailability>
}

/**
 * Always-unavailable probe. Used on platforms without a system model (iOS,
 * desktop, today) and in tests that don't care about ML Kit specifics —
 * [MiniBrainPolicy.resolve] always falls back to Qwen weights against it.
 */
object StubSystemBrainProbe : SystemBrainProbe {
    private val unavailable = SystemBrainAvailability.Unavailable("no platform system model on this target")

    override suspend fun availability(): SystemBrainAvailability = unavailable

    override fun download(): Flow<SystemBrainAvailability> = flowOf(unavailable)
}
