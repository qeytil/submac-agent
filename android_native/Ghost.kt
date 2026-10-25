package com.submac.agent

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The "SubMac is using your phone" layer: a red dot that shows each tap, swipe, scroll and
 * keystroke on top of the app the agent is driving, plus a small badge at the top with Stop.
 * Both are accessibility overlays (no extra permission) and never take touches except Stop.
 */
class Ghost(private val svc: SubMacA11y) {
    private val wm = svc.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val main = Handler(Looper.getMainLooper())
    private var layer: GhostView? = null
    private var badge: View? = null
    private var badgeDot: View? = null
    private var breath: ValueAnimator? = null
    private val autoHide: Runnable = Runnable { hideBadge() }

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, svc.resources.displayMetrics)

    private fun ensureLayer(): GhostView? {
        layer?.let { return it }
        return try {
            val v = GhostView(svc)
            val lp = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT
            )
            lp.gravity = Gravity.TOP or Gravity.START
            wm.addView(v, lp)
            layer = v
            v
        } catch (_: Throwable) { null }
    }

    /** Called before every action: keeps the badge up while the agent works. */
    fun active() {
        if (ScreenGuard.stale()) return // a step from a task that was already stopped never brings the badge back
        // The check above runs on the step's thread; Stop can land before this post runs on the main thread, so the
        // generation is checked again there (ISSUES T-16: the badge came back for up to 45 s after Stop).
        val g = ScreenGuard.mine()
        main.post {
            if (g != ScreenGuard.gen) return@post
            showBadge()
            main.removeCallbacks(autoHide)
            main.postDelayed(autoHide, 45_000)
        }
    }

    fun tap(x: Float, y: Float, long: Boolean = false) { if (ScreenGuard.stale()) return; val g = ScreenGuard.mine(); active(); main.post { if (g == ScreenGuard.gen) ensureLayer()?.add(Fx.Tap(x, y, long)) } }
    fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, ms: Long) { if (ScreenGuard.stale()) return; val g = ScreenGuard.mine(); active(); main.post { if (g == ScreenGuard.gen) ensureLayer()?.add(Fx.Swipe(x1, y1, x2, y2, ms)) } }
    fun type(r: RectF) { if (ScreenGuard.stale()) return; val g = ScreenGuard.mine(); active(); main.post { if (g == ScreenGuard.gen) ensureLayer()?.add(Fx.Type(r)) } }

    /** Hides the effects for a moment so a screenshot shows only the app, then runs [then]. */
    fun hiddenFor(then: () -> Unit) {
        main.post {
            layer?.visibility = View.INVISIBLE
            badge?.visibility = View.INVISIBLE
            TaskBubble.hiddenForShot(true)
            main.postDelayed({ then() }, 64)
        }
    }

    fun reveal() {
        main.post {
            layer?.visibility = View.VISIBLE
            badge?.visibility = View.VISIBLE
            TaskBubble.hiddenForShot(false)
        }
    }

    fun showBadge() {
        if (badge != null) return
        try {
            val pill = LinearLayout(svc).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(12f).toInt(), dp(7f).toInt(), dp(6f).toInt(), dp(7f).toInt())
                background = GradientDrawable().apply {
                    cornerRadius = dp(20f)
                    setColor(0xF2171510.toInt())
                }
                elevation = dp(6f)
            }
            val dot = View(svc).apply {
                background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(RED) }
            }
            // no coloured dot: a quiet text badge
            pill.addView(TextView(svc).apply {
                text = "SubMac is using your phone"
                setTextColor(0xFFF4F0E7.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            })
            val stop = TextView(svc).apply {
                text = "Stop"
                setTextColor(0xFF17150F.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                paint.isFakeBoldText = true
                setPadding(dp(12f).toInt(), dp(5f).toInt(), dp(12f).toInt(), dp(5f).toInt())
                background = GradientDrawable().apply { cornerRadius = dp(16f); setColor(0xFFF4F0E7.toInt()) }
                setOnClickListener {
                    Bridge.send("phoneStop")
                    ScreenGuard.halt() // steps still queued for this task do nothing
                    TaskBubble.hide()
                    hideBadge()
                }
            }
            pill.addView(stop, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                marginStart = dp(12f).toInt()
            })
            val lp = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                PixelFormat.TRANSLUCENT
            )
            lp.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            lp.y = dp(34f).toInt()
            pill.alpha = 0f
            pill.translationY = -dp(16f)
            wm.addView(pill, lp)
            pill.animate().alpha(1f).translationY(0f).setDuration(380).setInterpolator(OvershootInterpolator(1.1f)).start()
            badge = pill
            badgeDot = dot
        } catch (_: Throwable) {}
    }

    fun hideBadge() {
        main.post { doHide() }
    }

    private fun doHide() {
        main.removeCallbacks(autoHide)
        breath?.cancel(); breath = null
        val l = layer
        layer = null
        if (l != null) main.postDelayed({ try { wm.removeView(l) } catch (_: Throwable) {} }, 900)
        val b = badge ?: return
        badge = null; badgeDot = null
        b.animate().alpha(0f).translationY(-dp(12f)).setDuration(220).withEndAction {
            try { wm.removeView(b) } catch (_: Throwable) {}
        }.start()
    }

    companion object { const val RED = 0xFF8E8E93.toInt() } // calm system gray: visible on light and dark apps
}

sealed class Fx {
    val start = SystemClock.uptimeMillis()
    abstract val life: Long

    class Tap(val x: Float, val y: Float, val long: Boolean) : Fx() { override val life = if (long) 1300L else 750L }
    class Swipe(val x1: Float, val y1: Float, val x2: Float, val y2: Float, val ms: Long) : Fx() { override val life = ms + 450 }
    class Type(val r: RectF) : Fx() { override val life = 1100L }
}

class GhostView(ctx: Context) : View(ctx) {
    private val fx = ArrayList<Fx>()
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Ghost.RED }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Ghost.RED; style = Paint.Style.STROKE }
    private val glow = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Ghost.RED }
    private val dec = DecelerateInterpolator(2f)
    private val d = ctx.resources.displayMetrics.density

    init { setLayerType(LAYER_TYPE_HARDWARE, null) }

    fun add(f: Fx) {
        fx.add(f)
        postInvalidateOnAnimation()
    }

    override fun onDraw(c: Canvas) {
        val now = SystemClock.uptimeMillis()
        fx.removeAll { now - it.start > it.life }
        for (f in fx) {
            val t = ((now - f.start).toFloat() / f.life).coerceIn(0f, 1f)
            when (f) {
                is Fx.Tap -> drawTap(c, f, now - f.start, t)
                is Fx.Swipe -> drawSwipe(c, f, now - f.start)
                is Fx.Type -> drawType(c, f, now - f.start, t)
            }
        }
        if (fx.isNotEmpty()) postInvalidateOnAnimation()
    }

    private fun drawTap(c: Canvas, f: Fx.Tap, ms: Long, t: Float) {
        // dot pops in, presses, then fades; a ring ripples outward.
        val press = if (f.long) 700f else 140f
        val pin = (ms / 120f).coerceIn(0f, 1f)
        val fade = if (ms < press) 1f else (1f - (ms - press) / (f.life - press)).coerceIn(0f, 1f)
        val r = d * (9f * dec.getInterpolation(pin) - if (ms in 60..(press.toLong() + 60)) 2f else 0f)
        glow.alpha = (60 * fade).toInt()
        c.drawCircle(f.x, f.y, r * 2.2f, glow)
        dot.alpha = (240 * fade).toInt()
        c.drawCircle(f.x, f.y, r.coerceAtLeast(0f), dot)
        val rt = ((ms - 60f) / (f.life - 60f)).coerceIn(0f, 1f)
        if (rt > 0f) {
            ring.strokeWidth = d * 2.2f * (1f - rt)
            ring.alpha = (200 * (1f - rt)).toInt()
            c.drawCircle(f.x, f.y, d * (10f + 30f * dec.getInterpolation(rt)), ring)
        }
        if (f.long && ms < press) {
            ring.strokeWidth = d * 2.5f
            ring.alpha = 220
            c.drawArc(RectF(f.x - d * 16, f.y - d * 16, f.x + d * 16, f.y + d * 16), -90f, 360f * (ms / press), false, ring)
        }
    }

    private fun drawSwipe(c: Canvas, f: Fx.Swipe, ms: Long) {
        val mt = (ms.toFloat() / f.ms).coerceIn(0f, 1f)
        val e = dec.getInterpolation(mt)
        val x = f.x1 + (f.x2 - f.x1) * e
        val y = f.y1 + (f.y2 - f.y1) * e
        val fade = if (ms <= f.ms) 1f else (1f - (ms - f.ms) / 450f).coerceIn(0f, 1f)
        // a fading trail of shrinking dots behind the finger
        for (i in 1..10) {
            val te = dec.getInterpolation((mt - i * 0.035f).coerceIn(0f, 1f))
            val tx = f.x1 + (f.x2 - f.x1) * te
            val ty = f.y1 + (f.y2 - f.y1) * te
            glow.alpha = ((110 - i * 10) * fade).toInt().coerceAtLeast(0)
            c.drawCircle(tx, ty, d * (8f - i * 0.6f), glow)
        }
        glow.alpha = (60 * fade).toInt()
        c.drawCircle(x, y, d * 20f, glow)
        dot.alpha = (240 * fade).toInt()
        c.drawCircle(x, y, d * 9f, dot)
    }

    private fun drawType(c: Canvas, f: Fx.Type, ms: Long, t: Float) {
        val fade = if (t < 0.75f) 1f else (1f - (t - 0.75f) / 0.25f)
        ring.strokeWidth = d * 2f
        ring.alpha = (200 * fade).toInt()
        val r = RectF(f.r)
        r.inset(-d * 3, -d * 3)
        c.drawRoundRect(r, d * 8, d * 8, ring)
        // three dots bouncing at the field's end, like someone typing
        val cx = (f.r.right - d * 34).coerceAtLeast(f.r.left + d * 14)
        val cy = f.r.centerY()
        for (i in 0..2) {
            val ph = ((ms / 140f) - i * 0.9f)
            val lift = (kotlin.math.sin(ph.toDouble()).toFloat()).coerceAtLeast(0f)
            dot.alpha = (230 * fade).toInt()
            c.drawCircle(cx + i * d * 11, cy - lift * d * 4, d * 3.6f, dot)
        }
    }
}
