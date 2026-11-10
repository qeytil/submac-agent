package com.telesia.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.util.zip.ZipInputStream

/** "telesia/system": wake word, floating Live, phone control, SMS, notifications, permissions. */
object Bridge {
    var activity: WeakReference<Activity>? = null
    @Volatile var foreground = false
    private var channel: MethodChannel? = null
    private lateinit var ctx: Context
    private val main = Handler(Looper.getMainLooper())
    private var dartReady = false
    private val queue = ArrayList<Pair<String, Any?>>()

    fun attach(c: Context, engine: FlutterEngine) {
        ctx = c
        dartReady = false
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "telesia/system")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "ready" -> {
                        dartReady = true
                        val q = ArrayList(queue)
                        queue.clear()
                        for ((m, a) in q) ch.invokeMethod(m, a)
                        result.success(true)
                    }
                    "permissions" -> result.success(permissions())
                    // ---- save a picture, video or sound into the phone's gallery / music / downloads ----
                    "saveMedia" -> {
                        val path = call.argument<String>("path") ?: ""
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        val name = call.argument<String>("name") ?: File(path).name
                        val folder = call.argument<String>("folder") ?: ""
                        Thread {
                            val r = try { saveMedia(path, name, mime, folder) } catch (e: Exception) { "error: " + (e.message ?: "could not save") }
                            main.post { result.success(r) }
                        }.start()
                    }
                    "openPermission" -> {
                        openPermission(call.argument<String>("name") ?: "")
                        result.success(true)
                    }
                    // ---- wake word ----
                    "wakeStart" -> {
                        WakeService.start(
                            ctx,
                            call.argument<String>("model") ?: "",
                            (call.argument<Double>("sensitivity") ?: 0.6).toFloat(),
                            call.argument<Boolean>("screenOff") ?: true
                        )
                        result.success(true)
                    }
                    "wakeStop" -> {
                        WakeService.stop(ctx)
                        result.success(true)
                    }
                    "wakePause" -> {
                        WakeService.paused = true
                        result.success(true)
                    }
                    "wakeResume" -> {
                        WakeService.paused = false
                        result.success(true)
                    }
                    "wakeSensitivity" -> {
                        WakeService.sensitivity = (call.argument<Double>("value") ?: 0.6).toFloat()
                        result.success(true)
                    }
                    "wakeState" -> result.success(WakeService.state)
                    "liveHold" -> {
                        WakeService.live(ctx, call.argument<Boolean>("on") == true)
                        result.success(true)
                    }
                    "unzip" -> {
                        val zip = call.argument<String>("zip") ?: ""
                        val dest = call.argument<String>("dest") ?: ""
                        Thread {
                            val r = try {
                                unzip(File(zip), File(dest)); null
                            } catch (e: Exception) {
                                e.message ?: e.toString()
                            }
                            main.post { if (r == null) result.success(true) else result.error("unzip", r, null) }
                        }.start()
                    }
                    "chime" -> {
                        Chime.play(ctx)
                        result.success(true)
                    }
                    // ---- floating Live ----
                    "overlayShow" -> {
                        result.success(Overlay.show(ctx, call.argument<String>("mode") ?: "popup"))
                    }
                    "overlayUpdate" -> {
                        Overlay.update(
                            call.argument<String>("status") ?: "",
                            (call.argument<Double>("level") ?: 0.0).toFloat(),
                            call.argument<String>("caption") ?: "",
                            call.argument<String>("you") ?: "",
                            call.argument<Boolean>("muted") ?: false,
                            call.argument<Boolean>("thinking") ?: false
                        )
                        result.success(true)
                    }
                    "overlayHide" -> {
                        Overlay.hide()
                        result.success(true)
                    }
                    "moveToBack" -> {
                        activity?.get()?.moveTaskToBack(true)
                        result.success(true)
                    }
                    "bringToFront" -> {
                        bringToFront(call.argument<String>("route"))
                        result.success(true)
                    }
                    "isForeground" -> result.success(foreground)
                    // ---- notifications ----
                    "notify" -> {
                        Notifier.task(
                            ctx,
                            call.argument<Int>("id") ?: 1,
                            call.argument<String>("title") ?: "Telesia",
                            call.argument<String>("body") ?: "",
                            call.argument<String>("payload") ?: "",
                            call.argument<String>("kind") ?: "done"
                        )
                        result.success(true)
                    }
                    // ---- bots: calls, messages, notification watches ----
                    "ring" -> {
                        Notifier.ring(
                            ctx,
                            call.argument<Int>("id") ?: 9100,
                            call.argument<String>("bot") ?: "",
                            call.argument<String>("name") ?: "Telesia",
                            call.argument<String>("reason") ?: "",
                            call.argument<Boolean>("full") ?: false
                        )
                        result.success(true)
                    }
                    "ringCancel" -> {
                        Notifier.ringCancel(ctx, call.argument<Int>("id") ?: 0)
                        result.success(true)
                    }
                    "notifyBot" -> {
                        Notifier.bot(
                            ctx,
                            call.argument<Int>("id") ?: 9200,
                            call.argument<String>("name") ?: "Telesia",
                            call.argument<String>("body") ?: "",
                            call.argument<String>("payload") ?: "",
                            call.argument<Boolean>("reply") ?: false
                        )
                        result.success(true)
                    }
                    // Who it is from decides the channel and look (docs/notifications.md): agent | bots.
                    "notifyFrom" -> {
                        Notifier.from(
                            ctx,
                            call.argument<Int>("id") ?: 9200,
                            call.argument<String>("channel") ?: Notifier.BOTS,
                            call.argument<String>("title") ?: "Telesia",
                            call.argument<String>("body") ?: "",
                            call.argument<String>("payload") ?: "",
                            call.argument<Boolean>("reply") ?: false,
                            call.argument<String>("initial") ?: "",
                            (call.argument<Number>("color") ?: 0).toLong().toInt(),
                            call.argument<Boolean>("high") ?: false
                        )
                        result.success(true)
                    }
                    // A team chat post: one conversation per team, inline Reply.
                    "notifyTeam" -> {
                        Notifier.team(
                            ctx,
                            call.argument<Int>("id") ?: 9700,
                            call.argument<String>("team") ?: "",
                            call.argument<String>("name") ?: "Team",
                            call.argument<String>("sender") ?: "",
                            call.argument<String>("text") ?: "",
                            call.argument<String>("initial") ?: "",
                            (call.argument<Number>("color") ?: 0).toLong().toInt(),
                            call.argument<Boolean>("needs") ?: false
                        )
                        result.success(true)
                    }
                    "notifyApproval" -> {
                        Notifier.approval(
                            ctx,
                            call.argument<Int>("id") ?: 9900,
                            call.argument<String>("approval") ?: "",
                            call.argument<String>("name") ?: "Telesia",
                            call.argument<String>("title") ?: "",
                            call.argument<String>("body") ?: ""
                        )
                        result.success(true)
                    }
                    "setNotifWatches" -> {
                        ctx.getSharedPreferences("telesia_bots", Context.MODE_PRIVATE).edit()
                            .putString("watches", call.argument<String>("json") ?: "[]").apply()
                        result.success(true)
                    }
                    // ---- real hands in the in-app browser ----
                    "webTouch" -> {
                        val w = WebHands.find(activity?.get(), call.argument<String>("url") ?: "", call.argument<String>("mark") ?: "")
                        if (w == null || w.width < 2 || w.height < 2) {
                            result.success("no-view")
                        } else {
                            // Coordinates arrive as fractions (0..1) of the visible page; scale to this view's pixels.
                            val ww = w.width.toFloat()
                            val wh = w.height.toFloat()
                            val x = ((call.argument<Double>("x") ?: 0.5).toFloat() * ww).coerceIn(1f, ww - 1f)
                            val y = ((call.argument<Double>("y") ?: 0.5).toFloat() * wh).coerceIn(1f, wh - 1f)
                            val kind = call.argument<String>("kind") ?: "tap"
                            val hold = (call.argument<Int>("hold") ?: 55).toLong()
                            var replied = false
                            val done = { if (!replied) { replied = true; result.success("ok") } }
                            when (kind) {
                                "swipe" -> WebHands.swipe(
                                    w, x, y,
                                    ((call.argument<Double>("x2") ?: 0.5).toFloat() * ww).coerceIn(1f, ww - 1f),
                                    ((call.argument<Double>("y2") ?: 0.5).toFloat() * wh).coerceIn(1f, wh - 1f),
                                    (call.argument<Int>("ms") ?: 320).toLong(), done
                                )
                                // The finger rests a little longer for a long press, and never exactly as long
                                // as last time for a tap (a machine is always the same length).
                                "long" -> WebHands.stroke(w, listOf(x to y), 0, hold.coerceAtLeast(500L), done)
                                else -> WebHands.stroke(w, listOf(x to y), 0, hold.coerceIn(28L, 260L), done)
                            }
                        }
                    }
                    // One gesture through many points: the path of a real finger (curved, with a wobble).
                    "webStroke" -> {
                        val w = WebHands.find(activity?.get(), call.argument<String>("url") ?: "", call.argument<String>("mark") ?: "")
                        val raw = call.argument<List<Any?>>("pts") ?: emptyList<Any?>()
                        if (w == null || w.width < 2 || w.height < 2) {
                            result.success("no-view")
                        } else {
                            val ww = w.width.toFloat()
                            val wh = w.height.toFloat()
                            val pts = ArrayList<Pair<Float, Float>>()
                            for (p in raw) {
                                val pair = p as? List<*> ?: continue
                                if (pair.size < 2) continue
                                val fx = (pair[0] as? Number)?.toFloat() ?: continue
                                val fy = (pair[1] as? Number)?.toFloat() ?: continue
                                pts.add((fx * ww).coerceIn(1f, ww - 1f) to (fy * wh).coerceIn(1f, wh - 1f))
                            }
                            if (pts.isEmpty()) {
                                result.success("no-view")
                            } else {
                                var replied = false
                                val done = { if (!replied) { replied = true; result.success("ok") } }
                                WebHands.stroke(w, pts, (call.argument<Int>("ms") ?: 320).toLong(), (call.argument<Int>("hold") ?: 30).toLong(), done)
                            }
                        }
                    }
                    "webType" -> {
                        val w = WebHands.find(activity?.get(), call.argument<String>("url") ?: "", call.argument<String>("mark") ?: "")
                        result.success(if (w == null) "no-view" else WebHands.type(w, call.argument<String>("text") ?: ""))
                    }
                    "webKey" -> {
                        val w = WebHands.find(activity?.get(), call.argument<String>("url") ?: "", call.argument<String>("mark") ?: "")
                        result.success(if (w == null) "no-view" else WebHands.key(w, call.argument<String>("key") ?: "enter"))
                    }
                    "clearTasks" -> {
                        Notifier.clearTasks(ctx)
                        result.success(true)
                    }
                    "keepAlive" -> {
                        if (call.argument<Boolean>("on") == true) TaskService.start(ctx, call.argument<String>("text") ?: "Telesia is active")
                        else TaskService.stop(ctx)
                        result.success(true)
                    }
                    "scheduleAlarm" -> {
                        Alarms.set(ctx, call.argument<String>("id") ?: "", (call.argument<Number>("at") ?: 0).toLong(), call.argument<String>("label") ?: "")
                        result.success(true)
                    }
                    "cancelAlarm" -> {
                        Alarms.cancel(ctx, call.argument<String>("id") ?: "")
                        result.success(true)
                    }
                    "takeLaunchPayload" -> {
                        val p = launchPayload
                        launchPayload = null
                        result.success(p)
                    }
                    // ---- phone control (Accessibility) ----
                    "a11yEnabled" -> result.success(TelesiaA11y.instance != null)
                    "a11yState" -> result.success(
                        when {
                            TelesiaA11y.instance != null -> "on"
                            a11yOnInSettings() -> "stalled"
                            else -> "off"
                        }
                    )
                    "a11yScreen", "a11yTap", "a11yLongPress", "a11yType", "a11yScroll", "a11yTapText",
                    "a11yTypeFocused", "a11yEnter", "a11yTapAt", "a11ySwipe", "a11yGlobal" -> a11yAsync(call, result)
                    "a11yShot" -> {
                        val a = TelesiaA11y.instance
                        if (a == null) result.success(null) else {
                            var answered = false
                            val h = android.os.Handler(android.os.Looper.getMainLooper())
                            val timeout = Runnable { if (!answered) { answered = true; result.success(null) } }
                            h.postDelayed(timeout, 2500)
                            a.shot { bytes -> if (!answered) { answered = true; h.removeCallbacks(timeout); result.success(bytes) } }
                        }
                    }
                    "device" -> result.success(Device.run(ctx, call.argument<String>("action") ?: "status", call.argument<String>("value") ?: ""))
                    "a11yBadge" -> {
                        val a = TelesiaA11y.instance
                        if (a != null) { if (call.argument<Boolean>("on") == true) a.ghost.active() else a.ghost.hideBadge() }
                        result.success(a != null)
                    }
                    "a11yIdle" -> result.success((TelesiaA11y.instance?.idleMs() ?: 99999L).toInt())
                    // ---- the floating task chat while Telesia or a bot drives the screen ----
                    "bubbleShow" -> result.success(TaskBubble.show(ctx, call.argument<String>("state") ?: "{}"))
                    "bubbleHide" -> {
                        TaskBubble.hide()
                        result.success(true)
                    }
                    // No task drives the screen any more: cancel queued phone steps and take the badge down.
                    "screenHalt" -> {
                        ScreenGuard.halt()
                        try { TelesiaA11y.instance?.ghost?.hideBadge() } catch (_: Throwable) {}
                        result.success(true)
                    }
                    // The app (re)started: nothing can be driving the screen, so clear whatever is still shown.
                    "screenReset" -> {
                        ScreenGuard.halt()
                        try { TelesiaA11y.instance?.ghost?.hideBadge() } catch (_: Throwable) {}
                        TaskBubble.hide()
                        result.success(true)
                    }
                    // ---- WhatsApp on this phone (notification access + phone control) ----
                    "waStatus" -> result.success(WhatsApp.status(ctx))
                    "waInbox" -> result.success(
                        WhatsApp.list(ctx, call.argument<String>("pkg") ?: "", call.argument<String>("query") ?: "",
                            call.argument<Boolean>("unread") ?: false, call.argument<Int>("limit") ?: 20, call.argument<Int>("per") ?: 6)
                    )
                    "waChat" -> result.success(WhatsApp.chatInfo(ctx, call.argument<String>("query") ?: "", call.argument<String>("pkg") ?: ""))
                    "waQuickReply" -> {
                        val q = call.argument<String>("chat") ?: ""
                        val p = call.argument<String>("pkg") ?: ""
                        val t = call.argument<String>("text") ?: ""
                        Thread {
                            val r = try { WhatsApp.quickReply(ctx, q, p, t) } catch (e: Throwable) { "error:" + e.javaClass.simpleName }
                            main.post { result.success(r) }
                        }.start()
                    }
                    "waCapture" -> {
                        WhatsApp.setCapturing(ctx, call.argument<Boolean>("on") ?: true)
                        result.success(true)
                    }
                    "waClear" -> {
                        WhatsApp.clear(ctx)
                        result.success(true)
                    }
                    "waAct" -> waAsync(call, result)
                    // ---- notifications from other apps ----
                    "notifList" -> result.success(
                        NotifListener.list(ctx, call.argument<Int>("limit") ?: 30, call.argument<String>("query") ?: "", call.argument<String>("app") ?: "")
                    )
                    // ---- SMS ----
                    "readSms" -> result.success(
                        Sms.read(ctx, call.argument<Int>("limit") ?: 20, call.argument<String>("query") ?: "", call.argument<String>("box") ?: "inbox")
                    )
                    // ---- Calendar and contacts (plan 4, tier A) ----
                    "calendarEvents" -> result.success(
                        PhoneData.events(ctx, call.argument<Number>("from")?.toLong() ?: System.currentTimeMillis(),
                            call.argument<Int>("days") ?: 7, call.argument<String>("query") ?: "", call.argument<Int>("limit") ?: 50)
                    )
                    "calendarAdd" -> result.success(
                        PhoneData.addEvent(ctx, call.argument<String>("title") ?: "Event",
                            call.argument<Number>("start")?.toLong() ?: 0L, call.argument<Number>("end")?.toLong() ?: 0L,
                            call.argument<Boolean>("allDay") ?: false, call.argument<String>("place") ?: "", call.argument<String>("notes") ?: "")
                    )
                    "contacts" -> result.success(
                        PhoneData.contacts(ctx, call.argument<String>("query") ?: "", call.argument<Int>("limit") ?: 20)
                    )
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("failed", e.message ?: e.toString(), null)
            }
        }
    }

    /** Sends an event to Dart, waiting until Dart has said it is ready. */
    fun send(method: String, args: Any? = null) {
        main.post {
            val ch = channel
            if (ch == null || !dartReady) {
                queue.add(method to args)
                if (ch == null) TelesiaApp.engine(TelesiaApp.app)
            } else {
                ch.invokeMethod(method, args)
            }
        }
    }

    // ---------- launch payload (notification taps) ----------
    @Volatile var launchPayload: String? = null

    fun handleLaunchIntent(i: Intent?) {
        val p = i?.getStringExtra("telesia_payload") ?: return
        i.removeExtra("telesia_payload")
        launchPayload = p
        send("notificationTap", p)
    }

    fun bringToFront(route: String?) {
        val i = Intent(ctx, MainActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (route != null) i.putExtra("telesia_payload", route)
        ctx.startActivity(i)
    }

    // ---------- permissions ----------
    private fun granted(p: String) = ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    fun permissions(): HashMap<String, Any> {
        val m = HashMap<String, Any>()
        m["overlay"] = Build.VERSION.SDK_INT < 23 || Settings.canDrawOverlays(ctx)
        m["accessibility"] = TelesiaA11y.instance != null
        // Switched on in Settings but not running: Android stopped it (crash, update or battery saver).
        m["accessibilityStalled"] = TelesiaA11y.instance == null && a11yOnInSettings()
        m["sms"] = granted(Manifest.permission.READ_SMS)
        m["calendar"] = granted(Manifest.permission.READ_CALENDAR) && granted(Manifest.permission.WRITE_CALENDAR)
        m["contacts"] = granted(Manifest.permission.READ_CONTACTS)
        m["notifications"] = if (Build.VERSION.SDK_INT >= 33) granted("android.permission.POST_NOTIFICATIONS") else true
        m["microphone"] = granted(Manifest.permission.RECORD_AUDIO)
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        m["battery"] = pm.isIgnoringBatteryOptimizations(ctx.packageName)
        m["notifRead"] = NotifListener.enabled(ctx)
        return m
    }

    /** One phone action at a time, off the main thread, with a time limit: a slow app can't freeze Telesia. */
    private val a11yWorker = java.util.concurrent.Executors.newSingleThreadExecutor()

    private fun a11yAsync(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val a = TelesiaA11y.instance
        if (a == null) {
            result.success(if (a11yOnInSettings()) "PHONE_CONTROL_STALLED" else "Phone control is off.")
            return
        }
        var answered = false
        fun answer(v: String) = main.post { if (!answered) { answered = true; try { result.success(v) } catch (_: Throwable) {} } }
        main.postDelayed({ answer("That took too long (the app may be busy). Read the screen again, then try once more.") }, 15000)
        val g = ScreenGuard.gen
        try {
            a11yWorker.execute {
                ScreenGuard.enter(g)
                if (ScreenGuard.stale()) { ScreenGuard.exit(); answer("Stopped: this task was stopped."); return@execute }
                if (call.method == "a11yType" || call.method == "a11yTypeFocused") TaskBubble.yieldFocus()
                val out = try {
                    fun f(k: String, d: Double) = (call.argument<Number>(k) ?: d).toFloat()
                    when (call.method) {
                        "a11yScreen" -> a.screen()
                        "a11yTap" -> a.tap(call.argument<Int>("id") ?: -1)
                        "a11yLongPress" -> a.longPress(call.argument<Int>("id") ?: -1)
                        "a11yType" -> a.type(call.argument<Int>("id") ?: -1, call.argument<String>("text") ?: "")
                        "a11yScroll" -> a.scroll(call.argument<String>("direction") ?: "down", call.argument<Int>("id") ?: -1, call.argument<String>("amount") ?: "page")
                        "a11yTapText" -> a.tapText(call.argument<String>("text") ?: "")
                        "a11yTypeFocused" -> a.typeFocused(call.argument<String>("text") ?: "")
                        "a11yEnter" -> a.enter()
                        "a11yTapAt" -> a.tapAt(f("x", 50.0), f("y", 50.0), if (call.argument<Boolean>("long") == true) 750L else 60L)
                        "a11ySwipe" -> a.swipePct(f("x1", 50.0), f("y1", 70.0), f("x2", 50.0), f("y2", 30.0), (call.argument<Number>("ms") ?: 400).toLong())
                        "a11yGlobal" -> a.global(call.argument<String>("action") ?: "back")
                        else -> "Unknown phone action."
                    }
                } catch (e: Throwable) { "Phone control hit an error (${e.javaClass.simpleName}). Read the screen again and try another way." }
                finally { ScreenGuard.exit() }
                answer(out)
            }
        } catch (e: Throwable) { answer("Phone control is busy. Try again in a moment.") }
    }

    /** WhatsApp actions that open WhatsApp and press its buttons. One at a time on the phone-control worker. */
    private fun waAsync(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        var answered = false
        fun answer(v: String) = main.post { if (!answered) { answered = true; try { result.success(v) } catch (_: Throwable) {} } }
        fun j(ok: Boolean, state: String, detail: String = "") =
            org.json.JSONObject().apply { put("ok", ok); put("state", state); if (detail.isNotEmpty()) put("detail", detail) }.toString()
        main.postDelayed({ answer(j(false, "timeout", "WhatsApp took too long. Check the phone screen.")) }, 70000)
        val act = call.argument<String>("action") ?: ""
        val pkg = call.argument<String>("pkg") ?: WhatsApp.PERSONAL
        val phone = (call.argument<String>("phone") ?: "").filter { it.isDigit() }
        val name = call.argument<String>("name") ?: ""
        val text = call.argument<String>("text") ?: ""
        val g = ScreenGuard.gen
        try {
            a11yWorker.execute {
                ScreenGuard.enter(g)
                if (ScreenGuard.stale()) { ScreenGuard.exit(); answer(j(false, "stopped", "This task was stopped.")); return@execute }
                if (act != "read") TaskBubble.yieldFocus()
                val out = try {
                    val a = TelesiaA11y.instance
                    val hands = a?.let { WaHands(it) }
                    a?.ghost?.active()
                    fun opened(r: String) = r == "ok"
                    when {
                        !WhatsApp.installed(ctx, pkg) -> j(false, "not_installed", WhatsApp.appName(pkg) + " is not installed on this phone.")
                        act != "read" && act != "call" && WhatsApp.locked(ctx) -> j(false, "locked", "The phone is locked. Unlock it, or reply from the notification.")
                        act == "send_phone" -> {
                            if (!opened(WhatsApp.openChat(ctx, pkg, phone, text))) j(false, "error", "WhatsApp could not open that number.")
                            else if (hands == null) j(false, "opened_for_user", "The chat is open with the message typed in. Phone control is off, so the user taps Send.")
                            else {
                                android.os.SystemClock.sleep(1200)
                                val r = org.json.JSONObject(hands.sendInChat(pkg, text))
                                if (r.optBoolean("ok")) r.put("chat", hands.chatTitle(pkg)).toString()
                                else j(false, "opened_for_user", r.optString("detail") + " The message is ready in WhatsApp for the user to tap Send.")
                            }
                        }
                        hands == null -> j(false, "phone_control_off", "Phone control is off. Turn it on in Telesia > Apps > WhatsApp.")
                        act == "send_name" || act == "open_name" -> {
                            WhatsApp.openHome(ctx, pkg)
                            android.os.SystemClock.sleep(1200)
                            val o = org.json.JSONObject(hands.openByName(pkg, name))
                            if (!o.optBoolean("ok") || act == "open_name") o.toString()
                            else org.json.JSONObject(hands.sendInChat(pkg, text)).put("chat", o.optString("detail")).toString()
                        }
                        act == "open_phone" -> {
                            if (!opened(WhatsApp.openChat(ctx, pkg, phone, ""))) j(false, "error", "WhatsApp could not open that number.")
                            else {
                                android.os.SystemClock.sleep(1500)
                                val t = hands.chatTitle(pkg)
                                if (t.isEmpty()) j(false, "not_in_chat", "WhatsApp did not open the chat (the number may not be on WhatsApp).") else j(true, "opened", t)
                            }
                        }
                        act == "read" -> hands.readChat(pkg, call.argument<Int>("pages") ?: 0)
                        act == "call" -> hands.call(pkg, call.argument<Boolean>("video") == true)
                        act == "share" -> {
                            val path = call.argument<String>("path") ?: ""
                            val mime = (call.argument<String>("mime") ?: "").ifEmpty { WhatsApp.mimeFor(path) }
                            val r = WhatsApp.shareFile(ctx, pkg, path, mime, phone, call.argument<String>("caption") ?: "")
                            if (r != "ok") j(false, r.substringBefore(':'), r)
                            else { android.os.SystemClock.sleep(1500); hands.shareSend(pkg, if (phone.isEmpty()) name else "") }
                        }
                        act == "title" -> j(true, "title", hands.chatTitle(pkg))
                        else -> j(false, "error", "Unknown WhatsApp action.")
                    }
                } catch (e: Throwable) { j(false, "error", "WhatsApp step failed (" + e.javaClass.simpleName + ").") }
                finally { ScreenGuard.exit() }
                answer(out)
            }
        } catch (e: Throwable) { answer(j(false, "busy", "Phone control is busy. Try again in a moment.")) }
    }

    private fun a11yOnInSettings(): Boolean {
        val on = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return on.contains(ctx.packageName + "/")
    }

    /** Copies a file into public storage so it shows in Gallery / Files. Returns where it went, or "error: ...". */
    private fun saveMedia(path: String, name: String, mime: String, folder: String = ""): String {
        val src = File(path)
        if (!src.exists()) return "error: file not found"
        val dir: String
        val kind: String
        when {
            folder == "documents" -> { dir = android.os.Environment.DIRECTORY_DOCUMENTS; kind = "document" }
            folder == "downloads" -> { dir = android.os.Environment.DIRECTORY_DOWNLOADS; kind = "file" }
            mime.startsWith("image/") -> { dir = android.os.Environment.DIRECTORY_PICTURES; kind = "image" }
            mime.startsWith("video/") -> { dir = android.os.Environment.DIRECTORY_MOVIES; kind = "video" }
            mime.startsWith("audio/") -> { dir = android.os.Environment.DIRECTORY_MUSIC; kind = "audio" }
            else -> { dir = android.os.Environment.DIRECTORY_DOWNLOADS; kind = "file" }
        }
        if (Build.VERSION.SDK_INT >= 29) {
            val vol = android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY
            val collection = when (kind) {
                "image" -> android.provider.MediaStore.Images.Media.getContentUri(vol)
                "video" -> android.provider.MediaStore.Video.Media.getContentUri(vol)
                "audio" -> android.provider.MediaStore.Audio.Media.getContentUri(vol)
                "document" -> android.provider.MediaStore.Files.getContentUri(vol)
                else -> android.provider.MediaStore.Downloads.getContentUri(vol)
            }
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mime)
                put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, "$dir/Telesia")
                put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = ctx.contentResolver
            val uri = resolver.insert(collection, values) ?: return "error: could not create the file"
            resolver.openOutputStream(uri)?.use { out -> src.inputStream().use { it.copyTo(out) } }
            values.clear()
            values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "$dir/Telesia/$name"
        }
        @Suppress("DEPRECATION")
        val outDir = File(android.os.Environment.getExternalStoragePublicDirectory(dir), "Telesia")
        outDir.mkdirs()
        val out = File(outDir, name)
        src.copyTo(out, overwrite = true)
        android.media.MediaScannerConnection.scanFile(ctx, arrayOf(out.absolutePath), arrayOf(mime), null)
        return "$dir/Telesia/$name"
    }

    fun openPermission(name: String) {
        val i = when (name) {
            "overlay" -> Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + ctx.packageName))
            "accessibility" -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            "notifRead" -> Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
            "battery" -> Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.packageName))
            "notifications" -> if (Build.VERSION.SDK_INT >= 26)
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName)
            else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName))
            else -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName))
        }
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(i)
        } catch (e: Exception) {
            val f = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName))
            f.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ctx.startActivity(f)
        }
    }

    private fun unzip(zip: File, dest: File) {
        dest.mkdirs()
        val root = dest.canonicalPath
        ZipInputStream(zip.inputStream().buffered()).use { zin ->
            while (true) {
                val e = zin.nextEntry ?: break
                val out = File(dest, e.name)
                if (!out.canonicalPath.startsWith(root)) continue
                if (e.isDirectory) {
                    out.mkdirs()
                } else {
                    out.parentFile?.mkdirs()
                    out.outputStream().use { zin.copyTo(it) }
                }
            }
        }
    }
}
