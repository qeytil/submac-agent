package com.telesia.app

import android.app.Activity
import android.app.Application
import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.security.MessageDigest

/**
 * "telesia/update": in-app updates. New releases are ONE file in Cloudflare R2; older ones are stored in parts (Supabase
 * kept files under 50 MB). Every address is handed to Android's DownloadManager at once: it keeps downloading after the
 * user leaves the app, shows its own notification and survives the app being closed. A single file is checked
 * (sha256) and renamed in place; parts are joined into one file whose sha256 must match the release. Only then can
 * Install open Android's installer (through [UpdateFiles]).
 * State lives in SharedPreferences "telesia_update", so a restart picks up where it was.
 */
object AppUpdater {
    private const val PREFS = "telesia_update"
    private const val DIR = "updates"
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()

    private var channel: MethodChannel? = null
    private var watching = false

    fun attach(c: Context, engine: FlutterEngine) {
        val ctx = c.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "telesia/update")
        channel = ch
        watchScreen(ctx)
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> result.success(info(ctx))
                    "start" -> {
                        @Suppress("UNCHECKED_CAST")
                        val urls = (call.argument<List<Any?>>("urls") ?: emptyList()).map { it.toString() }
                        val code = (call.argument<Any?>("code") as? Number)?.toLong() ?: 0L
                        val sha = call.argument<String>("sha256") ?: ""
                        val size = (call.argument<Any?>("size") as? Number)?.toLong() ?: 0L
                        val title = call.argument<String>("title") ?: "Telesia update"
                        result.success(start(ctx, code, urls, sha, size, title))
                    }
                    "status" -> Thread {
                        val r = try { status(ctx) } catch (e: Exception) { mapOf("state" to "failed", "reason" to (e.message ?: "error")) }
                        main.post { result.success(r) }
                    }.start()
                    "cancel" -> { cancel(ctx); result.success(true) }
                    "install" -> Thread {
                        val r = try { install(ctx) } catch (e: Exception) { "error: " + (e.message ?: "could not open the installer") }
                        main.post { result.success(r) }
                    }.start()
                    "openInstallSettings" -> { openInstallSettings(ctx); result.success(true) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("failed", e.message ?: e.toString(), null)
            }
        }
    }

    /**
     * The engine outlives the screen, so "close Telesia and open it again" may not restart Dart. Tell Dart each time
     * the Telesia screen is freshly opened, so a pending update window shows again (owner: every start).
     */
    private fun watchScreen(ctx: Context) {
        if (watching) return
        val app = ctx as? Application ?: return
        watching = true
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(a: Activity, saved: Bundle?) {
                if (a is MainActivity && saved == null) main.post { try { channel?.invokeMethod("opened", null) } catch (_: Exception) {} }
            }
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityResumed(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, out: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        })
    }

    private fun prefs(ctx: Context): SharedPreferences = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun dir(ctx: Context): File = File(ctx.getExternalFilesDir(null) ?: ctx.filesDir, DIR)
    fun finalFile(ctx: Context, code: Long): File = File(dir(ctx), "telesia-update-$code.apk")
    private fun dm(ctx: Context) = ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private fun ids(ctx: Context): LongArray =
        (prefs(ctx).getString("ids", "") ?: "").split(',').mapNotNull { it.trim().toLongOrNull() }.toLongArray()

    @Suppress("DEPRECATION")
    private fun info(ctx: Context): Map<String, Any?> {
        val pi = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode else pi.versionCode.toLong()
        return mapOf(
            "code" to code,
            "name" to (pi.versionName ?: ""),
            "canInstall" to canInstall(ctx),
            "sdk" to Build.VERSION.SDK_INT,
            // Sent with in-app feedback (lib/services/feedback.dart).
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "release" to Build.VERSION.RELEASE,
        )
    }

    private fun canInstall(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 26 || ctx.packageManager.canRequestPackageInstalls()

    /** Starts (or restarts) the download of every part. Old files and downloads are removed first. */
    private fun start(ctx: Context, code: Long, urls: List<String>, sha: String, size: Long, title: String): List<Long> {
        if (code <= 0 || urls.isEmpty() || !Regex("^[0-9a-f]{64}$").matches(sha)) throw IllegalArgumentException("bad release")
        for (u in urls) if (!u.startsWith("https://")) throw IllegalArgumentException("bad address")
        cancel(ctx)
        val d = dir(ctx)
        d.mkdirs()
        val out = ArrayList<Long>()
        for ((i, u) in urls.withIndex()) {
            val req = DownloadManager.Request(Uri.parse(u))
                .setTitle(if (urls.size > 1) "$title (${i + 1}/${urls.size})" else title)
                .setDescription("Downloading the new version of Telesia")
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(true)
                .setMimeType("application/octet-stream")
                .setDestinationInExternalFilesDir(ctx, DIR, "part-$code-$i.bin")
            out.add(dm(ctx).enqueue(req))
        }
        prefs(ctx).edit()
            .putString("ids", out.joinToString(","))
            .putLong("code", code)
            .putString("sha", sha)
            .putLong("size", size)
            .putInt("parts", urls.size)
            .putBoolean("ready", false)
            .putBoolean("notified", false)
            .apply()
        return out
    }

    private fun partFile(ctx: Context, code: Long, i: Int) = File(dir(ctx), "part-$code-$i.bin")

    /**
     * none | running | paused | failed | bad (joined file did not match) | ready. Joins the parts when all are done.
     * Called from Dart and from [UpdateDone]; never on the main thread.
     */
    fun status(ctx: Context): Map<String, Any?> = synchronized(lock) { statusLocked(ctx) }

    private fun statusLocked(ctx: Context): Map<String, Any?> {
        val p = prefs(ctx)
        val code = p.getLong("code", 0L)
        if (code <= 0L) return mapOf("state" to "none")
        val f = finalFile(ctx, code)
        if (p.getBoolean("ready", false) && f.isFile) {
            return mapOf("state" to "ready", "code" to code, "path" to f.absolutePath, "bytes" to f.length(), "total" to f.length())
        }
        val ids = ids(ctx)
        if (ids.isEmpty()) return mapOf("state" to "none", "code" to code)
        var bytes = 0L
        var total = 0L
        var done = 0
        var failed = false
        var paused = false
        var reason = 0
        val local = HashMap<Long, File>()
        val q = DownloadManager.Query().setFilterById(*ids)
        var seen = 0
        dm(ctx).query(q)?.use { c ->
            val iSt = c.getColumnIndex(DownloadManager.COLUMN_STATUS)
            val iSo = c.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
            val iTo = c.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
            val iRe = c.getColumnIndex(DownloadManager.COLUMN_REASON)
            val iId = c.getColumnIndex(DownloadManager.COLUMN_ID)
            val iUri = c.getColumnIndex(DownloadManager.COLUMN_LOCAL_URI)
            while (c.moveToNext()) {
                seen++
                val u = if (iUri >= 0) c.getString(iUri) else null
                if (iId >= 0 && u != null && u.startsWith("file:")) Uri.parse(u).path?.let { local[c.getLong(iId)] = File(it) }
                val st = c.getInt(iSt)
                bytes += maxOf(0L, c.getLong(iSo))
                total += maxOf(0L, c.getLong(iTo))
                when (st) {
                    DownloadManager.STATUS_SUCCESSFUL -> done++
                    DownloadManager.STATUS_FAILED -> { failed = true; reason = c.getInt(iRe) }
                    DownloadManager.STATUS_PAUSED -> { paused = true; reason = c.getInt(iRe) }
                }
            }
        }
        val want = p.getLong("size", 0L)
        if (want > 0) total = want
        // A download the user removed from the system's Downloads list counts as stopped.
        if (seen < ids.size) failed = true
        if (failed) return mapOf("state" to "failed", "code" to code, "bytes" to bytes, "total" to total, "reason" to reason)
        if (done < ids.size) return mapOf("state" to if (paused) "paused" else "running", "code" to code, "bytes" to bytes, "total" to total, "reason" to reason)
        // Every part is in: join them in order and check the whole file.
        val parts = p.getInt("parts", ids.size)
        val sha = p.getString("sha", "") ?: ""
        val tmp = File(dir(ctx), "joining-$code.tmp")
        if (parts == 1) {
            // One file (Cloudflare R2): check it where it landed and rename it; no copy needed.
            val pf = ids.getOrNull(0)?.let { local[it] }?.takeIf { it.isFile } ?: partFile(ctx, code, 0)
            if (!pf.isFile) return mapOf("state" to "failed", "code" to code, "reason" to -1)
            val got1 = sha256(pf)
            if (got1 != sha) {
                pf.delete()
                try { dm(ctx).remove(*ids) } catch (_: Exception) {}
                p.edit().putString("ids", "").putLong("code", 0L).putBoolean("ready", false).apply()
                return mapOf("state" to "bad", "code" to code)
            }
            if (f.exists()) f.delete()
            if (!pf.renameTo(f)) {
                // Another folder or file system: fall back to a copy.
                pf.copyTo(f, overwrite = true)
                pf.delete()
            }
            // Only now forget the download: DownloadManager.remove deletes a finished file still at its old path.
            try { dm(ctx).remove(*ids) } catch (_: Exception) {}
            p.edit().putString("ids", "").apply()
            p.edit().putBoolean("ready", true).apply()
            return mapOf("state" to "ready", "code" to code, "path" to f.absolutePath, "bytes" to f.length(), "total" to f.length())
        }
        val md = MessageDigest.getInstance("SHA-256")
        tmp.outputStream().use { out ->
            val buf = ByteArray(256 * 1024)
            for (i in 0 until parts) {
                // DownloadManager may pick another name if one was taken; it reports where it really wrote.
                val pf = ids.getOrNull(i)?.let { local[it] }?.takeIf { it.isFile } ?: partFile(ctx, code, i)
                if (!pf.isFile) { tmp.delete(); return mapOf("state" to "failed", "code" to code, "reason" to -1) }
                pf.inputStream().use { inp ->
                    while (true) {
                        val n = inp.read(buf)
                        if (n < 0) break
                        md.update(buf, 0, n)
                        out.write(buf, 0, n)
                    }
                }
            }
        }
        val got = md.digest().joinToString("") { "%02x".format(it) }
        for (i in 0 until parts) partFile(ctx, code, i).delete()
        for (lf in local.values) if (lf.canonicalPath.startsWith(dir(ctx).canonicalPath + File.separator)) lf.delete()
        try { dm(ctx).remove(*ids) } catch (_: Exception) {}
        p.edit().putString("ids", "").apply()
        if (got != sha) {
            tmp.delete()
            p.edit().putLong("code", 0L).putBoolean("ready", false).apply()
            return mapOf("state" to "bad", "code" to code)
        }
        if (f.exists()) f.delete()
        tmp.renameTo(f)
        p.edit().putBoolean("ready", true).apply()
        return mapOf("state" to "ready", "code" to code, "path" to f.absolutePath, "bytes" to f.length(), "total" to f.length())
    }

    /** Stops the download and removes every update file (also used once the app is up to date). */
    fun cancel(ctx: Context) = synchronized(lock) {
        val ids = ids(ctx)
        if (ids.isNotEmpty()) try { dm(ctx).remove(*ids) } catch (_: Exception) {}
        dir(ctx).listFiles()?.forEach { it.delete() }
        prefs(ctx).edit().clear().apply()
    }

    private fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { inp ->
            val buf = ByteArray(256 * 1024)
            while (true) {
                val n = inp.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /** "started" | "needs_permission" | "not_ready" | "bad". Checks the file again right before opening the installer. */
    private fun install(ctx: Context): String {
        val p = prefs(ctx)
        val code = p.getLong("code", 0L)
        val f = finalFile(ctx, code)
        if (code <= 0L || !p.getBoolean("ready", false) || !f.isFile) return "not_ready"
        if (sha256(f) != (p.getString("sha", "") ?: "")) {
            cancel(ctx)
            return "bad"
        }
        if (!canInstall(ctx)) return "needs_permission"
        val uri = Uri.parse("content://" + UpdateFiles.authority(ctx) + "/" + f.name)
        val i = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        val act = Bridge.activity?.get()
        main.post { if (act != null) act.startActivity(i) else ctx.startActivity(i) }
        return "started"
    }

    private fun openInstallSettings(ctx: Context) {
        val i = if (Build.VERSION.SDK_INT >= 26)
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + ctx.packageName))
        else Intent(Settings.ACTION_SECURITY_SETTINGS)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val act = Bridge.activity?.get()
        try { if (act != null) act.startActivity(i) else ctx.startActivity(i) } catch (_: Exception) {
            ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    /** From [UpdateDone]: when the last part lands, join it and tell the user it is ready (once). */
    fun onDownloadDone(ctx: Context, id: Long) {
        if (id !in ids(ctx)) return
        val s = status(ctx)
        val p = prefs(ctx)
        if (s["state"] == "ready" && !p.getBoolean("notified", false)) {
            p.edit().putBoolean("notified", true).apply()
            Notifier.task(ctx, 7401, "Your Telesia update is ready. Tap to install.", "", "update", "info")
        }
    }
}

/** DownloadManager tells the app a part finished, even when Telesia is closed. */
class UpdateDone : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
        if (id < 0) return
        val pr = goAsync()
        Thread {
            try { AppUpdater.onDownloadDone(context.applicationContext, id) } catch (_: Exception) {} finally { pr.finish() }
        }.start()
    }
}

/**
 * Read-only access to the joined update file for Android's installer (files/updates only). Not exported: the
 * installer gets a one-time read grant from the install intent. Same idea as androidx FileProvider, without the
 * extra dependency.
 */
class UpdateFiles : ContentProvider() {
    companion object {
        fun authority(ctx: Context) = ctx.packageName + ".updates"
    }

    private fun fileFor(uri: Uri): File {
        val name = uri.lastPathSegment ?: throw FileNotFoundException()
        val ctx = context ?: throw FileNotFoundException()
        val dir = File(ctx.getExternalFilesDir(null) ?: ctx.filesDir, "updates")
        val f = File(dir, name)
        if (!name.endsWith(".apk") || !f.canonicalPath.startsWith(dir.canonicalPath + File.separator) || !f.isFile) throw FileNotFoundException()
        return f
    }

    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): android.os.ParcelFileDescriptor =
        android.os.ParcelFileDescriptor.open(fileFor(uri), android.os.ParcelFileDescriptor.MODE_READ_ONLY)

    override fun getType(uri: Uri): String = "application/vnd.android.package-archive"

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val f = fileFor(uri)
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val c = MatrixCursor(cols)
        c.addRow(cols.map { if (it == OpenableColumns.SIZE) f.length() else if (it == OpenableColumns.DISPLAY_NAME) f.name else null }.toTypedArray())
        return c
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
