package com.submac.agent

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.InputType
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.sin

/**
 * The floating task chat, shown over other apps while SubMac or a bot drives the screen.
 *  pill  - a small draggable bubble with what it is doing right now; tap to open.
 *  panel - a compact chat: latest messages, the one approval card (Approve · Edit · Not now), a box to steer, Stop.
 *
 * It never gets in the way of phone control: it takes no focus unless the user taps a text box, it moves (or folds
 * back into the pill) when a tap or swipe would land on it, touches pass through it while a gesture runs, and it hides
 * for screenshots. It goes away when the app says the task ended, or by itself if the app goes silent.
 */
@SuppressLint("StaticFieldLeak", "ClickableViewAccessibility", "SetTextI18n")
object TaskBubble {
    private val INK = 0xF2111111.toInt()
    private val PAPER = 0xFFF4F0E7.toInt()
    private val MUTED = 0xFFA39E92.toInt()
    private val LINE = 0x29F4F0E7

    private val main = Handler(Looper.getMainLooper())
    private var wm: WindowManager? = null
    private var ctx: Context? = null
    private var root: FrameLayout? = null
    private var params: WindowManager.LayoutParams? = null
    private var viaA11y = false

    @Volatile var expanded = false
        private set
    private var focusable = false
    private var passthrough = false
    private var state: JSONObject = JSONObject()
    private var owner = ""

    // pill position, kept across rebuilds
    private var px = -1
    private var py = -1

    // persistent views
    private var pillText: TextView? = null
    private var pillDot: PulseDot? = null
    private var whoTv: TextView? = null
    private var stepTv: TextView? = null
    private var msgs: LinearLayout? = null
    private var msgScroll: ScrollView? = null
    private var askBox: LinearLayout? = null
    private var input: EditText? = null
    private var inputRow: View? = null
    private var draft = ""

    // Edit on an ask: the text being changed, for which ask
    private var editFor = ""
    private var editText: EditText? = null
    private var editDraft = ""

    /** The app sends the state again at least every 20 s; with no word for this long, the bubble hides itself. */
    private val watchdog = Runnable { hideNow() }
    private val restoreTouch = Runnable { setPassthrough(false) }

    private fun dp(v: Float): Int = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, ctx!!.resources.displayMetrics).toInt()

    private fun sans(c: Context, bold: Boolean = false): Typeface = try {
        Typeface.createFromAsset(c.assets, if (bold) "flutter_assets/assets/fonts/Geist-Medium.ttf" else "flutter_assets/assets/fonts/Geist-Regular.ttf")
    } catch (_: Exception) { Typeface.DEFAULT }

    private fun serif(c: Context): Typeface = try {
        Typeface.createFromAsset(c.assets, "flutter_assets/assets/fonts/InstrumentSerif-Italic.ttf")
    } catch (_: Exception) { Typeface.create(Typeface.SERIF, Typeface.ITALIC) }

    // ------------------------------------------------------------------ from the app

    /** Shows or updates the bubble with the app's state (JSON from screen_control.dart). */
    fun show(c: Context, json: String): Boolean {
        val s = try { JSONObject(json) } catch (_: Exception) { return false }
        if (Overlay.liveActive) { hideNow(); return false } // Live floats its own card
        main.removeCallbacks(watchdog)
        main.postDelayed(watchdog, 60_000)
        val newOwner = s.optString("owner")
        if (newOwner != owner) { draft = ""; editFor = ""; editDraft = "" }
        owner = newOwner
        state = s
        if (root == null) {
            if (!open(c)) return false
        } else {
            render()
        }
        return true
    }

    fun hide() = main.post { hideNow() }

    /** The phone-control service went away: a bubble drawn through it cannot stay. */
    fun serviceGone() = main.post { if (viaA11y) hideNow() }

    // ------------------------------------------------------------------ staying out of phone control's way

    /**
     * Called on the phone-control thread right before a tap or swipe covering [area] (screen pixels).
     * Touches pass through while it runs, and the bubble moves off that spot (the panel folds into the pill).
     */
    fun beforeGesture(area: RectF) {
        if (root == null) return
        val latch = CountDownLatch(1)
        main.post {
            try {
                val r = root
                val p = params
                if (r != null && p != null) {
                    setPassthrough(true)
                    if (covers(area)) {
                        if (expanded) {
                            saveDrafts()
                            expanded = false
                            rebuild()
                        }
                        moveAway(area)
                    }
                }
            } catch (_: Throwable) {}
            latch.countDown()
        }
        try { latch.await(300, TimeUnit.MILLISECONDS) } catch (_: Throwable) {}
    }

    /** The gesture finished: the bubble takes touches again a moment later. */
    fun afterGesture() {
        main.removeCallbacks(restoreTouch)
        main.postDelayed(restoreTouch, 350)
    }

    /** Phone control is about to type into an app: the bubble gives the keyboard back (the draft stays). */
    fun yieldFocus() = main.post { if (focusable && (input?.text?.isEmpty() != false) && editFor.isEmpty()) setFocusable(false) }

    /** Hidden while a screenshot is taken, so the picture shows only the app. */
    fun hiddenForShot(on: Boolean) = main.post { root?.visibility = if (on) View.INVISIBLE else View.VISIBLE }

    private fun covers(area: RectF): Boolean {
        val r = root ?: return false
        if (params == null) return false
        // Not laid out yet: its place on screen is unknown, so treat it as in the way.
        if (r.width == 0 || r.height == 0) return true
        val loc = IntArray(2)
        r.getLocationOnScreen(loc)
        val m = dp(20f)
        val box = Rect(loc[0] - m, loc[1] - m, loc[0] + r.width + m, loc[1] + r.height + m)
        // A point tap has an empty area; RectF.intersects needs width, so check the point too.
        return RectF.intersects(RectF(box), area) || box.contains(area.centerX().toInt(), area.centerY().toInt())
    }

    private fun moveAway(area: RectF) {
        val r = root ?: return
        val p = params ?: return
        val dm = ctx!!.resources.displayMetrics
        val w = r.width.takeIf { it > 0 } ?: dp(200f)
        val h = r.height.takeIf { it > 0 } ?: dp(44f)
        // Opposite side of the screen from the touch, both ways.
        p.x = if (area.centerX() > dm.widthPixels / 2f) dp(8f) else dm.widthPixels - w - dp(8f)
        p.y = if (area.centerY() > dm.heightPixels / 2f) (dm.heightPixels * 0.16f).toInt() else (dm.heightPixels * 0.72f).toInt() - h
        p.gravity = Gravity.TOP or Gravity.START
        px = p.x; py = p.y
        try { wm?.updateViewLayout(r, p) } catch (_: Throwable) {}
    }

    private fun setPassthrough(on: Boolean) {
        val r = root ?: return
        val p = params ?: return
        if (passthrough == on) return
        passthrough = on
        p.flags = if (on) p.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE else p.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        // Android 12+ only lets touches through a see-through overlay: keep it a little translucent meanwhile.
        p.alpha = if (on) 0.8f else 1f
        try { wm?.updateViewLayout(r, p) } catch (_: Throwable) {}
    }

    private fun setFocusable(on: Boolean) {
        val r = root ?: return
        val p = params ?: return
        if (focusable == on) return
        focusable = on
        p.flags = if (on) p.flags and WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE.inv() else p.flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        try { wm?.updateViewLayout(r, p) } catch (_: Throwable) {}
        if (!on) {
            try {
                (ctx!!.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(r.windowToken, 0)
            } catch (_: Throwable) {}
        }
    }

    // ------------------------------------------------------------------ window

    private fun open(c: Context): Boolean {
        val a11y = SubMacA11y.instance
        val overlayOk = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(c)
        if (!overlayOk && a11y == null) return false
        viaA11y = !overlayOk
        ctx = if (viaA11y) a11y else c.applicationContext
        wm = ctx!!.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        expanded = false
        build(animateIn = true)
        return root != null
    }

    private fun rebuild() {
        val old = root ?: return
        try { wm?.removeView(old) } catch (_: Throwable) {}
        root = null
        build(animateIn = false)
    }

    private fun build(animateIn: Boolean) {
        val c = ctx ?: return
        val type = when {
            viaA11y -> WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY
            Build.VERSION.SDK_INT >= 26 -> WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else -> WindowManager.LayoutParams.TYPE_PHONE
        }
        focusable = false
        passthrough = false
        val flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED
        val dm = c.resources.displayMetrics
        val p: WindowManager.LayoutParams
        if (expanded) {
            val w = minOf(dm.widthPixels - dp(24f), dp(380f))
            p = WindowManager.LayoutParams(w, WindowManager.LayoutParams.WRAP_CONTENT, type, flags, PixelFormat.TRANSLUCENT)
            val low = py < 0 || py > dm.heightPixels / 2
            p.gravity = (if (low) Gravity.BOTTOM else Gravity.TOP) or Gravity.CENTER_HORIZONTAL
            p.y = if (low) dp(24f) else maxOf(py, dp(40f))
            p.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        } else {
            p = WindowManager.LayoutParams(WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT, type, flags, PixelFormat.TRANSLUCENT)
            p.gravity = Gravity.TOP or Gravity.START
            p.x = if (px >= 0) px else dm.widthPixels - dp(200f)
            p.y = if (py >= 0) py else (dm.heightPixels * 0.30f).toInt()
        }
        params = p
        val r = object : FrameLayout(c) {
            override fun dispatchKeyEvent(event: KeyEvent): Boolean {
                if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
                    if (this@TaskBubble.focusable && expanded) { saveDrafts(); this@TaskBubble.setFocusable(false); return true }
                }
                return super.dispatchKeyEvent(event)
            }
        }
        root = r
        clearRefs()
        if (expanded) buildPanel(r) else buildPill(r)
        if (animateIn) {
            r.alpha = 0f
            r.scaleX = 0.92f; r.scaleY = 0.92f
            r.animate().alpha(1f).scaleX(1f).scaleY(1f).setInterpolator(DecelerateInterpolator(2f)).setDuration(260).start()
        }
        try { wm!!.addView(r, p) } catch (_: Throwable) { root = null; return }
        render()
    }

    private fun clearRefs() {
        pillText = null; pillDot = null; whoTv = null; stepTv = null; msgs = null; msgScroll = null
        askBox = null; input = null; inputRow = null; editText = null
    }

    private fun hideNow() {
        main.removeCallbacks(watchdog)
        main.removeCallbacks(restoreTouch)
        val r = root ?: return
        root = null
        saveDrafts()
        pillDot?.running = false
        clearRefs()
        expanded = false
        r.animate().alpha(0f).scaleX(0.94f).scaleY(0.94f).setDuration(180).withEndAction {
            try { wm?.removeView(r) } catch (_: Throwable) {}
        }.start()
        // If the animation never runs (window already gone), make sure it is removed.
        main.postDelayed({ try { if (r.isAttachedToWindow) wm?.removeView(r) } catch (_: Throwable) {} }, 600)
    }

    private fun saveDrafts() {
        input?.let { draft = it.text.toString() }
        editText?.let { editDraft = it.text.toString() }
    }

    private fun send(action: String, id: String = "", text: String? = null) {
        val m = HashMap<String, Any?>()
        m["action"] = action
        m["owner"] = owner
        m["id"] = id
        if (text != null) m["text"] = text
        Bridge.send("bubble", m)
    }

    // ------------------------------------------------------------------ pill

    private fun buildPill(r: FrameLayout) {
        val c = ctx!!
        r.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        val pill = LinearLayout(c)
        pill.orientation = LinearLayout.HORIZONTAL
        pill.gravity = Gravity.CENTER_VERTICAL
        pill.setPadding(dp(12f), dp(9f), dp(14f), dp(9f))
        pill.background = GradientDrawable().apply { cornerRadius = dp(22f).toFloat(); setColor(INK); setStroke(dp(1f), LINE) }
        pill.elevation = dp(8f).toFloat()
        val dot = PulseDot(c)
        pillDot = dot
        pill.addView(dot, LinearLayout.LayoutParams(dp(12f), dp(12f)))
        val t = TextView(c)
        t.typeface = sans(c, bold = true)
        t.textSize = 13f
        t.setTextColor(PAPER)
        t.maxLines = 1
        t.ellipsize = TextUtils.TruncateAt.END
        t.maxWidth = dp(190f)
        pillText = t
        pill.addView(t, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { leftMargin = dp(9f) })
        val m = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        m.setMargins(dp(4f), dp(4f), dp(4f), dp(6f))
        r.addView(pill, m)

        var downX = 0f; var downY = 0f; var startX = 0; var startY = 0; var moved = false
        pill.setOnTouchListener { _, e ->
            val p = params ?: return@setOnTouchListener false
            when (e.action) {
                MotionEvent.ACTION_DOWN -> { downX = e.rawX; downY = e.rawY; startX = p.x; startY = p.y; moved = false; true }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX; val dy = e.rawY - downY
                    if (moved || dx * dx + dy * dy > dp(6f) * dp(6f)) {
                        moved = true
                        p.x = startX + dx.toInt(); p.y = startY + dy.toInt()
                        px = p.x; py = p.y
                        try { wm?.updateViewLayout(r, p) } catch (_: Throwable) {}
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) { expanded = true; rebuild() } else snapToEdge(r, p)
                    true
                }
                else -> false
            }
        }
    }

    private fun snapToEdge(r: View, p: WindowManager.LayoutParams) {
        val w = ctx!!.resources.displayMetrics.widthPixels
        val target = if (p.x + r.width / 2 < w / 2) dp(8f) else w - r.width - dp(8f)
        val a = ValueAnimator.ofInt(p.x, target)
        a.duration = 220
        a.interpolator = DecelerateInterpolator()
        a.addUpdateListener {
            p.x = it.animatedValue as Int
            px = p.x
            try { if (root === r) wm?.updateViewLayout(r, p) } catch (_: Throwable) {}
        }
        a.start()
    }

    // ------------------------------------------------------------------ panel

    private fun pillButton(c: Context, label: String, strong: Boolean = false, quiet: Boolean = false, onTap: () -> Unit): TextView {
        val t = TextView(c)
        t.text = label
        t.setTextColor(if (strong) 0xFF111111.toInt() else if (quiet) MUTED else PAPER)
        t.textSize = 13.5f
        t.typeface = sans(c, bold = true)
        t.gravity = Gravity.CENTER
        t.setPadding(dp(13f), dp(8f), dp(13f), dp(8f))
        t.background = GradientDrawable().apply {
            cornerRadius = dp(18f).toFloat()
            if (strong) setColor(PAPER) else { setColor(0x00000000); if (!quiet) setStroke(dp(1f), 0x40F4F0E7) }
        }
        t.setOnClickListener { onTap() }
        return t
    }

    private fun gap() = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { leftMargin = dp(6f) }

    private fun buildPanel(r: FrameLayout) {
        val c = ctx!!
        r.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        val card = LinearLayout(c)
        card.orientation = LinearLayout.VERTICAL
        card.setPadding(dp(16f), dp(14f), dp(16f), dp(12f))
        card.background = GradientDrawable().apply { cornerRadius = dp(24f).toFloat(); setColor(INK); setStroke(dp(1f), LINE) }
        card.elevation = dp(14f).toFloat()

        // Header: who, what now, minimize, Stop
        val head = LinearLayout(c)
        head.orientation = LinearLayout.HORIZONTAL
        head.gravity = Gravity.CENTER_VERTICAL
        val col = LinearLayout(c)
        col.orientation = LinearLayout.VERTICAL
        val who = TextView(c)
        who.typeface = serif(c)
        who.textSize = 21f
        who.setTextColor(PAPER)
        who.maxLines = 1
        who.ellipsize = TextUtils.TruncateAt.END
        whoTv = who
        col.addView(who)
        val st = TextView(c)
        st.typeface = sans(c)
        st.textSize = 13f
        st.setTextColor(MUTED)
        st.maxLines = 2
        st.ellipsize = TextUtils.TruncateAt.END
        stepTv = st
        col.addView(st)
        head.addView(col, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        head.addView(pillButton(c, "Hide") { saveDrafts(); expanded = false; rebuild() }, gap())
        head.addView(pillButton(c, "Stop", strong = true) { stopNow() }, gap())
        card.addView(head)

        // Latest messages
        val sv = object : ScrollView(c) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                super.onMeasure(widthMeasureSpec, View.MeasureSpec.makeMeasureSpec(dp(190f), View.MeasureSpec.AT_MOST))
            }
        }
        sv.isVerticalScrollBarEnabled = false
        val list = LinearLayout(c)
        list.orientation = LinearLayout.VERTICAL
        sv.addView(list)
        msgs = list
        msgScroll = sv
        card.addView(sv, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10f) })

        // The ask, when there is one
        val ask = LinearLayout(c)
        ask.orientation = LinearLayout.VERTICAL
        askBox = ask
        card.addView(ask, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        // Steer
        val row = LinearLayout(c)
        row.orientation = LinearLayout.HORIZONTAL
        row.gravity = Gravity.CENTER_VERTICAL
        val et = textBox(c, "Tell ${state.optString("who", "Telesia")} something", draft)
        input = et
        val sendIt = {
            val t = et.text.toString().trim()
            if (t.isNotEmpty()) {
                send("send", text = t)
                et.setText("")
                draft = ""
                setFocusable(false)
            }
        }
        et.setOnEditorActionListener { _, id, _ -> if (id == EditorInfo.IME_ACTION_SEND) { sendIt(); true } else false }
        row.addView(et, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(pillButton(c, "Send", strong = true) { sendIt() }, gap())
        inputRow = row
        card.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10f) })

        val open = TextView(c)
        open.text = "Open Telesia"
        open.typeface = sans(c)
        open.textSize = 12.5f
        open.setTextColor(MUTED)
        open.gravity = Gravity.END
        open.setPadding(dp(4f), dp(8f), dp(4f), dp(0f))
        open.setOnClickListener { send("open"); hideNow() }
        card.addView(open, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        r.addView(card, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    /** A text box that takes the keyboard only when the user taps it (the bubble is never focusable otherwise). */
    private fun textBox(c: Context, hint: String, text: String): EditText {
        val et = EditText(c)
        et.hint = hint
        et.setHintTextColor(MUTED)
        et.setTextColor(PAPER)
        et.typeface = sans(c)
        et.textSize = 14.5f
        et.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        et.maxLines = 4
        et.imeOptions = EditorInfo.IME_ACTION_SEND
        et.setPadding(dp(14f), dp(10f), dp(14f), dp(10f))
        et.background = GradientDrawable().apply { cornerRadius = dp(18f).toFloat(); setColor(0x14F4F0E7) }
        et.setText(text)
        et.setOnTouchListener { v, e ->
            if (e.action == MotionEvent.ACTION_DOWN && !focusable) {
                setFocusable(true)
                v.postDelayed({
                    v.requestFocus()
                    try { (c.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(v, 0) } catch (_: Throwable) {}
                }, 120)
            }
            false
        }
        return et
    }

    private fun stopNow() {
        send("stop")
        ScreenGuard.halt()
        try { SubMacA11y.instance?.ghost?.hideBadge() } catch (_: Throwable) {}
        hideNow()
    }

    // ------------------------------------------------------------------ drawing the state

    private fun render() {
        val c = ctx ?: return
        val s = state
        val step = s.optString("step", "Working on it")
        val ask = s.optJSONObject("ask")
        pillText?.text = if (ask != null) "Needs your OK" else step
        pillDot?.alert = ask != null
        whoTv?.text = s.optString("who", "Telesia")
        stepTv?.text = step
        val list = msgs
        if (list != null) {
            list.removeAllViews()
            val arr = s.optJSONArray("messages")
            val n = arr?.length() ?: 0
            if (n == 0) {
                list.addView(line(c, false, "Updates from this task show here.", quiet = true))
            }
            for (i in 0 until n) {
                val m = arr!!.optJSONObject(i) ?: continue
                list.addView(line(c, m.optBoolean("me"), m.optString("text")))
            }
            msgScroll?.post { msgScroll?.fullScroll(View.FOCUS_DOWN) }
        }
        val canType = s.optBoolean("canType", true)
        inputRow?.visibility = if (canType) View.VISIBLE else View.GONE
        renderAsk(c, ask)
    }

    private fun line(c: Context, me: Boolean, text: String, quiet: Boolean = false): View {
        val t = TextView(c)
        t.text = text
        t.typeface = sans(c)
        t.textSize = 14f
        t.setLineSpacing(0f, 1.2f)
        t.setTextColor(if (quiet) MUTED else PAPER)
        val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        lp.topMargin = dp(6f)
        if (me) {
            t.setPadding(dp(12f), dp(7f), dp(12f), dp(7f))
            t.background = GradientDrawable().apply { cornerRadius = dp(14f).toFloat(); setColor(0x1FF4F0E7) }
            lp.gravity = Gravity.END
            lp.leftMargin = dp(36f)
        } else {
            lp.rightMargin = dp(20f)
        }
        t.layoutParams = lp
        return t
    }

    private fun renderAsk(c: Context, ask: JSONObject?) {
        val box = askBox ?: return
        val id = ask?.optString("id") ?: ""
        // Don't rebuild the card under the user's fingers while they change the text.
        if (editFor.isNotEmpty() && editFor == id && box.childCount > 0) return
        if (editFor.isNotEmpty() && editFor != id) { editFor = ""; editDraft = "" }
        box.removeAllViews()
        editText = null
        if (ask == null) { box.visibility = View.GONE; return }
        box.visibility = View.VISIBLE
        val card = LinearLayout(c)
        card.orientation = LinearLayout.VERTICAL
        card.setPadding(dp(14f), dp(12f), dp(14f), dp(10f))
        card.background = GradientDrawable().apply { cornerRadius = dp(16f).toFloat(); setColor(0x0FF4F0E7); setStroke(dp(1f), 0x66F4F0E7) }
        val kind = ask.optString("kind")
        val label = TextView(c)
        label.text = if (kind == "question") "${ask.optString("who")} needs to know" else "${ask.optString("who")} asks"
        label.typeface = sans(c)
        label.textSize = 12.5f
        label.setTextColor(MUTED)
        card.addView(label)
        val title = TextView(c)
        title.text = ask.optString("title")
        title.typeface = sans(c, bold = true)
        title.textSize = 15f
        title.setTextColor(PAPER)
        title.setPadding(0, dp(3f), 0, 0)
        card.addView(title)
        val body = ask.optString("body")
        val editing = editFor == id
        if (editing) {
            val et = textBox(c, "", if (editDraft.isNotEmpty()) editDraft else ask.optString("editText"))
            et.imeOptions = EditorInfo.IME_ACTION_NONE
            editText = et
            card.addView(et, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8f) })
        } else if (body.isNotEmpty()) {
            val b = TextView(c)
            b.text = body
            b.typeface = sans(c)
            b.textSize = 13.5f
            b.setTextColor(PAPER)
            b.maxLines = 4
            b.ellipsize = TextUtils.TruncateAt.END
            b.setPadding(0, dp(4f), 0, 0)
            card.addView(b)
        }
        val row = LinearLayout(c)
        row.orientation = LinearLayout.HORIZONTAL
        row.gravity = Gravity.CENTER_VERTICAL or Gravity.START
        val first = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        when {
            ask.optBoolean("needsApp") -> row.addView(pillButton(c, "Open Telesia", strong = true) { send("open"); hideNow() }, first)
            kind == "question" -> {
                val opts = ask.optJSONArray("options")
                val n = opts?.length() ?: 0
                if (n == 0) {
                    val hint = TextView(c)
                    hint.text = "Type your answer below."
                    hint.typeface = sans(c)
                    hint.textSize = 12.5f
                    hint.setTextColor(MUTED)
                    row.addView(hint)
                } else {
                    // Options stack, so long ones stay readable.
                    row.orientation = LinearLayout.VERTICAL
                    for (i in 0 until minOf(n, 4)) {
                        val o = opts!!.optString(i)
                        row.addView(pillButton(c, o) { send("option", id, o) },
                            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(6f) })
                    }
                }
            }
            else -> {
                // The one approval card: Approve · Edit · Not now.
                row.addView(pillButton(c, "Approve", strong = true) {
                    val t = if (editing) editText?.text?.toString() ?: "" else ""
                    editFor = ""; editDraft = ""
                    setFocusable(false)
                    send("approve", id, t)
                }, first)
                row.addView(pillButton(c, if (editing) "Cancel" else "Edit") {
                    if (editing) {
                        editFor = ""; editDraft = ""
                        setFocusable(false)
                        renderAsk(c, ask)
                    } else if (ask.optBoolean("editable")) {
                        editFor = id; editDraft = ""
                        box.removeAllViews()
                        renderAsk(c, ask)
                    } else {
                        send("edit", id)
                    }
                }, gap())
                row.addView(pillButton(c, "Not now", quiet = true) {
                    editFor = ""; editDraft = ""
                    setFocusable(false)
                    send("notnow", id)
                }, gap())
            }
        }
        card.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10f) })
        box.addView(card, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(10f) })
    }

    /** A soft breathing dot; brighter with a ring when the task waits on the user. */
    class PulseDot(c: Context) : View(c) {
        @Volatile var running = true
        @Volatile var alert = false
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val now = System.currentTimeMillis()
            val cx = width / 2f
            val cy = height / 2f
            val base = minOf(width, height) / 2f
            val k = 0.5f + 0.5f * sin(now / 1000.0 * 2 * Math.PI * 0.6).toFloat()
            paint.color = 0xFFF4F0E7.toInt()
            paint.alpha = if (alert) 255 else (150 + 105 * k).toInt()
            canvas.drawCircle(cx, cy, base * (if (alert) 0.62f else 0.42f + 0.12f * k), paint)
            if (alert) {
                ring.color = 0xFFF4F0E7.toInt()
                ring.alpha = (200 * (1f - k)).toInt()
                ring.strokeWidth = base * 0.14f
                canvas.drawCircle(cx, cy, base * (0.7f + 0.25f * k), ring)
            }
            if (running) postInvalidateOnAnimation()
        }
    }
}
