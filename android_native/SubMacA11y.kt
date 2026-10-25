package com.submac.agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Phone control. The user turns it on in Android settings; SubMac then reads the screen as a
 * numbered list and taps, types and scrolls by number, only when the user asks for something.
 *
 * Every public action is called from Bridge's worker thread (never the main thread), so a slow app
 * can't freeze SubMac and make Android mark the service "not working". Nothing here may throw:
 * an uncaught error would take the service down, so every action catches and answers in words.
 */
class SubMacA11y : AccessibilityService() {
    companion object {
        @Volatile var instance: SubMacA11y? = null
        /** When the screen last changed, so SubMac can wait for an app to settle before reading it. */
        @Volatile var lastEvent = 0L
        @Volatile var connectedAt = 0L
    }

    @Volatile private var nodes: List<AccessibilityNodeInfo> = emptyList()
    val ghost by lazy { Ghost(this) }
    private val main = Handler(Looper.getMainLooper())

    // ---------------------------------------------------------------- lifecycle

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        connectedAt = SystemClock.uptimeMillis()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        try {
            if (event?.packageName?.toString() != packageName) lastEvent = SystemClock.uptimeMillis()
        } catch (_: Throwable) {}
    }

    fun idleMs(): Long = SystemClock.uptimeMillis() - lastEvent

    override fun onInterrupt() {}

    override fun onDestroy() {
        cleanUp()
        super.onDestroy()
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        cleanUp()
        return super.onUnbind(intent)
    }

    /** Phone control went away: queued steps stop, and the badge and a bubble drawn through this service go. */
    private fun cleanUp() {
        ScreenGuard.halt()
        try { ghost.hideBadge() } catch (_: Throwable) {}
        try { TaskBubble.serviceGone() } catch (_: Throwable) {}
        if (instance === this) instance = null
    }

    /** Runs an action and turns any crash into words, so one odd app can never stop phone control. */
    inline fun safe(what: String, block: () -> String): String =
        if (ScreenGuard.stale()) "Stopped: this task was stopped."
        else try { block() } catch (e: Throwable) { "Could not $what (${e.javaClass.simpleName}). Read the screen again and try another way." }

    // ---------------------------------------------------------------- reading the screen

    internal fun txt(n: AccessibilityNodeInfo): String = try { (n.text ?: "").toString().trim() } catch (_: Throwable) { "" }
    internal fun desc(n: AccessibilityNodeInfo): String = try { (n.contentDescription ?: "").toString().trim() } catch (_: Throwable) { "" }
    private fun hint(n: AccessibilityNodeInfo): String =
        if (Build.VERSION.SDK_INT >= 26) try { (n.hintText ?: "").toString().trim() } catch (_: Throwable) { "" } else ""
    internal fun idName(n: AccessibilityNodeInfo): String =
        try { (n.viewIdResourceName ?: "").substringAfterLast('/').replace('_', ' ').trim() } catch (_: Throwable) { "" }

    internal fun label(n: AccessibilityNodeInfo): String = listOf(txt(n), desc(n)).filter { it.isNotEmpty() }.distinct().joinToString(" | ")

    /** Text from the first few readable children, for buttons and rows that have no label of their own. */
    private fun childText(n: AccessibilityNodeInfo, depth: Int = 0, out: ArrayList<String> = ArrayList()): ArrayList<String> {
        if (depth > 4 || out.size >= 3) return out
        for (i in 0 until safeCount(n)) {
            val c = child(n, i) ?: continue
            val l = label(c)
            if (l.isNotEmpty() && out.none { it == l }) out.add(l)
            if (out.size >= 3) break
            childText(c, depth + 1, out)
        }
        return out
    }

    internal fun safeCount(n: AccessibilityNodeInfo) = try { n.childCount } catch (_: Throwable) { 0 }
    internal fun child(n: AccessibilityNodeInfo, i: Int): AccessibilityNodeInfo? = try { n.getChild(i) } catch (_: Throwable) { null }
    internal fun bounds(n: AccessibilityNodeInfo): Rect { val r = Rect(); try { n.getBoundsInScreen(r) } catch (_: Throwable) {}; return r }

    /** The current screen as numbered elements the agent can act on. */
    fun screen(): String = safe("read the screen") {
        val root = appRoot() ?: return@safe "The screen can't be read right now (it may be locked, loading or protected). Wait a second and read it again."
        val list = ArrayList<AccessibilityNodeInfo>()
        val sb = StringBuilder()
        sb.append("App: ").append(root.packageName ?: "unknown").append('\n')
        val kb = try { windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD } } catch (_: Throwable) { false }
        if (kb) sb.append("(keyboard is open)\n")
        val dm = resources.displayMetrics
        walk(root, sb, 0, list, dm.widthPixels, dm.heightPixels)
        nodes = list
        if (list.isEmpty()) sb.append("(nothing readable on screen: try phone_wait, or phone_gesture by position)\n")
        sb.append("\nUse the numbers with phone_tap, phone_type, phone_scroll and phone_long_press. (x%,y%) is where it sits, for phone_gesture.")
        val s = sb.toString()
        if (s.length > 14000) s.substring(0, 14000) + "\n…(cut: scroll to see more)" else s
    }

    private fun walk(n: AccessibilityNodeInfo, sb: StringBuilder, depth: Int, list: ArrayList<AccessibilityNodeInfo>, w: Int, h: Int) {
        if (depth > 45 || list.size >= 250) return
        val visible = try { n.isVisibleToUser } catch (_: Throwable) { false }
        if (!visible) return
        val r = bounds(n)
        val text = txt(n)
        val d = desc(n)
        val clickable = n.isClickable || n.isLongClickable
        val useful = clickable || n.isEditable || n.isCheckable || n.isScrollable || text.isNotEmpty() || d.isNotEmpty()
        // A plain text that sits inside a clickable row is already shown on that row.
        if (useful && !r.isEmpty) {
            list.add(n)
            val idx = list.size
            val cls = (n.className ?: "").toString().substringAfterLast('.')
            val kind = when {
                n.isEditable -> "Field"
                n.isCheckable -> if (n.isChecked) "On" else "Off"
                cls.contains("Button") || (clickable && cls.contains("Image")) -> "Button"
                n.isScrollable -> "List"
                clickable -> "Tap"
                else -> "Text"
            }
            var l = label(n)
            if (n.isEditable) {
                val hn = hint(n)
                l = when {
                    text.isEmpty() && hn.isNotEmpty() -> "empty, hint: $hn"
                    hn.isNotEmpty() && text == hn -> "empty, hint: $hn"
                    else -> l
                }
            }
            if (l.isEmpty() && (clickable || n.isScrollable)) l = childText(n).joinToString(" · ")
            val id = idName(n)
            sb.append('[').append(idx).append("] ").append(kind)
            if (l.isNotEmpty()) sb.append(" \"").append(l.take(150).replace('\n', ' ')).append('"')
            if (id.isNotEmpty() && (l.isEmpty() || kind == "Button")) sb.append(" id:").append(id.take(40))
            if (!n.isEnabled) sb.append(" (disabled)")
            if (n.isSelected) sb.append(" (selected)")
            sb.append(" (").append((r.exactCenterX() * 100 / w).toInt()).append("%,").append((r.exactCenterY() * 100 / h).toInt()).append("%)")
            sb.append('\n')
        }
        for (i in 0 until safeCount(n)) {
            val c = child(n, i) ?: continue
            walk(c, sb, depth + 1, list, w, h)
        }
    }

    /** The app the user sees: skips SubMac's own floating card so phone control reads the real app underneath. */
    internal fun appRoot(): AccessibilityNodeInfo? {
        try {
            val all = windows
            val apps = all.filter { it.type == AccessibilityWindowInfo.TYPE_APPLICATION || it.type == AccessibilityWindowInfo.TYPE_SYSTEM }
            fun pkg(wi: AccessibilityWindowInfo) = try { wi.root?.packageName?.toString() } catch (_: Throwable) { null }
            val pick = apps.firstOrNull { it.isFocused && pkg(it) != packageName && it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
                ?: apps.firstOrNull { it.isActive && pkg(it) != packageName && it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
                ?: apps.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_APPLICATION && pkg(it) != packageName }
                ?: apps.firstOrNull { it.isFocused || it.isActive }
            pick?.root?.let { return it }
        } catch (_: Throwable) {}
        return try { rootInActiveWindow } catch (_: Throwable) { null }
    }

    private fun node(id: Int): AccessibilityNodeInfo? {
        val l = nodes
        val n = if (id in 1..l.size) l[id - 1] else return null
        // A node from an older screen may be gone; refresh() says whether it still exists.
        return try { if (n.refresh()) n else null } catch (_: Throwable) { null }
    }

    // ---------------------------------------------------------------- tapping

    private fun clickUp(n: AccessibilityNodeInfo): Boolean {
        var p: AccessibilityNodeInfo? = n
        var hops = 0
        while (p != null && hops < 8) {
            try { if (p.isClickable && p.isEnabled && p.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true } catch (_: Throwable) {}
            p = try { p.parent } catch (_: Throwable) { null }
            hops++
        }
        return false
    }

    /**
     * A clickable element gets the click action (exact, never hits the keyboard by mistake); anything
     * else gets a real finger tap at its centre, which apps built with Flutter, Compose or web views need.
     */
    internal fun press(n: AccessibilityNodeInfo): Boolean {
        val own = try { n.isClickable && n.isEnabled && n.performAction(AccessibilityNodeInfo.ACTION_CLICK) } catch (_: Throwable) { false }
        return own || gestureAt(n, 60) || clickUp(n)
    }

    private fun showTap(n: AccessibilityNodeInfo, long: Boolean = false) {
        val r = bounds(n)
        if (r.isEmpty) ghost.active() else ghost.tap(r.exactCenterX(), r.exactCenterY(), long)
    }

    fun tap(id: Int): String = safe("tap $id") {
        val n = node(id) ?: return@safe "Element $id is not on screen any more. Read the screen again for fresh numbers."
        if (!n.isEnabled) return@safe "Element $id is disabled right now (maybe something must be filled in first)."
        showTap(n)
        if (press(n)) "Tapped $id." else "Could not tap $id."
    }

    /** Taps the element whose text best matches [text] (exact first, then the shortest that contains it). */
    fun tapText(text: String): String = safe("tap \"$text\"") {
        val root = appRoot() ?: return@safe "The screen can't be read right now."
        val q = text.trim().lowercase()
        if (q.isEmpty()) return@safe "Say what to tap."
        val found = ArrayList<AccessibilityNodeInfo>()
        fun collect(n: AccessibilityNodeInfo, d: Int) {
            if (d > 45 || found.size > 40) return
            if (!(try { n.isVisibleToUser } catch (_: Throwable) { false })) return
            val l = (label(n) + " " + idName(n)).lowercase()
            if (l.contains(q)) found.add(n)
            for (i in 0 until safeCount(n)) child(n, i)?.let { collect(it, d + 1) }
        }
        collect(root, 0)
        if (found.isEmpty()) return@safe "Nothing on screen says \"$text\". Read the screen and tap by number, or scroll to find it."
        val best = found.firstOrNull { label(it).lowercase() == q }
            ?: found.firstOrNull { idName(it).lowercase() == q }
            ?: found.minByOrNull { label(it).length }!!
        val name = label(best).ifEmpty { idName(best) }.take(60)
        showTap(best)
        if (press(best)) "Tapped \"$name\"." else "Could not tap \"$text\"."
    }

    fun longPress(id: Int): String = safe("long-press $id") {
        val n = node(id) ?: return@safe "Element $id is not on screen any more. Read the screen again."
        showTap(n, true)
        if (gestureAt(n, 750)) return@safe "Long-pressed $id."
        if (try { n.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK) } catch (_: Throwable) { false }) "Long-pressed $id." else "Could not long-press $id."
    }

    /** Tap by position, in percent of the screen (0-100). */
    fun tapAt(xp: Float, yp: Float, ms: Long): String = safe("tap there") {
        val dm = resources.displayMetrics
        val x = dm.widthPixels * xp / 100f
        val y = dm.heightPixels * yp / 100f
        ghost.tap(x, y, ms > 400)
        val p = Path().apply { moveTo(x, y) }
        if (dispatch(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(p, 0, ms)).build())) "Tapped there." else "Could not tap."
    }

    // ---------------------------------------------------------------- typing

    private fun editableNear(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (n.isEditable) return n
        firstField(n, 0)?.let { return it }
        var p = try { n.parent } catch (_: Throwable) { null }
        var hops = 0
        while (p != null && hops < 3) {
            if (p.isEditable) return p
            p = try { p.parent } catch (_: Throwable) { null }
            hops++
        }
        return null
    }

    internal fun firstField(n: AccessibilityNodeInfo, d: Int): AccessibilityNodeInfo? {
        if (d > 45) return null
        if (n.isEditable && (try { n.isVisibleToUser } catch (_: Throwable) { false })) return n
        for (i in 0 until safeCount(n)) {
            val c = child(n, i) ?: continue
            firstField(c, d + 1)?.let { return it }
        }
        return null
    }

    internal fun setText(n: AccessibilityNodeInfo, text: String): Boolean {
        showType(n)
        try { n.performAction(AccessibilityNodeInfo.ACTION_CLICK) } catch (_: Throwable) {}
        try { n.performAction(AccessibilityNodeInfo.ACTION_FOCUS) } catch (_: Throwable) {}
        val b = Bundle()
        b.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        val ok = try { n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, b) } catch (_: Throwable) { false }
        SystemClock.sleep(120)
        if (ok && textMatches(n, text)) return true
        // Some apps (custom editors, web fields) ignore SET_TEXT: paste it like a person would.
        return paste(n, text) || ok
    }

    private fun textMatches(n: AccessibilityNodeInfo, text: String): Boolean = try {
        n.refresh()
        val now = (n.text ?: "").toString()
        now.contains(text.take(20)) || text.isEmpty()
    } catch (_: Throwable) { true }

    private fun paste(n: AccessibilityNodeInfo, text: String): Boolean {
        val latch = CountDownLatch(1)
        main.post {
            try {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("SubMac", text))
            } catch (_: Throwable) {}
            latch.countDown()
        }
        latch.await(1, TimeUnit.SECONDS)
        try {
            val sel = Bundle()
            sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
            sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, (n.text ?: "").length)
            n.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel)
        } catch (_: Throwable) {}
        val ok = try { n.performAction(AccessibilityNodeInfo.ACTION_PASTE) } catch (_: Throwable) { false }
        SystemClock.sleep(120)
        return ok && textMatches(n, text)
    }

    private fun showType(n: AccessibilityNodeInfo) {
        val r = bounds(n)
        if (r.isEmpty) ghost.active() else ghost.type(android.graphics.RectF(r))
    }

    fun type(id: Int, text: String): String = safe("type") {
        val n = node(id) ?: return@safe "Element $id is not on screen any more. Read the screen again."
        val f = editableNear(n) ?: return@safe "Element $id is not a text field. Tap it first if it opens one, then type."
        if (setText(f, text)) "Typed it into $id." else "The field did not take the text. Tap it, then type without an id."
    }

    /** Types into the focused field, or the first field on screen. */
    fun typeFocused(text: String): String = safe("type") {
        val root = appRoot() ?: return@safe "The screen can't be read right now."
        var f = try { root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) } catch (_: Throwable) { null }
        if (f == null || !f.isEditable) f = firstField(root, 0)
        val n = f ?: return@safe "There's no text field on screen. Tap the search or message box first."
        if (setText(n, text)) "Typed it." else "The field did not take the text."
    }

    /** Presses the keyboard's enter, search or send key; falls back to a visible Send/Search button. */
    fun enter(): String = safe("press enter") {
        val root = appRoot() ?: return@safe "The screen can't be read right now."
        val f = try { root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) } catch (_: Throwable) { null }
        if (f != null && Build.VERSION.SDK_INT >= 30) {
            if (try { f.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id) } catch (_: Throwable) { false }) return@safe "Pressed enter."
        }
        for (word in listOf("send", "search", "go", "done", "next", "submit")) {
            val hit = findByWord(root, word) ?: continue
            showTap(hit)
            if (press(hit)) return@safe "Pressed ${label(hit).ifEmpty { word }}."
        }
        "There is no enter key here; tap the send or search button by number."
    }

    private fun findByWord(n: AccessibilityNodeInfo, word: String, d: Int = 0): AccessibilityNodeInfo? {
        if (d > 45) return null
        if ((n.isClickable) && (try { n.isVisibleToUser } catch (_: Throwable) { false })) {
            val l = (label(n) + " " + idName(n)).lowercase()
            if (Regex("\\b$word\\b").containsMatchIn(l)) return n
        }
        for (i in 0 until safeCount(n)) {
            val c = child(n, i) ?: continue
            findByWord(c, word, d + 1)?.let { return it }
        }
        return null
    }

    // ---------------------------------------------------------------- scrolling and swiping

    /** A cheap fingerprint of what is visible, to tell whether a scroll really moved anything. */
    private fun signature(): String {
        val root = appRoot() ?: return ""
        val sb = StringBuilder()
        fun go(n: AccessibilityNodeInfo, d: Int) {
            if (d > 30 || sb.length > 3000) return
            if (!(try { n.isVisibleToUser } catch (_: Throwable) { false })) return
            val t = txt(n); if (t.isNotEmpty()) sb.append(t.take(30)).append('|')
            val r = bounds(n); if (n.isScrollable) sb.append(r.top).append(',')
            for (i in 0 until safeCount(n)) child(n, i)?.let { go(it, d + 1) }
        }
        go(root, 0)
        return sb.toString()
    }

    /** The biggest scrollable area on screen (the main list), not the first little carousel. */
    internal fun mainScrollable(root: AccessibilityNodeInfo, horizontal: Boolean): AccessibilityNodeInfo? {
        var best: AccessibilityNodeInfo? = null
        var bestArea = 0L
        fun go(n: AccessibilityNodeInfo, d: Int) {
            if (d > 45) return
            if (!(try { n.isVisibleToUser } catch (_: Throwable) { false })) return
            if (n.isScrollable) {
                val r = bounds(n)
                val wide = r.width() > r.height() * 1.6
                if (!r.isEmpty && (!horizontal || wide)) {
                    val area = r.width().toLong() * r.height()
                    if (area > bestArea) { bestArea = area; best = n }
                }
            }
            for (i in 0 until safeCount(n)) child(n, i)?.let { go(it, d + 1) }
        }
        go(root, 0)
        return best
    }

    /**
     * Scrolls the main list (or element [id]) by a real finger swipe, which every app understands,
     * and checks the screen moved. [amount]: "page" (default), "little" or "lots".
     */
    fun scroll(direction: String, id: Int = -1, amount: String = "page"): String = safe("scroll") {
        val root = appRoot() ?: return@safe "The screen can't be read right now."
        val horizontal = direction == "left" || direction == "right"
        val target = (if (id > 0) node(id) else null) ?: mainScrollable(root, horizontal)
        val dm = resources.displayMetrics
        val area = target?.let { bounds(it) }?.takeIf { !it.isEmpty && it.height() > dm.heightPixels / 6 }
            ?: Rect(0, (dm.heightPixels * 0.15).toInt(), dm.widthPixels, (dm.heightPixels * 0.85).toInt())
        val reach = when (amount) { "little" -> 0.3f; "lots" -> 0.8f; else -> 0.6f }
        val before = signature()
        val times = if (amount == "lots") 2 else 1
        repeat(times) {
            if (horizontal) {
                val y = area.exactCenterY()
                val a = area.left + area.width() * (0.5f + reach / 2); val b = area.left + area.width() * (0.5f - reach / 2)
                // "right" means see what is to the right: the finger moves right-to-left.
                if (direction == "right") swipe(a, y, b, y, 300) else swipe(b, y, a, y, 300)
            } else {
                val x = area.exactCenterX()
                val lo = area.top + area.height() * (0.5f + reach / 2); val hi = area.top + area.height() * (0.5f - reach / 2)
                // "down" means see what is further down: the finger moves up.
                if (direction == "down") swipe(x, lo, x, hi, 380) else swipe(x, hi, x, lo, 380)
            }
            SystemClock.sleep(350)
        }
        if (signature() != before) return@safe "Scrolled $direction."
        // The swipe did nothing (some lists only take the scroll action).
        val ok = try {
            target?.performAction(if (direction == "down" || direction == "right") AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD) == true
        } catch (_: Throwable) { false }
        SystemClock.sleep(300)
        if (ok && signature() != before) "Scrolled $direction." else "Nothing moved: this is probably the ${if (direction == "down" || direction == "right") "end" else "start"} of the list."
    }

    fun swipePct(x1: Float, y1: Float, x2: Float, y2: Float, ms: Long = 400): String = safe("swipe") {
        val dm = resources.displayMetrics
        val ok = swipe(dm.widthPixels * x1 / 100f, dm.heightPixels * y1 / 100f, dm.widthPixels * x2 / 100f, dm.heightPixels * y2 / 100f, ms)
        if (ok) "Swiped." else "Could not swipe."
    }

    fun global(action: String): String = safe(action) {
        val a = when (action) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
            "screenshot" -> if (Build.VERSION.SDK_INT >= 28) GLOBAL_ACTION_TAKE_SCREENSHOT else return@safe "Screenshots need Android 9 or newer."
            "lock" -> if (Build.VERSION.SDK_INT >= 28) GLOBAL_ACTION_LOCK_SCREEN else return@safe "Locking needs Android 9 or newer."
            else -> return@safe "Unknown button $action."
        }
        ghost.active()
        if (performGlobalAction(a)) "Pressed $action." else "Could not press $action."
    }

    // ---------------------------------------------------------------- gestures

    private fun gestureAt(n: AccessibilityNodeInfo, ms: Long): Boolean {
        val r = bounds(n)
        val dm = resources.displayMetrics
        if (r.isEmpty || r.right <= 0 || r.bottom <= 0 || r.left >= dm.widthPixels || r.top >= dm.heightPixels) return false
        val x = r.exactCenterX().coerceIn(1f, dm.widthPixels - 1f)
        val y = r.exactCenterY().coerceIn(1f, dm.heightPixels - 1f)
        val p = Path().apply { moveTo(x, y) }
        return dispatch(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(p, 0, ms)).build())
    }

    internal fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, ms: Long): Boolean {
        ghost.swipe(x1, y1, x2, y2, ms)
        val p = Path().apply { moveTo(x1, y1); lineTo(x2, y2) }
        return dispatch(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(p, 0, ms)).build())
    }

    /** Sends a gesture and waits until Android says it finished, so the next step sees its result. */
    private fun dispatch(g: GestureDescription): Boolean {
        if (ScreenGuard.stale()) return false
        if (Looper.myLooper() == Looper.getMainLooper()) return try { dispatchGesture(g, null, null) } catch (_: Throwable) { false }
        // The floating task chat steps out of the way (and lets touches through) while the gesture runs.
        val area = gestureArea(g)
        TaskBubble.beforeGesture(area)
        return try {
            dispatchWait(g)
        } finally {
            TaskBubble.afterGesture()
        }
    }

    /** The screen area a gesture touches. */
    private fun gestureArea(g: GestureDescription): android.graphics.RectF {
        val all = android.graphics.RectF()
        try {
            for (i in 0 until g.strokeCount) {
                val b = android.graphics.RectF()
                g.getStroke(i).path.computeBounds(b, true)
                if (i == 0) all.set(b) else all.union(b.left, b.top, b.right, b.bottom)
            }
        } catch (_: Throwable) {}
        return all
    }

    private fun dispatchWait(g: GestureDescription): Boolean {
        val latch = CountDownLatch(1)
        var ok = false
        val cb = object : GestureResultCallback() {
            override fun onCompleted(d: GestureDescription?) { ok = true; latch.countDown() }
            override fun onCancelled(d: GestureDescription?) { ok = false; latch.countDown() }
        }
        val sent = try { dispatchGesture(g, cb, main) } catch (_: Throwable) { false }
        if (!sent) return false
        latch.await(4, TimeUnit.SECONDS)
        return ok
    }

    // ---------------------------------------------------------------- screenshot for models that can see

    /**
     * A small screenshot of the screen with the element numbers drawn on, for models that can see.
     * Android 11+ only; older phones (and protected screens) just get the text list.
     */
    fun shot(done: (ByteArray?) -> Unit) {
        if (Build.VERSION.SDK_INT < 30) { done(null); return }
        val boxes = ArrayList<Pair<Int, Rect>>()
        for ((i, n) in nodes.withIndex()) {
            try {
                if (!(n.isClickable || n.isEditable || n.isCheckable || n.isLongClickable || n.isScrollable)) continue
            } catch (_: Throwable) { continue }
            val r = bounds(n)
            if (!r.isEmpty) boxes.add(Pair(i + 1, r))
        }
        val finish: (ByteArray?) -> Unit = { b -> ghost.reveal(); done(b) }
        ghost.hiddenFor { capture(boxes, finish) }
    }

    private fun capture(boxes: ArrayList<Pair<Int, Rect>>, done: (ByteArray?) -> Unit) {
        if (Build.VERSION.SDK_INT < 30) { done(null); return }
        try {
            takeScreenshot(android.view.Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
                override fun onSuccess(s: ScreenshotResult) {
                    Thread {
                        var out: ByteArray? = null
                        try {
                            val hw = android.graphics.Bitmap.wrapHardwareBuffer(s.hardwareBuffer, s.colorSpace)
                            s.hardwareBuffer.close()
                            if (hw != null) {
                                val w = 640
                                val scale = w.toFloat() / hw.width
                                val h = (hw.height * scale).toInt()
                                val soft = hw.copy(android.graphics.Bitmap.Config.ARGB_8888, false)
                                hw.recycle()
                                val small = android.graphics.Bitmap.createScaledBitmap(soft, w, h, true)
                                soft.recycle()
                                val bmp = small.copy(android.graphics.Bitmap.Config.ARGB_8888, true)
                                small.recycle()
                                val cv = android.graphics.Canvas(bmp)
                                val mark = 0xFFE5281B.toInt()
                                val stroke = android.graphics.Paint().apply { color = mark; style = android.graphics.Paint.Style.STROKE; strokeWidth = 2f }
                                val fill = android.graphics.Paint().apply { color = mark; style = android.graphics.Paint.Style.FILL }
                                val txt = android.graphics.Paint().apply { color = 0xFFFFFFFF.toInt(); textSize = 13f; isAntiAlias = true; isFakeBoldText = true }
                                for ((num, r) in boxes) {
                                    val l = r.left * scale; val t = r.top * scale; val rr = r.right * scale; val b = r.bottom * scale
                                    cv.drawRect(l, t, rr, b, stroke)
                                    val label = num.toString()
                                    val tw = txt.measureText(label) + 6f
                                    cv.drawRect(l, t, l + tw, t + 16f, fill)
                                    cv.drawText(label, l + 3f, t + 13f, txt)
                                }
                                val bos = java.io.ByteArrayOutputStream()
                                bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 60, bos)
                                bmp.recycle()
                                out = bos.toByteArray()
                            }
                        } catch (_: Throwable) {}
                        val r = out
                        main.post { done(r) }
                    }.start()
                }

                override fun onFailure(errorCode: Int) { done(null) }
            })
        } catch (_: Throwable) { done(null) }
    }
}
