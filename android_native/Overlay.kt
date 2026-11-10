package com.telesia.app

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.provider.Settings
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Floating Live, drawn over other apps.
 *  popup  - the Siri-like card at the bottom: the red dot blooms, breathes with the voice, captions.
 *  orb    - the small mic, docked in the notch: a dot in the status-bar strip at the very top of the
 *           screen, out of the way of everything. Drag it along the top (it snaps back into the strip),
 *           tap it to open the card again.
 *  sheet  - the card plus a box to type to Telesia.
 */
@SuppressLint("StaticFieldLeak", "ClickableViewAccessibility", "SetTextI18n")
object Overlay {
    // The app's real ink (theme.dart), not pure black, so the card reads as Telesia.
    private val INK = 0xFF17150F.toInt()
    private val PAPER = 0xFFF4F0E7.toInt()
    private val RED = 0xFFF4F0E7.toInt() // the orb is paper-white on ink: calm, no red
    private val MUTED = 0xFFA39E92.toInt()
    // Translucent ink surface: the card floats like Siri over whatever is behind it.
    private val CARD = 0xB317150F.toInt()
    private val CARD_STROKE = 0x24F4F0E7

    @Volatile var liveActive = false
    private var wm: WindowManager? = null
    private var ctx: Context? = null
    private var root: FrameLayout? = null
    private var params: WindowManager.LayoutParams? = null
    private var mode = "popup"

    private var orb: OrbView? = null
    private var statusTv: TextView? = null
    private var captionTv: TextView? = null
    private var youTv: TextView? = null
    private var input: EditText? = null
    private var muteBtn: TextView? = null
    private var lastStatus = ""
    // Where the notch dot was left (an x offset from the centre). MIN_VALUE = never placed yet.
    private var orbX = Int.MIN_VALUE
    private var orbY = Int.MIN_VALUE

    /** The touch target of the docked mic. The dot drawn inside it is about a quarter of this. */
    private fun orbSize(): Int = dp(56f)

    /** The strip the status bar (and most notches) live in, so the dot can sit inside it. */
    private fun statusStrip(): Int {
        val c = ctx ?: return 0
        val id = c.resources.getIdentifier("status_bar_height", "dimen", "android")
        val h = if (id > 0) {
            try { c.resources.getDimensionPixelSize(id) } catch (_: Exception) { 0 }
        } else 0
        return if (h > 0) h else dp(28f)
    }

    /**
     * The y that puts the dot's centre in the middle of the notch strip. It is negative when the strip is
     * shorter than the touch target, which is fine: the window is transparent and LAYOUT_NO_LIMITS lets the
     * empty top part sit off-screen.
     */
    private fun stripY(size: Int): Int = (statusStrip() - size) / 2

    /**
     * How far from the centre the dot has to sit so it never covers a camera hole. 0 when the top edge is
     * clear, and on any device where the cutout cannot be read (the dot then simply centres).
     */
    private fun notchShift(size: Int): Int {
        val w = wm ?: return 0
        val hole = try {
            if (Build.VERSION.SDK_INT >= 30) w.currentWindowMetrics.windowInsets.displayCutout else null
        } catch (_: Exception) {
            null
        }?.boundingRects?.firstOrNull { it.top <= 0 && it.width() > 0 } ?: return 0
        val centre = ctx!!.resources.displayMetrics.widthPixels / 2
        if (hole.right <= centre || hole.left >= centre) return 0 // the hole is not in the middle
        val gap = dp(8f)
        val room = (ctx!!.resources.displayMetrics.widthPixels - size) / 2 - dp(6f)
        val right = hole.right + gap + size / 2 - centre
        val left = hole.left - gap - size / 2 - centre
        return when {
            right <= room -> right
            left >= -room -> left
            else -> 0
        }
    }

    private fun dp(v: Float): Int = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, ctx!!.resources.displayMetrics).toInt()

    private fun serif(c: Context): Typeface = try {
        Typeface.createFromAsset(c.assets, "flutter_assets/assets/fonts/InstrumentSerif-Italic.ttf")
    } catch (_: Exception) {
        Typeface.create(Typeface.SERIF, Typeface.ITALIC)
    }

    private fun sans(c: Context, bold: Boolean = false): Typeface = try {
        Typeface.createFromAsset(c.assets, if (bold) "flutter_assets/assets/fonts/Geist-Medium.ttf" else "flutter_assets/assets/fonts/Geist-Regular.ttf")
    } catch (_: Exception) {
        Typeface.DEFAULT
    }

    fun canShow(c: Context) = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(c)

    /** Shows (or switches) the floating Live. Returns false without the "display over other apps" permission. */
    fun show(c: Context, newMode: String): Boolean {
        if (!canShow(c)) return false
        ctx = c.applicationContext
        liveActive = true
        if (root != null && mode == newMode && !hiding) return true
        val first = root == null
        removeNow()
        mode = newMode
        build(first)
        return true
    }

    @Volatile private var hiding = false

    fun hide() {
        liveActive = false
        val r = root ?: return
        hiding = true
        r.animate().alpha(0f).translationY(if (mode == "orb") 0f else dp(30f).toFloat()).setDuration(200)
            .withEndAction { if (root === r) removeNow() }.start()
    }

    private fun removeNow() {
        hiding = false
        val r = root ?: return
        r.animate().cancel()
        orb?.stop()
        try { wm?.removeView(r) } catch (_: Exception) {}
        root = null
        orb = null; statusTv = null; captionTv = null; youTv = null; input = null; muteBtn = null
    }

    fun update(status: String, level: Float, caption: String, you: String, muted: Boolean, thinking: Boolean) {
        orb?.level = level
        orb?.thinking = thinking
        orb?.muted = muted
        if (status != lastStatus) {
            lastStatus = status
            statusTv?.text = status
        }
        if (caption.isNotEmpty()) captionTv?.text = caption
        youTv?.text = you
        youTv?.visibility = if (you.isEmpty()) View.GONE else View.VISIBLE
        muteBtn?.text = if (muted) "Unmute" else "Mute"
    }

    private fun send(action: String, text: String? = null) {
        val m = HashMap<String, Any?>()
        m["action"] = action
        if (text != null) m["text"] = text
        Bridge.send("overlay", m)
    }

    private fun build(animateIn: Boolean) {
        val c = ctx!!
        wm = c.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val focusable = mode == "sheet"
        // NOT_TOUCH_MODAL: touches outside the card always reach the app behind it, so the phone never freezes.
        val flags = (if (focusable) 0 else WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE) or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED
        val p = if (mode == "orb") {
            // The small mic lives in the notch: the status-bar strip at the very top, so it never sits over
            // what the person is reading. 56dp is the touch target; the dot inside is about 14dp.
            val size = orbSize()
            WindowManager.LayoutParams(size, size, type, flags, PixelFormat.TRANSLUCENT).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                x = if (orbX != Int.MIN_VALUE) orbX else notchShift(size)
                y = if (orbY != Int.MIN_VALUE) orbY else stripY(size)
            }
        } else {
            WindowManager.LayoutParams(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.WRAP_CONTENT, type, flags, PixelFormat.TRANSLUCENT).apply {
                gravity = Gravity.BOTTOM
                softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE
            }
        }
        params = p
        val r = object : FrameLayout(c) {
            override fun dispatchKeyEvent(event: KeyEvent): Boolean {
                if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP && mode == "sheet") {
                    show(c, "popup")
                    return true
                }
                return super.dispatchKeyEvent(event)
            }
        }
        root = r
        if (mode == "orb") buildOrb(r) else buildCard(r)
        if (animateIn) {
            r.alpha = 0f
            if (mode != "orb") r.translationY = dp(36f).toFloat()
            r.animate().alpha(1f).translationY(0f).setInterpolator(DecelerateInterpolator(2f)).setDuration(320).start()
        }
        wm!!.addView(r, p)
        orb?.bloom()
        if (mode == "sheet") {
            input?.postDelayed({
                input?.requestFocus()
                (c.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(input, 0)
            }, 150)
        }
    }

    private fun buildOrb(r: FrameLayout) {
        val c = ctx!!
        // A small dot (~16dp across) so it fits inside the notch strip instead of sitting on the app.
        val o = OrbView(c, 0.14f)
        orb = o
        r.addView(o, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        var downX = 0f; var downY = 0f; var startX = 0; var startY = 0; var moved = false
        o.setOnTouchListener { _, e ->
            val p = params ?: return@setOnTouchListener false
            when (e.action) {
                MotionEvent.ACTION_DOWN -> { downX = e.rawX; downY = e.rawY; startX = p.x; startY = p.y; moved = false; true }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX; val dy = e.rawY - downY
                    if (moved || dx * dx + dy * dy > dp(6f) * dp(6f)) {
                        moved = true
                        p.x = startX + dx.toInt(); p.y = startY + dy.toInt()
                        orbX = p.x; orbY = p.y
                        try { wm?.updateViewLayout(r, p) } catch (_: Exception) {}
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) { show(c, "popup"); send("mode", "popup") } else snapToNotch(r, p)
                    true
                }
                else -> false
            }
        }
    }

    /**
     * Back into the notch: the dot snaps to the nearest top anchor (left of the strip, the middle, or the
     * right of it) and always back to the strip's height, so a drag can never leave it sitting over the app.
     */
    private fun snapToNotch(r: View, p: WindowManager.LayoutParams) {
        val dm = ctx!!.resources.displayMetrics
        val size = if (p.width > 0) p.width else orbSize()
        val room = (dm.widthPixels - size) / 2 - dp(6f)
        val restY = stripY(size)
        val targetX = listOf(-room, 0, room).minByOrNull { kotlin.math.abs(it - p.x) } ?: 0
        val a = ValueAnimator.ofInt(p.x, targetX)
        a.duration = 220
        a.interpolator = DecelerateInterpolator()
        a.addUpdateListener {
            p.x = it.animatedValue as Int
            p.y = restY
            orbX = p.x
            orbY = p.y
            try { wm?.updateViewLayout(r, p) } catch (_: Exception) {}
        }
        a.start()
    }

    private fun pill(c: Context, label: String, strong: Boolean = false, onTap: () -> Unit): TextView {
        val t = TextView(c)
        t.text = label
        t.setTextColor(if (strong) INK else PAPER)
        t.textSize = 14.5f
        t.typeface = sans(c, bold = true)
        t.gravity = Gravity.CENTER
        t.setPadding(dp(14f), dp(9f), dp(14f), dp(9f))
        t.background = GradientDrawable().apply {
            cornerRadius = dp(20f).toFloat()
            if (strong) setColor(RED) else { setColor(0x00000000); setStroke(dp(1f), 0x33F4F0E7) }
        }
        t.setOnClickListener { onTap() }
        return t
    }

    private fun buildCard(r: FrameLayout) {
        val c = ctx!!
        val card = LinearLayout(c)
        card.orientation = LinearLayout.VERTICAL
        card.gravity = Gravity.CENTER_HORIZONTAL
        card.setPadding(dp(20f), dp(10f), dp(20f), dp(16f))
        card.background = GradientDrawable().apply {
            cornerRadius = dp(28f).toFloat()
            setColor(CARD)
            setStroke(dp(1f), CARD_STROKE)
        }
        card.elevation = dp(10f).toFloat()

        val o = OrbView(c)
        orb = o
        card.addView(o, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(132f)))

        val st = TextView(c)
        st.typeface = serif(c)
        st.textSize = 26f
        st.setTextColor(PAPER)
        st.gravity = Gravity.CENTER
        st.text = if (lastStatus.isEmpty()) "Listening" else lastStatus
        statusTv = st
        card.addView(st)

        val you = TextView(c)
        you.typeface = sans(c)
        you.textSize = 14f
        you.setTextColor(MUTED)
        you.gravity = Gravity.CENTER
        you.maxLines = 2
        you.ellipsize = android.text.TextUtils.TruncateAt.START
        you.visibility = View.GONE
        youTv = you
        card.addView(you, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6f) })

        val cap = TextView(c)
        cap.typeface = sans(c)
        cap.textSize = 16.5f
        cap.setLineSpacing(0f, 1.25f)
        cap.setTextColor(PAPER)
        cap.gravity = Gravity.CENTER
        cap.maxLines = if (mode == "sheet") 6 else 3
        cap.ellipsize = android.text.TextUtils.TruncateAt.START
        captionTv = cap
        card.addView(cap, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6f) })

        if (mode == "sheet") {
            val row = LinearLayout(c)
            row.orientation = LinearLayout.HORIZONTAL
            row.gravity = Gravity.CENTER_VERTICAL
            val et = EditText(c)
            et.hint = "Message Telesia"
            et.setHintTextColor(MUTED)
            et.setTextColor(PAPER)
            et.typeface = sans(c)
            et.textSize = 16f
            et.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            et.maxLines = 4
            et.imeOptions = EditorInfo.IME_ACTION_SEND
            et.setPadding(dp(16f), dp(12f), dp(16f), dp(12f))
            et.background = GradientDrawable().apply { cornerRadius = dp(22f).toFloat(); setColor(0x1FF4F0E7) }
            input = et
            val sendIt = {
                val t = et.text.toString().trim()
                if (t.isNotEmpty()) { send("text", t); et.setText("") }
            }
            et.setOnEditorActionListener { _, id, _ -> if (id == EditorInfo.IME_ACTION_SEND) { sendIt(); true } else false }
            row.addView(et, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            row.addView(pill(c, "Send", strong = true) { sendIt() }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { leftMargin = dp(8f) })
            card.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(14f) })
        }

        val actions = LinearLayout(c)
        actions.orientation = LinearLayout.HORIZONTAL
        actions.gravity = Gravity.CENTER
        val gap = { LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { leftMargin = dp(4f); rightMargin = dp(4f) } }
        if (mode == "popup") actions.addView(pill(c, "Type") { show(c, "sheet"); send("mode", "sheet") }, gap())
        else actions.addView(pill(c, "Hide keyboard") { show(c, "popup"); send("mode", "popup") }, gap())
        val mb = pill(c, "Mute") { send("mute") }
        muteBtn = mb
        actions.addView(mb, gap())
        actions.addView(pill(c, "Open") { send("open") }, gap())
        actions.addView(pill(c, "Small") { show(c, "orb"); send("mode", "orb") }, gap())
        actions.addView(pill(c, "End", strong = true) { send("end") }, gap())
        card.addView(actions, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(14f) })

        val lp = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        lp.setMargins(dp(10f), 0, dp(10f), dp(14f))
        r.addView(card, lp)
    }

    /** The brand's red dot: blooms in with two ripples, breathes when idle, swells with the voice. */
    class OrbView(c: Context, private val scale: Float = 0.2f) : View(c) {
        @Volatile var level = 0f
        @Volatile var thinking = false
        @Volatile var muted = false
        private var shown = 0f
        private var bloomAt = 0L
        private var running = true
        private var smooth = 0f
        private val core = Paint(Paint.ANTI_ALIAS_FLAG)
        private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
        private val glow = Paint(Paint.ANTI_ALIAS_FLAG)
        private val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
        private val oval = RectF()
        private val overshoot = OvershootInterpolator(2.2f)

        fun bloom() {
            bloomAt = System.currentTimeMillis()
            postInvalidateOnAnimation()
        }

        fun stop() { running = false }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val now = System.currentTimeMillis()
            val cx = width / 2f
            val cy = height / 2f
            val base = min(width, height) * scale
            val t = ((now - bloomAt) / 650f).coerceIn(0f, 1f)
            shown = overshoot.getInterpolation(t)
            smooth += (level - smooth) * 0.25f
            val breathe = 0.035f * sin(now / 1000.0 * 2 * PI * 0.55).toFloat()
            val r = base * shown * (1f + breathe + 0.42f * smooth)
            val color = if (muted) MUTED else RED

            // Glow
            if (r > 1f) {
                glow.shader = RadialGradient(cx, cy, r * 2.4f, intArrayOf(withAlpha(color, (70 + 90 * smooth).toInt()), withAlpha(color, 0)), null, Shader.TileMode.CLAMP)
                canvas.drawCircle(cx, cy, r * 2.4f, glow)
            }
            // Two ripples on wake
            for (k in 0..1) {
                val rt = ((now - bloomAt - k * 180) / 900f)
                if (rt in 0f..1f) {
                    ring.color = withAlpha(color, (150 * (1f - rt)).toInt())
                    ring.strokeWidth = base * 0.08f * (1f - rt) + 1f
                    canvas.drawCircle(cx, cy, base * (1f + 1.7f * rt), ring)
                }
            }
            core.color = color
            canvas.drawCircle(cx, cy, max(r, 0f), core)
            // Thinking: a thin arc that circles the dot
            if (thinking && r > 1f) {
                arc.color = withAlpha(PAPER, 200)
                arc.strokeWidth = base * 0.07f
                val ar = r * 1.35f
                oval.set(cx - ar, cy - ar, cx + ar, cy + ar)
                val start = ((now % 1200) / 1200f) * 360f
                canvas.drawArc(oval, start, 80f, false, arc)
            }
            if (running) postInvalidateOnAnimation()
        }

        private fun withAlpha(c: Int, a: Int) = (a.coerceIn(0, 255) shl 24) or (c and 0x00FFFFFF)
    }
}
