package com.telesia.app

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.webkit.WebView

/**
 * Real hands for the in-app browser. Instead of faking clicks with page script, Telesia sends genuine
 * Android touch and keyboard input straight into the tab's WebView, exactly like a finger and a keyboard.
 * Sites see trusted events, so React forms, sliders, maps, OTP boxes and anti-bot checks behave as for a person.
 * Coordinates are WebView pixels (the page script converts CSS pixels using zoom and device pixel ratio).
 */
object WebHands {
    private val main = Handler(Looper.getMainLooper())

    private fun collect(v: View, out: ArrayList<WebView>) {
        if (v is WebView) {
            out.add(v)
            return
        }
        if (v is ViewGroup) for (i in 0 until v.childCount) collect(v.getChildAt(i), out)
    }

    /** The WebView showing [url]. With several on the same page, the one carrying [mark] in its title wins. */
    fun find(act: Activity?, url: String, mark: String): WebView? {
        val root = act?.window?.decorView ?: return null
        val all = ArrayList<WebView>()
        collect(root, all)
        if (all.isEmpty()) return null
        if (mark.isNotEmpty()) all.firstOrNull { (it.title ?: "").contains(mark) }?.let { return it }
        val same = all.filter { (it.url ?: "") == url }
        if (same.size == 1) return same[0]
        val host = try { android.net.Uri.parse(url).host ?: "" } catch (_: Exception) { "" }
        val byHost = all.filter { host.isNotEmpty() && (it.url ?: "").contains(host) }
        if (byHost.size == 1) return byHost[0]
        return null
    }

    private fun ev(down: Long, t: Long, action: Int, x: Float, y: Float): MotionEvent {
        val e = MotionEvent.obtain(down, t, action, x, y, 0)
        e.source = InputDevice.SOURCE_TOUCHSCREEN
        return e
    }

    private fun send(w: WebView, e: MotionEvent) {
        try {
            w.dispatchTouchEvent(e)
        } catch (_: Throwable) {
        } finally {
            e.recycle()
        }
    }

    /** A finger path: down at the first point, move through the rest over [ms], up at the end. Calls [done] after. */
    fun stroke(w: WebView, pts: List<Pair<Float, Float>>, ms: Long, hold: Long, done: () -> Unit) {
        if (pts.isEmpty()) {
            done()
            return
        }
        val down = SystemClock.uptimeMillis()
        val (x0, y0) = pts[0]
        send(w, ev(down, down, MotionEvent.ACTION_DOWN, x0, y0))
        val steps = if (pts.size > 1) pts.size - 1 else 0
        val per = if (steps > 0) (ms / steps).coerceAtLeast(8L) else 0L
        var i = 1
        fun next() {
            if (i <= steps) {
                val (x, y) = pts[i]
                send(w, ev(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_MOVE, x, y))
                i++
                main.postDelayed({ next() }, per)
            } else {
                val (xl, yl) = pts[pts.size - 1]
                send(w, ev(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, xl, yl))
                main.postDelayed({ done() }, 60)
            }
        }
        main.postDelayed({ next() }, if (steps == 0) hold.coerceAtLeast(40L) else hold.coerceAtLeast(16L))
    }

    fun tap(w: WebView, x: Float, y: Float, long: Boolean, done: () -> Unit) =
        stroke(w, listOf(x to y), 0, if (long) 650 else 55, done)

    /** Smooth swipe with a little ease, like a thumb. */
    fun swipe(w: WebView, x1: Float, y1: Float, x2: Float, y2: Float, ms: Long, done: () -> Unit) {
        val n = 14
        val pts = ArrayList<Pair<Float, Float>>()
        for (k in 0..n) {
            val f = k.toFloat() / n
            val e = 1f - (1f - f) * (1f - f)
            pts.add((x1 + (x2 - x1) * e) to (y1 + (y2 - y1) * e))
        }
        stroke(w, pts, ms, 30, done)
    }

    /** Text the way a keyboard app delivers it, into whatever field has focus. */
    fun type(w: WebView, text: String): String {
        return try {
            if (!w.hasFocus()) w.requestFocus()
            val ic = w.onCreateInputConnection(EditorInfo()) ?: return "no-input"
            ic.beginBatchEdit()
            ic.commitText(text, 1)
            ic.endBatchEdit()
            "ok"
        } catch (e: Throwable) {
            "error: " + (e.message ?: "typing failed")
        }
    }

    private val keys = mapOf(
        "enter" to KeyEvent.KEYCODE_ENTER, "tab" to KeyEvent.KEYCODE_TAB, "escape" to KeyEvent.KEYCODE_ESCAPE,
        "backspace" to KeyEvent.KEYCODE_DEL, "delete" to KeyEvent.KEYCODE_FORWARD_DEL,
        "arrowdown" to KeyEvent.KEYCODE_DPAD_DOWN, "arrowup" to KeyEvent.KEYCODE_DPAD_UP,
        "arrowleft" to KeyEvent.KEYCODE_DPAD_LEFT, "arrowright" to KeyEvent.KEYCODE_DPAD_RIGHT,
        "space" to KeyEvent.KEYCODE_SPACE, "pagedown" to KeyEvent.KEYCODE_PAGE_DOWN, "pageup" to KeyEvent.KEYCODE_PAGE_UP,
        "home" to KeyEvent.KEYCODE_MOVE_HOME, "end" to KeyEvent.KEYCODE_MOVE_END
    )

    fun key(w: WebView, name: String): String {
        val code = keys[name.lowercase()] ?: return "unknown-key"
        return try {
            val t = SystemClock.uptimeMillis()
            w.dispatchKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0))
            w.dispatchKeyEvent(KeyEvent(t, t + 40, KeyEvent.ACTION_UP, code, 0))
            "ok"
        } catch (e: Throwable) {
            "error: " + (e.message ?: "key failed")
        }
    }
}
