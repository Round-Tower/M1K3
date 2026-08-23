package app.m1k3.ai.assistant.avatar

import android.view.Choreographer
import android.view.TextureView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import app.m1k3.ai.assistant.utils.Logger
import com.google.android.filament.View
import com.google.android.filament.android.UiHelper
import com.google.android.filament.utils.ModelViewer
import com.google.android.filament.utils.Utils
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
 * inside the view hierarchy — the [CrtOverlay] Compose layer draws *over*
 * it. Transparent (isOpaque=false swapchain + alpha-0 clear + no skybox) so
 * it floats over the app's charcoal background. A slow auto-rotate keeps it
 * alive without a heavy idle clip; [Survey] plays underneath for the gentle
 * head turns.
 *
 * ⚠️ Only ever mounted behind [Companion3DPolicy] (brain resident + memory
 * headroom) — Filament co-initialising with the LLM once OOM'd an 8 GB device.
 * Lifecycle: the Choreographer loop stops and the Engine is destroyed in
 * [DisposableEffect]'s onDispose.
 *
 * MurphySig: kev+claude-opus-4-8 / confidence 0.72 / 2026-08-23
 * Rationale: Filament-core-direct is the only maintained 3D path on this
 * toolchain; on-screen result is verify-at-run, as Filament always is.
 * Prior: companion-fox-3d-plan.md; SharedModelCache.kt (SceneView era).
 */
@Composable
fun Companion3DView(
    rotationSpeed: Float,
    modifier: Modifier = Modifier,
) {
    // Latest rotation speed, read inside the frame callback without
    // re-subscribing the Choreographer each recomposition.
    val speedState = remember { mutableStateOf(rotationSpeed) }
    speedState.value = rotationSpeed

    val holder = remember { FoxSceneHolder() }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            TextureView(context).also { textureView ->
                textureView.isOpaque = false
                holder.attach(textureView, speedState)
                runCatching {
                    val bytes = context.assets.open("companions/fox.glb").use { it.readBytes() }
                    holder.load(bytes)
                }.onFailure { logger.e(it) { "Failed to load fox.glb" } }
            }
        },
    )

    DisposableEffect(Unit) {
        onDispose { holder.destroy() }
    }
}

/**
 * Owns the Filament [ModelViewer], the Choreographer loop and teardown. Kept
 * off the composable so its imperative lifecycle is explicit and disposable.
 */
private class FoxSceneHolder {
    private var modelViewer: ModelViewer? = null
    private var choreographer: Choreographer? = null
    private var frameCallback: Choreographer.FrameCallback? = null
    private var startNanos = 0L
    private var destroyed = false
    private val baseTransform = FloatArray(16)
    private var haveBase = false

    fun attach(
        textureView: TextureView,
        speed: androidx.compose.runtime.State<Float>,
    ) {
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
        // emissive-only model. Open right up (EV ~1) so the amber wire glows
        // and crosses the bloom threshold.
        viewer.camera.setExposure(1.0f, 0.5f, 100.0f)

        val chore = Choreographer.getInstance()
        choreographer = chore
        val cb =
            object : Choreographer.FrameCallback {
                override fun doFrame(frameTimeNanos: Long) {
                    if (destroyed) return
                    if (startNanos == 0L) startNanos = frameTimeNanos
                    val seconds = (frameTimeNanos - startNanos) / 1_000_000_000.0

                    val mv = modelViewer
                    if (mv != null) {
                        mv.animator?.let { anim ->
                            if (anim.animationCount > 0) {
                                // Survey (index 1 of Run/Survey/Walk) — the
                                // calm idle head-turns.
                                val clip = if (anim.animationCount > 1) 1 else 0
                                anim.applyAnimation(clip, seconds.toFloat())
                                anim.updateBoneMatrices()
                            }
                        }
                        rotate(mv, seconds, speed.value)
                        mv.render(frameTimeNanos)
                    }
                    chore.postFrameCallback(this)
                }
            }
        frameCallback = cb
        chore.postFrameCallback(cb)
    }

    fun load(glb: ByteArray) {
        val mv = modelViewer ?: return
        mv.loadModelGlb(ByteBuffer.wrap(glb))
        mv.transformToUnitCube()
        val asset = mv.asset
        if (asset != null) {
            val instance = mv.engine.transformManager.getInstance(asset.root)
            if (instance != 0) {
                mv.engine.transformManager.getTransform(instance, baseTransform)
                haveBase = true
            }
            logger.i { "fox.glb loaded (${asset.entities.size} entities, ${mv.animator?.animationCount ?: 0} clips)" }
        } else {
            logger.e { "fox.glb: asset was null after load" }
        }
    }

    private fun rotate(
        mv: ModelViewer,
        seconds: Double,
        speed: Float,
    ) {
        if (!haveBase) return
        val asset = mv.asset ?: return
        val tm = mv.engine.transformManager
        val instance = tm.getInstance(asset.root)
        if (instance == 0) return
        val angle = (seconds * speed).toFloat()
        val c = kotlin.math.cos(angle)
        val s = kotlin.math.sin(angle)
        // Column-major Y rotation, applied AROUND the unit-cube-centred model:
        // world = rotY * base (base = transformToUnitCube's centre+scale).
        val rotY =
            floatArrayOf(
                c, 0f, -s, 0f,
                0f, 1f, 0f, 0f,
                s, 0f, c, 0f,
                0f, 0f, 0f, 1f,
            )
        tm.setTransform(instance, mul(rotY, baseTransform))
    }

    /** Column-major 4x4 multiply: result = a * b. */
    private fun mul(
        a: FloatArray,
        b: FloatArray,
    ): FloatArray {
        val r = FloatArray(16)
        for (col in 0 until 4) {
            for (row in 0 until 4) {
                var sum = 0f
                for (k in 0 until 4) {
                    sum += a[k * 4 + row] * b[col * 4 + k]
                }
                r[col * 4 + row] = sum
            }
        }
        return r
    }

    fun destroy() {
        if (destroyed) return
        destroyed = true
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
