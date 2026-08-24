package app.m1k3.ai.assistant.avatar

import android.view.Choreographer
import android.view.TextureView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.m1k3.ai.assistant.utils.Logger
import com.google.android.filament.ColorGrading
import com.google.android.filament.View
import com.google.android.filament.android.UiHelper
import com.google.android.filament.utils.ModelViewer
import com.google.android.filament.utils.Utils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer

private val logger = Logger.withTag("Companion3DView")

/**
 * The 3D Phosphor Fox, rendered with Filament core (not SceneView — cut in the
 * reduction, and stuck at 2.3.0 against this Kotlin 2.4.10 / CMP 1.11.1
 * toolchain). Loads the baked amber-wire glb from
 * `assets/companions/fox.glb` — a dark body plus an *emissive* triangle
 * lattice, so the wire self-illuminates against the charcoal even with no
 * scene lighting. Bloom turns that emission into a phosphor glow; the
 * [CrtOverlay] laid on top adds the scanlines, vignette and flicker.
 *
 * Rendered into a [TextureView] (not a z-on-top SurfaceView) so it composits
 * inside the view hierarchy — the [CrtOverlay] Compose layer draws *over* it.
 * Transparent (isOpaque=false swapchain + alpha-0 clear + no skybox) so it
 * floats over the charcoal. The fox renders STATIC (the CRT overlay carries the
 * motion) — a self-spin about the root swung it out of frame, and the Khronos
 * clips carry root motion that walks it off-frame.
 *
 * Robustness (per review):
 *  - The ~950 KB glb is read on [Dispatchers.IO], not the main thread, then
 *    handed to Filament on the main thread.
 *  - Any attach/load failure fires [onFailure] so the hero can fall back to the
 *    2D face instead of stranding the user on an empty CRT.
 *  - The Choreographer render loop pauses on `ON_PAUSE` and resumes on
 *    `ON_RESUME`, so it never burns GPU (or renders to a torn-down surface)
 *    while the app is backgrounded.
 *
 * ⚠️ Only ever mounted behind [Companion3DPolicy] (brain resident + memory
 * headroom) — Filament co-initialising with the LLM once OOM'd an 8 GB device.
 *
 * MurphySig: kev+claude-opus-4-8 / confidence 0.78 / 2026-08-24
 * Prior: companion-fox-3d-plan.md; SharedModelCache.kt (SceneView era).
 */
@Composable
fun Companion3DView(
    modifier: Modifier = Modifier,
    onFailure: () -> Unit = {},
) {
    val holder = remember { FoxSceneHolder() }
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()

    AndroidView(
        modifier = modifier,
        factory = { context ->
            TextureView(context).also { textureView ->
                textureView.isOpaque = false
                scope.launch {
                    val bytes =
                        withContext(Dispatchers.IO) {
                            runCatching {
                                context.assets.open("companions/fox.glb").use { it.readBytes() }
                            }.getOrNull()
                        }
                    if (bytes == null) {
                        logger.e { "fox.glb read failed" }
                        onFailure()
                        return@launch
                    }
                    // Back on the main thread — Filament wants the GL thread.
                    val ok =
                        runCatching {
                            holder.attach(textureView)
                            holder.load(bytes)
                            holder.resume()
                        }.onFailure { logger.e(it) { "fox attach/load failed" } }.isSuccess
                    if (!ok) onFailure()
                }
            }
        },
    )

    DisposableEffect(lifecycleOwner) {
        val observer =
            LifecycleEventObserver { _, event ->
                when (event) {
                    Lifecycle.Event.ON_PAUSE -> holder.pause()
                    Lifecycle.Event.ON_RESUME -> holder.resume()
                    else -> Unit
                }
            }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            holder.destroy()
        }
    }
}

/**
 * Owns the Filament [ModelViewer], the Choreographer loop and teardown. Kept
 * off the composable so its imperative lifecycle is explicit and disposable.
 * Every method runs on the main thread (Choreographer callbacks, Compose
 * lifecycle events, and the post-IO continuation are all main-thread), so the
 * flags need no synchronisation.
 */
private class FoxSceneHolder {
    private var modelViewer: ModelViewer? = null
    private var choreographer: Choreographer? = null
    private var frameCallback: Choreographer.FrameCallback? = null
    private var loaded = false
    private var running = false
    private var destroyed = false

    fun attach(textureView: TextureView) {
        if (destroyed) return
        val viewer =
            ModelViewer(
                textureView = textureView,
                uiHelper =
                    UiHelper(UiHelper.ContextErrorPolicy.DONT_CHECK).apply {
                        isOpaque = false
                    },
            )
        modelViewer = viewer

        // Float over the charcoal: no skybox, translucent blend, alpha-0 clear.
        viewer.scene.skybox = null
        viewer.view.blendMode = View.BlendMode.TRANSLUCENT
        viewer.renderer.clearOptions =
            viewer.renderer.clearOptions.apply {
                // Default clearColor is already transparent black {0,0,0,0};
                // just enable the clear so the tube shows through.
                clear = true
            }

        // Bloom turns the emissive amber wire into a phosphor glow.
        viewer.view.bloomOptions =
            viewer.view.bloomOptions.apply {
                enabled = true
                strength = 0.55f
            }

        // The default camera is f/16 daylight — far too dark for an
        // emissive-only model. Open right up (EV ~1) so the wire glows and
        // crosses the bloom threshold.
        viewer.camera.setExposure(1.0f, 0.5f, 100.0f)

        // The ACES tonemapper desaturates the bright emissive toward white,
        // and a Compose overlay can't tint a separate render surface — so the
        // amber phosphor is graded in-Filament: warm white balance + a red-
        // biased channel mix push the cream fox toward the M1K3 tube glow.
        viewer.view.colorGrading =
            ColorGrading
                .Builder()
                .whiteBalance(-0.6f, 0.1f)
                .channelMixer(
                    floatArrayOf(1.0f, 0.0f, 0.0f),
                    floatArrayOf(0.35f, 0.55f, 0.0f),
                    floatArrayOf(0.05f, 0.10f, 0.20f),
                ).build(viewer.engine)

        choreographer = Choreographer.getInstance()
        frameCallback =
            object : Choreographer.FrameCallback {
                override fun doFrame(frameTimeNanos: Long) {
                    if (destroyed || !running) return
                    modelViewer?.render(frameTimeNanos)
                    choreographer?.postFrameCallback(this)
                }
            }
    }

    fun load(glb: ByteArray) {
        val mv = modelViewer ?: return
        if (destroyed) return
        mv.loadModelGlb(ByteBuffer.wrap(glb))
        mv.transformToUnitCube()
        loaded = true
    }

    /** Start (or resume) the render loop — no-op unless attached + loaded. */
    fun resume() {
        if (destroyed || running || !loaded) return
        val cb = frameCallback ?: return
        running = true
        choreographer?.postFrameCallback(cb)
    }

    /** Stop rendering while backgrounded; safe to call repeatedly. */
    fun pause() {
        running = false
        frameCallback?.let { choreographer?.removeFrameCallback(it) }
    }

    fun destroy() {
        if (destroyed) return
        destroyed = true
        running = false
        frameCallback?.let { choreographer?.removeFrameCallback(it) }
        frameCallback = null
        choreographer = null
        runCatching { modelViewer?.destroy() }
            .onFailure { logger.e(it) { "ModelViewer destroy failed" } }
        modelViewer = null
    }

    companion object {
        init {
            // Loads filament-jni + gltfio-jni + filament-utils-jni once.
            Utils.init()
        }
    }
}
