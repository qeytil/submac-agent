package com.submac.agent

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.content.Context
import android.os.Bundle
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * SubMac native bridge (copied over the generated MainActivity by CI):
 * - phone actions through Android intents (the user taps to finish)
 * - receiving "Share to SubMac" text and files from other apps
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: HashMap<String, Any?>? = null

    // One long-lived engine (owned by SubMacApp) so Live, the wake word and background tasks
    // keep running when this screen closes.
    override fun provideFlutterEngine(context: Context): FlutterEngine = SubMacApp.engine(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before the engine attaches: the window asks for the fastest refresh rate from the very first frame (v1.13.101).
        highRefresh()
        super.onCreate(savedInstanceState)
        // After FlutterActivity's onCreate, which sets its own status-bar scrim (25% black) and no navigation-bar layout.
        edgeToEdge()
        Bridge.activity = java.lang.ref.WeakReference(this)
        Bridge.handleLaunchIntent(intent)
    }

    /**
     * Ask for the screen's fastest mode (90/120/144 Hz) at the current resolution, so animations stay fluid.
     * Asked again on every resume and focus: some phones (Samsung, Xiaomi, OnePlus) drop an app back to 60 Hz after
     * it was in the background, a dialog or the split screen, and the old code asked only once in onCreate.
     */
    private fun highRefresh() {
        try {
            if (android.os.Build.VERSION.SDK_INT < 23) return
            @Suppress("DEPRECATION")
            val d = (if (android.os.Build.VERSION.SDK_INT >= 30) display else null) ?: windowManager.defaultDisplay ?: return
            val cur = d.mode
            val best = d.supportedModes
                .filter { it.physicalWidth == cur.physicalWidth && it.physicalHeight == cur.physicalHeight }
                .maxByOrNull { it.refreshRate } ?: return
            val lp = window.attributes
            if (lp.preferredDisplayModeId == best.modeId && lp.preferredRefreshRate == best.refreshRate) return
            lp.preferredDisplayModeId = best.modeId
            lp.preferredRefreshRate = best.refreshRate
            window.attributes = lp
        } catch (_: Throwable) {}
    }

    /**
     * Edge to edge, every time the screen comes back (owner 2026-10-24: "the sky bg is short"). The engine is one
     * long-lived engine (SubMacApp), so Dart's main() and its SystemChrome.setEnabledSystemUIMode(edgeToEdge) run
     * once, and only reach the first screen it is attached to. Every later screen (after Back, a recreate or a start
     * from a background service) got a fresh PlatformPlugin whose default flags lay out under the status bar but NOT
     * under the navigation bar, so the sky stopped above the navigation bar. Same calls as Flutter's own edgeToEdge mode.
     */
    private fun edgeToEdge() {
        try {
            val w = window
            // The light/dark icon bits Flutter set for the look are kept (never cleared here).
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                w.setDecorFitsSystemWindows(false)
            } else {
                @Suppress("DEPRECATION")
                w.decorView.systemUiVisibility = w.decorView.systemUiVisibility or
                    android.view.View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                    android.view.View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    android.view.View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            }
            w.addFlags(android.view.WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                w.isNavigationBarContrastEnforced = false
                w.isStatusBarContrastEnforced = false
            }
            @Suppress("DEPRECATION")
            w.statusBarColor = android.graphics.Color.TRANSPARENT
            @Suppress("DEPRECATION")
            w.navigationBarColor = android.graphics.Color.TRANSPARENT
            if (android.os.Build.VERSION.SDK_INT >= 28) {
                val lp = w.attributes
                lp.layoutInDisplayCutoutMode = if (android.os.Build.VERSION.SDK_INT >= 30)
                    android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                else android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                w.attributes = lp
            }
        } catch (_: Throwable) {}
    }

    override fun onResume() {
        super.onResume()
        Bridge.activity = java.lang.ref.WeakReference(this)
        Bridge.foreground = true
        highRefresh()
    }

    // After FlutterActivity's own onPostResume, which re-applies the PlatformPlugin's (non edge-to-edge) defaults.
    override fun onPostResume() {
        super.onPostResume()
        edgeToEdge()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) highRefresh()
    }

    override fun onPause() {
        super.onPause()
        Bridge.foreground = false
    }

    override fun onDestroy() {
        if (Bridge.activity?.get() === this) Bridge.activity = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "submac/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // opencode on the phone (test screen, 2026-11-02).
                    "ocStart" -> {
                        val base = call.argument<String>("baseUrl") ?: ""
                        val token = call.argument<String>("token") ?: ""
                        val pass = call.argument<String>("password") ?: ""
                        val want = num(call.argument<Any>("port"), 4096).toInt()
                        val cwd = call.argument<String>("cwd")
                        val skills = (call.argument<Map<String, Any?>>("skills") ?: emptyMap())
                            .mapNotNull { (k, v) -> (v as? String)?.let { k to it } }.toMap()
                        val main = android.os.Handler(mainLooper)
                        Thread {
                            try {
                                val port = OpenCode.start(applicationContext, base, token, pass, want, cwd, skills)
                                val health = OpenCode.waitHealthy(60000)
                                main.post {
                                    result.success(mapOf("ok" to (health != null), "port" to port, "health" to health, "log" to OpenCode.lastLog()))
                                }
                            } catch (e: Throwable) {
                                main.post { result.success(mapOf("ok" to false, "error" to e.toString(), "log" to OpenCode.lastLog())) }
                            }
                        }.start()
                    }
                    "ocToken" -> {
                        call.argument<String>("baseUrl")?.let { if (it.isNotEmpty()) LocalProxy.upstream = it }
                        call.argument<String>("token")?.let { if (it.isNotEmpty()) LocalProxy.token = it }
                        result.success(true)
                    }
                    "ocStop" -> {
                        OpenCode.stop()
                        result.success(true)
                    }
                    "ocStatus" -> result.success(mapOf("installed" to OpenCode.installed(applicationContext), "running" to OpenCode.running(),
                        "port" to OpenCode.port, "log" to OpenCode.lastLog()))
                    "takeShared" -> {
                        val p = pending
                        pending = null
                        result.success(p)
                    }
                    "setAlarm" -> {
                        val i = Intent(AlarmClock.ACTION_SET_ALARM)
                        i.putExtra(AlarmClock.EXTRA_HOUR, num(call.argument<Any>("hour"), 7).toInt())
                        i.putExtra(AlarmClock.EXTRA_MINUTES, num(call.argument<Any>("minute"), 0).toInt())
                        val label = call.argument<String>("label")
                        if (!label.isNullOrEmpty()) i.putExtra(AlarmClock.EXTRA_MESSAGE, label)
                        val days = call.argument<List<Int>>("days")
                        if (!days.isNullOrEmpty()) i.putExtra(AlarmClock.EXTRA_DAYS, ArrayList(days))
                        i.putExtra(AlarmClock.EXTRA_SKIP_UI, call.argument<Boolean>("skipUi") ?: true)
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                        result.success(true)
                    }
                    "setTimer" -> {
                        val i = Intent(AlarmClock.ACTION_SET_TIMER)
                        i.putExtra(AlarmClock.EXTRA_LENGTH, num(call.argument<Any>("seconds"), 60).toInt())
                        val label = call.argument<String>("label")
                        if (!label.isNullOrEmpty()) i.putExtra(AlarmClock.EXTRA_MESSAGE, label)
                        i.putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                        result.success(true)
                    }
                    "addEvent" -> {
                        val i = Intent(Intent.ACTION_INSERT)
                        i.data = CalendarContract.Events.CONTENT_URI
                        i.putExtra(CalendarContract.Events.TITLE, call.argument<String>("title") ?: "")
                        i.putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, num(call.argument<Any>("begin"), 0).toLong())
                        i.putExtra(CalendarContract.EXTRA_EVENT_END_TIME, num(call.argument<Any>("end"), 0).toLong())
                        i.putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, call.argument<Boolean>("allDay") ?: false)
                        val loc = call.argument<String>("location")
                        if (!loc.isNullOrEmpty()) i.putExtra(CalendarContract.Events.EVENT_LOCATION, loc)
                        val desc = call.argument<String>("description")
                        if (!desc.isNullOrEmpty()) i.putExtra(CalendarContract.Events.DESCRIPTION, desc)
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                        result.success(true)
                    }
                    "openApp" -> {
                        val name = (call.argument<String>("name") ?: "").trim().lowercase()
                        val pm = packageManager
                        var launch: Intent? = null
                        var label: String? = null
                        if (name.contains('.')) {
                            launch = pm.getLaunchIntentForPackage(name)
                            label = name
                        }
                        if (launch == null) {
                            val q = Intent(Intent.ACTION_MAIN)
                            q.addCategory(Intent.CATEGORY_LAUNCHER)
                            @Suppress("DEPRECATION")
                            val apps = pm.queryIntentActivities(q, 0)
                            var best: android.content.pm.ResolveInfo? = null
                            for (a in apps) {
                                val l = a.loadLabel(pm).toString().lowercase()
                                if (l == name) { best = a; break }
                                if (best == null && (l.contains(name) || name.contains(l))) best = a
                            }
                            if (best != null) {
                                launch = pm.getLaunchIntentForPackage(best.activityInfo.packageName)
                                label = best.loadLabel(pm).toString()
                            }
                        }
                        if (launch == null) {
                            result.success(null)
                        } else {
                            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(launch)
                            result.success(label)
                        }
                    }
                    "pdfInfo" -> {
                        val path = call.argument<String>("path") ?: ""
                        val fd = android.os.ParcelFileDescriptor.open(File(path), android.os.ParcelFileDescriptor.MODE_READ_ONLY)
                        val r = android.graphics.pdf.PdfRenderer(fd)
                        val n = r.pageCount
                        r.close()
                        fd.close()
                        result.success(n)
                    }
                    "pdfPage" -> {
                        val path = call.argument<String>("path") ?: ""
                        val index = call.argument<Int>("page") ?: 0
                        val width = call.argument<Int>("width") ?: 1080
                        val fd = android.os.ParcelFileDescriptor.open(File(path), android.os.ParcelFileDescriptor.MODE_READ_ONLY)
                        val r = android.graphics.pdf.PdfRenderer(fd)
                        val page = r.openPage(index.coerceIn(0, r.pageCount - 1))
                        val h = (width.toDouble() * page.height / page.width).toInt().coerceAtLeast(1)
                        val bmp = android.graphics.Bitmap.createBitmap(width, h, android.graphics.Bitmap.Config.ARGB_8888)
                        bmp.eraseColor(android.graphics.Color.WHITE)
                        page.render(bmp, null, null, android.graphics.pdf.PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        page.close()
                        r.close()
                        fd.close()
                        val out = java.io.ByteArrayOutputStream()
                        bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)
                        bmp.recycle()
                        result.success(out.toByteArray())
                    }
                    "listApps" -> {
                        val q = Intent(Intent.ACTION_MAIN)
                        q.addCategory(Intent.CATEGORY_LAUNCHER)
                        @Suppress("DEPRECATION")
                        val apps = packageManager.queryIntentActivities(q, 0)
                        val names = ArrayList<String>()
                        for (a in apps) names.add(a.loadLabel(packageManager).toString())
                        result.success(names)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: ActivityNotFoundException) {
                result.error("no_app", "No app on this phone can do that.", null)
            } catch (e: Exception) {
                result.error("failed", e.message ?: e.toString(), null)
            }
        }
        handleShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        Bridge.handleLaunchIntent(intent)
        if (handleShare(intent)) channel?.invokeMethod("shared", null)
    }

    private fun num(v: Any?, fallback: Long): Long = when (v) {
        is Int -> v.toLong()
        is Long -> v
        is Double -> v.toLong()
        is String -> v.toLongOrNull() ?: fallback
        else -> fallback
    }

    private fun handleShare(i: Intent?): Boolean {
        if (i == null) return false
        val action = i.action ?: return false
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return false
        val uris = ArrayList<Uri>()
        if (action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION")
            val u = i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (u != null) uris.add(u)
        } else {
            @Suppress("DEPRECATION")
            val list = i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            if (list != null) uris.addAll(list)
        }
        val dir = File(cacheDir, "shared")
        dir.mkdirs()
        val files = ArrayList<String>()
        for (u in uris) {
            val path = copyUri(u, dir)
            if (path != null) files.add(path)
        }
        val map = HashMap<String, Any?>()
        map["text"] = i.getStringExtra(Intent.EXTRA_TEXT) ?: ""
        map["subject"] = i.getStringExtra(Intent.EXTRA_SUBJECT) ?: ""
        map["files"] = files
        pending = map
        i.action = null
        return true
    }

    private fun copyUri(u: Uri, dir: File): String? {
        return try {
            var name = "shared_" + System.currentTimeMillis()
            contentResolver.query(u, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) {
                    val n = c.getString(idx)
                    if (!n.isNullOrEmpty()) name = n
                }
            }
            val out = File(dir, name.replace('/', '_'))
            contentResolver.openInputStream(u)?.use { input ->
                out.outputStream().use { output -> input.copyTo(output) }
            }
            out.absolutePath
        } catch (e: Exception) {
            null
        }
    }
}
