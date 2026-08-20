package app.m1k3.ai.assistant.avatar

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import kotlin.math.sin

/**
 * 間 AI Avatar Rendering Engine
 *
 * Canvas-based robot avatar renderer with emotion-aware features.
 * Draws minimalist robot using geometric primitives.
 */

object AvatarEngine {
    /**
     * Render complete robot avatar
     *
     * @param state Current avatar state (emotion, activity, intensity)
     * @param geometry Visual parameters (sizes, positions)
     * @param animation Animation parameters (bounce, rotation)
     */
    fun DrawScope.drawRobotAvatar(
        state: AvatarState,
        geometry: RobotGeometry = RobotGeometry(),
        animation: AvatarAnimation = AvatarAnimation()
    ) {
        val centerX = size.width / 2f
        val centerY = size.height / 2f

        // Apply animation offsets - always animate, reduce intensity when idle
        val bounceIntensity = if (state.activity.isActive) 1f else 0.3f
        val bounceOffset = sin(state.animationProgress * Math.PI * 2).toFloat() *
            animation.bounceHeight * bounceIntensity

        val emotionColor = state.displayColor

        // Draw antenna with pulsing glow
        drawAntenna(
            center = Offset(centerX, centerY - geometry.headSize / 2),
            geometry = geometry,
            color = emotionColor,
            isActive = state.isAnimating,
            animationProgress = state.animationProgress
        )

        // Draw head
        drawHead(
            center = Offset(centerX, centerY + bounceOffset),
            geometry = geometry,
            color = emotionColor
        )

        // Blinking animation - blink every ~5 seconds
        val blinkCycle = 5f  // Seconds between blinks (at 2s animation loop)
        val blinkDuration = 0.03f  // 3% of cycle (quick blink)
        val cyclePosition = state.animationProgress % (blinkCycle / 2f)
        val shouldBlink = cyclePosition < blinkDuration

        // Draw eyes based on emotion (use SLEEPY for closed eyes when blinking)
        drawEyes(
            center = Offset(centerX, centerY + bounceOffset + geometry.eyeVerticalOffset),
            emotion = if (shouldBlink) AvatarEmotion.SLEEPY else state.emotion,
            geometry = geometry,
            color = emotionColor
        )

        // Draw mouth based on emotion
        drawMouth(
            center = Offset(centerX, centerY + bounceOffset + geometry.mouthVerticalOffset),
            emotion = state.emotion,
            geometry = geometry,
            color = emotionColor,
            intensity = state.intensity
        )
    }

    /**
     * Draw robot head (rounded rectangle)
     */
    private fun DrawScope.drawHead(
        center: Offset,
        geometry: RobotGeometry,
        color: Color
    ) {
        val headRect = RoundRect(
            rect = Rect(
                left = center.x - geometry.headSize / 2,
                top = center.y - geometry.headSize / 2,
                right = center.x + geometry.headSize / 2,
                bottom = center.y + geometry.headSize / 2
            ),
            cornerRadius = CornerRadius(geometry.headCornerRadius)
        )

        // Fill
        drawRoundRect(
            color = geometry.backgroundColor,
            topLeft = Offset(headRect.left, headRect.top),
            size = Size(headRect.width, headRect.height),
            cornerRadius = CornerRadius(geometry.headCornerRadius)
        )

        // Emotion color tint overlay
        drawRoundRect(
            color = color.copy(alpha = 0.1f),
            topLeft = Offset(headRect.left, headRect.top),
            size = Size(headRect.width, headRect.height),
            cornerRadius = CornerRadius(geometry.headCornerRadius)
        )

        // Outline
        drawRoundRect(
            color = geometry.outlineColor,
            topLeft = Offset(headRect.left, headRect.top),
            size = Size(headRect.width, headRect.height),
            cornerRadius = CornerRadius(geometry.headCornerRadius),
            style = Stroke(width = geometry.outlineWidth)
        )
    }

    /**
     * Draw antenna with glowing bulb (pulsing animation)
     */
    private fun DrawScope.drawAntenna(
        center: Offset,
        geometry: RobotGeometry,
        color: Color,
        isActive: Boolean,
        animationProgress: Float = 0f
    ) {
        // Antenna stem
        drawLine(
            color = geometry.outlineColor,
            start = center,
            end = Offset(center.x, center.y - geometry.antennaHeight),
            strokeWidth = geometry.antennaWidth
        )

        // Antenna bulb
        val bulbAlpha = if (isActive) 1.0f else 0.6f
        drawCircle(
            color = color.copy(alpha = bulbAlpha),
            radius = geometry.antennaBulbRadius,
            center = Offset(center.x, center.y - geometry.antennaHeight)
        )

        // Bulb outline
        drawCircle(
            color = geometry.outlineColor,
            radius = geometry.antennaBulbRadius,
            center = Offset(center.x, center.y - geometry.antennaHeight),
            style = Stroke(width = geometry.outlineWidth)
        )

        // Pulsing glow effect (always visible, more intense when active)
        val glowIntensity = sin(animationProgress * Math.PI * 2).toFloat() * 0.5f + 0.5f
        val baseAlpha = if (isActive) 0.4f else 0.2f
        drawCircle(
            color = color.copy(alpha = baseAlpha * glowIntensity),
            radius = geometry.antennaBulbRadius * (1.5f + glowIntensity * 0.3f),
            center = Offset(center.x, center.y - geometry.antennaHeight)
        )
    }

    /**
     * Draw eyes based on emotion
     */
    private fun DrawScope.drawEyes(
        center: Offset,
        emotion: AvatarEmotion,
        geometry: RobotGeometry,
        color: Color
    ) {
        val leftEyeX = center.x - geometry.eyeSpacing / 2
        val rightEyeX = center.x + geometry.eyeSpacing / 2

        when (emotion) {
            AvatarEmotion.HAPPY -> {
                // Curved happy eyes (arcs)
                drawHappyEyes(leftEyeX, rightEyeX, center.y, geometry, color)
            }
            AvatarEmotion.SAD -> {
                // Downward curved sad eyes
                drawSadEyes(leftEyeX, rightEyeX, center.y, geometry, color)
            }
            AvatarEmotion.ANGRY -> {
                // Angled angry eyes
                drawAngryEyes(leftEyeX, rightEyeX, center.y, geometry, color)
            }
            AvatarEmotion.SURPRISED -> {
                // Wide circular eyes
                drawSurprisedEyes(leftEyeX, rightEyeX, center.y, geometry, color)
            }
            AvatarEmotion.LOVE -> {
                // Heart-shaped eyes
                drawLoveEyes(leftEyeX, rightEyeX, center.y, geometry, color)
            }
            AvatarEmotion.THINKING -> {
                // Squinted analytical eyes
                drawThinkingEyes(leftEyeX, rightEyeX, center.y, geometry, color)
            }
            AvatarEmotion.SLEEPY -> {
                // Half-closed drowsy eyes
                drawSleepyEyes(leftEyeX, rightEyeX, center.y, geometry, color)
            }
            AvatarEmotion.EXCITED -> {
                // Wide energetic eyes with sparkle
                drawExcitedEyes(leftEyeX, rightEyeX, center.y, geometry, color)
            }
            AvatarEmotion.NEUTRAL -> {
                // Simple horizontal lines
                drawNeutralEyes(leftEyeX, rightEyeX, center.y, geometry, color)
            }
        }
    }

    private fun DrawScope.drawNeutralEyes(
        leftX: Float, rightX: Float, y: Float,
        geometry: RobotGeometry, color: Color
    ) {
        // Left eye
        drawLine(
            color = color,
            start = Offset(leftX - geometry.eyeWidth / 2, y),
            end = Offset(leftX + geometry.eyeWidth / 2, y),
            strokeWidth = geometry.eyeHeight
        )
        // Right eye
        drawLine(
            color = color,
            start = Offset(rightX - geometry.eyeWidth / 2, y),
            end = Offset(rightX + geometry.eyeWidth / 2, y),
            strokeWidth = geometry.eyeHeight
        )
    }

    private fun DrawScope.drawHappyEyes(
        leftX: Float, rightX: Float, y: Float,
        geometry: RobotGeometry, color: Color
    ) {
        val path = Path()
        // Left eye (curved upward)
        path.moveTo(leftX - geometry.eyeWidth / 2, y)
        path.quadraticBezierTo(
            leftX, y - 10f,
            leftX + geometry.eyeWidth / 2, y
        )
        drawPath(path, color, style = Stroke(width = geometry.eyeHeight))

        val path2 = Path()
        // Right eye (curved upward)
        path2.moveTo(rightX - geometry.eyeWidth / 2, y)
        path2.quadraticBezierTo(
            rightX, y - 10f,
            rightX + geometry.eyeWidth / 2, y
        )
        drawPath(path2, color, style = Stroke(width = geometry.eyeHeight))
    }

    private fun DrawScope.drawSadEyes(
        leftX: Float, rightX: Float, y: Float,
        geometry: RobotGeometry, color: Color
    ) {
        val path = Path()
        // Left eye (curved downward)
        path.moveTo(leftX - geometry.eyeWidth / 2, y)
        path.quadraticBezierTo(
            leftX, y + 10f,
            leftX + geometry.eyeWidth / 2, y
        )
        drawPath(path, color, style = Stroke(width = geometry.eyeHeight))

        val path2 = Path()
        // Right eye (curved downward)
        path2.moveTo(rightX - geometry.eyeWidth / 2, y)
        path2.quadraticBezierTo(
            rightX, y + 10f,
            rightX + geometry.eyeWidth / 2, y
        )
        drawPath(path2, color, style = Stroke(width = geometry.eyeHeight))
    }

    private fun DrawScope.drawAngryEyes(
        leftX: Float, rightX: Float, y: Float,
        geometry: RobotGeometry, color: Color
    ) {
        // Left eye (angled downward toward center)
        drawLine(
            color = color,
            start = Offset(leftX - geometry.eyeWidth / 2, y - 8f),
            end = Offset(leftX + geometry.eyeWidth / 2, y + 4f),
            strokeWidth = geometry.eyeHeight
        )
        // Right eye (angled downward toward center)
        drawLine(
            color = color,
            start = Offset(rightX - geometry.eyeWidth / 2, y + 4f),
            end = Offset(rightX + geometry.eyeWidth / 2, y - 8f),
            strokeWidth = geometry.eyeHeight
        )
    }

    private fun DrawScope.drawSurprisedEyes(
        leftX: Float, rightX: Float, y: Float,
        geometry: RobotGeometry, color: Color
    ) {
        val radius = geometry.eyeWidth / 2
        // Left eye (circle)
        drawCircle(color = color, radius = radius, center = Offset(leftX, y))
        // Right eye (circle)
        drawCircle(color = color, radius = radius, center = Offset(rightX, y))
    }

    private fun DrawScope.drawLoveEyes(
        leftX: Float, rightX: Float, y: Float,
        geometry: RobotGeometry, color: Color
    ) {
        val heartSize = geometry.eyeWidth / 2
        // Left heart
        drawHeart(Offset(leftX, y), heartSize, color)
        // Right heart
        drawHeart(Offset(rightX, y), heartSize, color)
    }

    private fun DrawScope.drawHeart(center: Offset, size: Float, color: Color) {
        val path = Path()
        path.moveTo(center.x, center.y + size / 2)
        path.cubicTo(
            center.x - size, center.y - size / 2,
            center.x - size / 2, center.y - size,
            center.x, center.y - size / 4
        )
        path.cubicTo(
            center.x + size / 2, center.y - size,
            center.x + size, center.y - size / 2,
            center.x, center.y + size / 2
        )
        drawPath(path, color)
    }

    private fun DrawScope.drawThinkingEyes(
        leftX: Float, rightX: Float, y: Float,
        geometry: RobotGeometry, color: Color
    ) {
        // Squinted eyes (short lines)
        drawLine(
            color = color,
            start = Offset(leftX - geometry.eyeWidth / 3, y),
            end = Offset(leftX + geometry.eyeWidth / 3, y),
            strokeWidth = geometry.eyeHeight * 0.7f
        )
        drawLine(
            color = color,
            start = Offset(rightX - geometry.eyeWidth / 3, y),
            end = Offset(rightX + geometry.eyeWidth / 3, y),
            strokeWidth = geometry.eyeHeight * 0.7f
        )
    }

    private fun DrawScope.drawSleepyEyes(
        leftX: Float, rightX: Float, y: Float,
        geometry: RobotGeometry, color: Color
    ) {
        // Half-closed (horizontal line with droop)
        drawLine(
            color = color,
            start = Offset(leftX - geometry.eyeWidth / 2, y + 3f),
            end = Offset(leftX + geometry.eyeWidth / 2, y + 3f),
            strokeWidth = geometry.eyeHeight
        )
        drawLine(
            color = color,
            start = Offset(rightX - geometry.eyeWidth / 2, y + 3f),
            end = Offset(rightX + geometry.eyeWidth / 2, y + 3f),
            strokeWidth = geometry.eyeHeight
        )
    }

    private fun DrawScope.drawExcitedEyes(
        leftX: Float, rightX: Float, y: Float,
        geometry: RobotGeometry, color: Color
    ) {
        val radius = geometry.eyeWidth / 2.2f
        // Wide eyes
        drawCircle(color = color, radius = radius, center = Offset(leftX, y))
        drawCircle(color = color, radius = radius, center = Offset(rightX, y))

        // Sparkles
        drawLine(
            color = color.copy(alpha = 0.6f),
            start = Offset(leftX - 5f, y - radius - 8f),
            end = Offset(leftX + 5f, y - radius - 8f),
            strokeWidth = 2f
        )
        drawLine(
            color = color.copy(alpha = 0.6f),
            start = Offset(leftX, y - radius - 13f),
            end = Offset(leftX, y - radius - 3f),
            strokeWidth = 2f
        )
    }

    /**
     * Draw mouth based on emotion
     */
    private fun DrawScope.drawMouth(
        center: Offset,
        emotion: AvatarEmotion,
        geometry: RobotGeometry,
        color: Color,
        intensity: Float
    ) {
        val mouthY = center.y
        val mouthHalfWidth = geometry.mouthWidth / 2

        when (emotion) {
            AvatarEmotion.HAPPY, AvatarEmotion.LOVE, AvatarEmotion.EXCITED -> {
                // Smile (curved upward)
                val path = Path()
                path.moveTo(center.x - mouthHalfWidth, mouthY)
                path.quadraticBezierTo(
                    center.x, mouthY + 15f * intensity,
                    center.x + mouthHalfWidth, mouthY
                )
                drawPath(path, color, style = Stroke(width = geometry.mouthHeight))
            }
            AvatarEmotion.SAD, AvatarEmotion.SLEEPY -> {
                // Frown (curved downward)
                val path = Path()
                path.moveTo(center.x - mouthHalfWidth, mouthY)
                path.quadraticBezierTo(
                    center.x, mouthY - 15f * intensity,
                    center.x + mouthHalfWidth, mouthY
                )
                drawPath(path, color, style = Stroke(width = geometry.mouthHeight))
            }
            AvatarEmotion.ANGRY -> {
                // Angry frown with sharp angle
                drawLine(
                    color = color,
                    start = Offset(center.x - mouthHalfWidth, mouthY - 8f),
                    end = Offset(center.x, mouthY),
                    strokeWidth = geometry.mouthHeight
                )
                drawLine(
                    color = color,
                    start = Offset(center.x, mouthY),
                    end = Offset(center.x + mouthHalfWidth, mouthY - 8f),
                    strokeWidth = geometry.mouthHeight
                )
            }
            AvatarEmotion.SURPRISED -> {
                // Open circle mouth
                drawCircle(
                    color = color,
                    radius = geometry.mouthWidth / 4,
                    center = Offset(center.x, mouthY),
                    style = Stroke(width = geometry.mouthHeight)
                )
            }
            AvatarEmotion.THINKING -> {
                // Small wavy line
                val path = Path()
                path.moveTo(center.x - mouthHalfWidth / 2, mouthY)
                path.quadraticBezierTo(
                    center.x - mouthHalfWidth / 4, mouthY - 5f,
                    center.x, mouthY
                )
                path.quadraticBezierTo(
                    center.x + mouthHalfWidth / 4, mouthY + 5f,
                    center.x + mouthHalfWidth / 2, mouthY
                )
                drawPath(path, color, style = Stroke(width = geometry.mouthHeight * 0.8f))
            }
            AvatarEmotion.NEUTRAL -> {
                // Straight line
                drawLine(
                    color = color,
                    start = Offset(center.x - mouthHalfWidth, mouthY),
                    end = Offset(center.x + mouthHalfWidth, mouthY),
                    strokeWidth = geometry.mouthHeight
                )
            }
        }
    }

}

/**
 * Usage Example:
 * ```kotlin
 * // Basic robot avatar
 * Canvas(modifier = Modifier.size(280.dp)) {
 *     with(AvatarEngine) {
 *         drawRobotAvatar(
 *             state = AvatarState(
 *                 emotion = AvatarEmotion.HAPPY,
 *                 activity = AvatarActivity.SPEAKING,
 *                 intensity = 0.8f
 *             )
 *         )
 *     }
 * }
 *
 * ```
 */
