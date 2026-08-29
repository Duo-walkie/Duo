package app.oneone.one_one_app

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View
import android.view.animation.LinearInterpolator

/**
 * Hey-Google-style horizontal bar visualizer. Each bar springs toward its
 * target height (driven by live [AudioRecord]/[MediaRecorder] amplitude)
 * with critically-damped easing so the motion reads as alive, not jittery.
 */
class AssistantOrbView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    private val barCount = 5
    private val targets = FloatArray(barCount) { 0.12f }
    private val current = FloatArray(barCount) { 0.12f }
    private val velocities = FloatArray(barCount)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = Color.parseColor("#F8BE03")
    }
    private var accentColor: Int = Color.parseColor("#F8BE03")
    private val animator = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = 16
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener { step() }
    }

    init {
        setWillNotDraw(false)
    }

    fun setAccentColor(color: Int) {
        accentColor = color
        paint.color = color
        invalidate()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        animator.start()
    }

    override fun onDetachedFromWindow() {
        animator.cancel()
        super.onDetachedFromWindow()
    }

    /** [level] is normalized 0f (silence) .. 1f (loud). */
    fun setLevel(level: Float) {
        val clamped = level.coerceIn(0f, 1f)
        for (i in 0 until barCount) {
            // Slight per-bar phase offset so bars don't move in lockstep —
            // reads as a natural voice waveform rather than a VU meter.
            val phase = 1f - (kotlin.math.abs(i - barCount / 2) * 0.12f)
            targets[i] = (0.12f + clamped * 0.88f * phase).coerceIn(0.08f, 1f)
        }
    }

    fun reset() {
        for (i in 0 until barCount) targets[i] = 0.12f
    }

    private fun step() {
        var changed = false
        for (i in 0 until barCount) {
            val delta = targets[i] - current[i]
            // Critically-damped spring: no overshoot, no harsh snapping.
            velocities[i] = velocities[i] * 0.72f + delta * 0.35f
            current[i] += velocities[i]
            if (kotlin.math.abs(delta) > 0.001f || kotlin.math.abs(velocities[i]) > 0.001f) {
                changed = true
            }
        }
        if (changed) invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return
        val gap = w * 0.06f
        val barWidth = (w - gap * (barCount - 1)) / barCount
        var x = 0f
        for (i in 0 until barCount) {
            val barHeight = (h * current[i]).coerceAtLeast(barWidth)
            val top = (h - barHeight) / 2f
            val radius = barWidth / 2f
            canvas.drawRoundRect(x, top, x + barWidth, top + barHeight, radius, radius, paint)
            x += barWidth + gap
        }
    }
}
