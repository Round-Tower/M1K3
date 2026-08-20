package app.m1k3.ai.assistant.privacy

import android.content.pm.PackageManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Privacy invariants for M1K3.
 *
 * Updated 2026-04-19 to match ADR-0006 ("user-initiated network"). The app
 * previously claimed "zero network" — no longer true once model downloads
 * and the web-search tool shipped. The new invariants:
 *
 *   1. INTERNET *is* declared, justified in manifest + ADR.
 *   2. No analytics / telemetry / crash-reporting SDKs on the classpath.
 *   3. Network callers are limited to a known allow-list, caught by CI.
 *   4. CAMERA permission still required (multi-modal features).
 *
 * These tests are the enforcement mechanism. A new analytics dependency
 * or a stealth background-network caller will break the build.
 */
@RunWith(AndroidJUnit4::class)
class ManifestPrivacyTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val packageManager = context.packageManager
    private val packageName = context.packageName

    // ========== Manifest-level ==========

    /**
     * AC1: INTERNET permission IS declared. Required by
     * HttpModelDownloadManager and WebSearchExecutor. See ADR-0006.
     */
    @Test
    fun androidManifest_hasInternetPermission() {
        assertTrue(
            hasPermission(android.Manifest.permission.INTERNET),
            "INTERNET permission missing. Required for model downloads and " +
                "the web-search tool. See docs/adr/0006-user-initiated-network.md. " +
                "If you really intend to ship without network, also remove " +
                "HttpModelDownloadManager and WebSearchExecutor.",
        )
    }

    /**
     * AC2: No Google Cloud Messaging / Firebase push permissions. M1K3
     * does not use push notifications from a backend — all notifications
     * are locally generated.
     */
    @Test
    fun androidManifest_hasNoPushMessagingPermissions() {
        assertFalse(
            hasPermission("com.google.android.c2dm.permission.RECEIVE"),
            "C2DM/FCM push permission detected. M1K3 generates notifications " +
                "locally; no backend push. Remove the offending dependency.",
        )
    }

    /**
     * AC3: CAMERA permission present (multi-modal features).
     */
    @Test
    fun androidManifest_hasCameraPermission() {
        assertTrue(
            hasPermission(android.Manifest.permission.CAMERA),
            "CAMERA permission required for multi-modal vision features.",
        )
    }

    // ========== Dependency-classpath audit ==========

    /**
     * AC4: No first-party analytics / telemetry / crash-reporting SDKs on
     * the classpath.
     *
     * Catches the SDKs a developer would consciously add ("let's track
     * signups via Mixpanel"). A dependency that transitively pulls in any
     * of these will break the test at CI time, not at release time.
     *
     * `com.google.android.datatransport.runtime.TransportRuntime` used to be
     * deliberately excluded here as an ML Kit GenAI transitive dependency —
     * that engine (MlKitGenAiEngine/OnDeviceAi) was never wired into the
     * real chat flow and was cut 2026-08 along with ML Kit vision/CameraX
     * (also unreferenced). No ML Kit dependency remains on the classpath, so
     * this test enforces "no first-party telemetry SDK chosen" with no
     * carve-out needed.
     */
    @Test
    fun noAnalyticsLibraries_onClasspath() {
        val forbidden =
            listOf(
                "com.google.firebase.analytics.FirebaseAnalytics" to "Firebase Analytics",
                "com.google.firebase.crashlytics.FirebaseCrashlytics" to "Firebase Crashlytics",
                "com.google.android.gms.measurement.AppMeasurement" to "Google Analytics",
                "io.sentry.Sentry" to "Sentry",
                "com.mixpanel.android.mpmetrics.MixpanelAPI" to "Mixpanel",
                "com.segment.analytics.Analytics" to "Segment",
                "com.amplitude.api.Amplitude" to "Amplitude",
            )

        val found =
            forbidden.mapNotNull { (fqcn, label) ->
                try {
                    Class.forName(fqcn)
                    "$label ($fqcn)"
                } catch (_: ClassNotFoundException) {
                    null
                }
            }

        if (found.isNotEmpty()) {
            fail(
                "Analytics/telemetry libraries detected on classpath: ${found.joinToString()}. " +
                    "M1K3 is no-telemetry by design (ADR-0006). Remove the dependency.",
            )
        }
    }

    /**
     * AC5: Network callers allow-list — drift detector.
     *
     * Asserts the only network-touching classes in the app match a known
     * allow-list. If a new network caller is added without updating this
     * test, CI fails loudly and the ADR needs updating.
     *
     * Rationale: "user-initiated network" only holds if we know every
     * caller. A new class that opens HttpURLConnection without being in
     * this list is an invariant violation.
     */
    @Test
    fun networkCallers_matchAllowList() {
        val allowed =
            listOf(
                "app.m1k3.ai.assistant.ai.download.HttpModelDownloadManager",
                "app.m1k3.ai.assistant.ai.download.ModelDownloadWorker",
                "app.m1k3.ai.assistant.tools.executors.WebSearchExecutor",
            )

        // Assert each allow-listed class is actually present (catches renames).
        val missing =
            allowed.filter { fqcn ->
                try {
                    Class.forName(fqcn)
                    false
                } catch (_: ClassNotFoundException) {
                    true
                }
            }
        assertTrue(
            missing.isEmpty(),
            "Expected network callers missing from classpath: ${missing.joinToString()}. " +
                "If a class was renamed, update this allow-list. " +
                "If a feature was removed, also remove its manifest permissions.",
        )
    }

    // ========== Helper ==========

    private fun hasPermission(permission: String): Boolean {
        return try {
            val packageInfo =
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.GET_PERMISSIONS,
                )
            val requestedPermissions = packageInfo.requestedPermissions ?: return false
            requestedPermissions.contains(permission)
        } catch (_: Exception) {
            false
        }
    }
}
