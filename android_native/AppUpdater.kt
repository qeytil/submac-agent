package com.submac.agent

import android.app.Activity
import android.app.Application
import android.app.DownloadManager
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.StatFs
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * "submac/update": in-app updates. A release is ONE file (Cloudflare R2) or several parts (Supabase storage keeps
 * files under 50 MB). The parts are fetched one by one by our own downloader inside [UpdateService] (a small
 * dataSync foreground service, so it keeps going when the user leaves SubMac):
 *  - every part is a file updates/part-<code>-<i>.bin; a finished part is kept, a partial part is continued with
 *    `Range: bytes=<have>-` (206 appends; a server that answers 200 instead restarts only that part);
 *  - a lost connection waits for the network and continues by itself; server errors are retried, then reported;
 *  - free space (about 2x the APK, parts + joined file) is checked before starting and before joining.
 * (Android's DownloadManager cannot do this: it refuses a 206 to a request it did not resume itself and deletes the
 * partial file when a download fails.)
 * When every part is in, they are joined and the sha256 must match the release. Before the installer opens, the file
 * is checked again and its signing certificate must match the installed app's ([verify], [install]).
 * State lives in SharedPreferences "submac_update", so a restart picks up where it was.
 */
object AppUpdater {
    private const val PREFS = "submac_update"
    private const val DIR = "updates"
    const val NOTE_ID = 7402
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()

    private var channel: MethodChannel? = null
    private var watching = false

    @Volatile private var worker: Thread? = null
    @Volatile private var stopFlag = false
    @Volatile private var liveBytes = -1L
    @Volatile private var startedAt = 0L
    @Volatile var onProgress: ((Long, Long, String) -> Unit)? = null

    fun attach(c: Context, engine: FlutterEngine) {
        val ctx = c.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "submac/update")
        channel = ch
        watchScreen(ctx)
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> result.success(info(ctx))
                    "files" -> {
                        val code = (call.argument<Any?>("code") as? Number)?.toLong() ?: 0L
                        val count = (call.argument<Any?>("count") as? Number)?.toInt() ?: 0
                        result.success(files(ctx, code, count))
                    }
                    "start" -> {
                        val urls = (call.argument<List<Any?>>("urls") ?: emptyList()).map { it.toString() }
                        val sizes = (call.argument<List<Any?>>("sizes") ?: emptyList()).map { (it as? Number)?.toLong() ?: 0L }
                        val code = (call.argument<Any?>("code") as? Number)?.toLong() ?: 0L
                        val sha = call.argument<String>("sha256") ?: ""
                        val size = (call.argument<Any?>("size") as? Number)?.toLong() ?: 0L
                        val title = call.argument<String>("title") ?: "SubMac"
                        val words = (call.argument<Map<String, Any?>>("words") ?: emptyMap()).mapValues { it.value?.toString() ?: "" }
                        result.success(start(ctx, code, urls, sizes, sha, size, title, words))
                    }
                    "status" -> Thread {
                        val r = try { status(ctx) } catch (e: Exception) { mapOf("state" to "failed", "reason" to "unknown") }
                        main.post { result.success(r) }
                    }.start()
                    "stop" -> { stop(ctx); result.success(true) }
                    "cancel" -> { cancel(ctx); result.success(true) }
                    "verify" -> Thread {
                        val r = try { verify(ctx) } catch (e: Exception) { mapOf("ready" to false) }
                        main.post { result.success(r) }
                    }.start()
                    "install" -> Thread {
                        val r = try { install(ctx) } catch (e: Exception) { "not_ready" }
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
     * The engine outlives the screen, so "close SubMac and open it again" may not restart Dart. Tell Dart each time
     * the SubMac screen is freshly opened, so a pending update window can show again (unless that version is snoozed).
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
    fun finalFile(ctx: Context, code: Long): File = File(dir(ctx), "submac-update-$code.apk")
    private fun partFile(ctx: Context, code: Long, i: Int) = File(dir(ctx), "part-$code-$i.bin")
    private fun longs(s: String?): List<Long> = (s ?: "").split(',').mapNotNull { it.trim().toLongOrNull() }
    private fun doneSet(p: SharedPreferences): MutableSet<Int> =
        (p.getString("done", "") ?: "").split(',').mapNotNull { it.trim().toIntOrNull() }.toMutableSet()
    fun word(ctx: Context, key: String, fallback: String): String =
        prefs(ctx).getString("w_$key", null)?.takeIf { it.isNotBlank() } ?: fallback

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

    private fun freeBytes(ctx: Context): Long = try {
        val d = dir(ctx); d.mkdirs(); StatFs(d.absolutePath).availableBytes
    } catch (_: Exception) { -1L }

    /** What is already on the phone for release [code]: bytes of each part, which parts are finished, free space. */
    private fun files(ctx: Context, code: Long, count: Int): Map<String, Any?> {
        val p = prefs(ctx)
        val same = p.getLong("code", 0L) == code
        val done = if (same) doneSet(p) else mutableSetOf()
        val have = (0 until count).map { i -> partFile(ctx, code, i).let { if (it.isFile) it.length() else 0L } }
        return mapOf("have" to have, "done" to (0 until count).map { done.contains(it) }, "free" to freeBytes(ctx))
    }

    /**
     * Starts (or continues) the download. Files of another release are removed; parts of this one are kept.
     * Returns "started" | "running" | "no_space".
     */
    private fun start(ctx: Context, code: Long, urls: List<String>, sizes: List<Long>, sha: String, size: Long, title: String, words: Map<String, String>): String {
        if (code <= 0 || urls.isEmpty() || !Regex("^[0-9a-f]{64}$").matches(sha)) throw IllegalArgumentException("bad release")
        for (u in urls) if (!u.startsWith("https://")) throw IllegalArgumentException("bad address")
        val p = prefs(ctx)
        if (worker?.isAlive == true && p.getLong("code", 0L) == code && !stopFlag) return "running"
        val sameRelease = p.getLong("code", 0L) == code && p.getString("sha", "") == sha
        // Let a stopping (or another release's) download end first; it writes its state on the way out.
        if (worker?.isAlive == true) { stopFlag = true; try { worker?.join(5000) } catch (_: Exception) {} }
        synchronized(lock) {
            legacyCleanup(ctx)
            if (!sameRelease) {
                dir(ctx).listFiles()?.forEach { it.delete() }
                p.edit().clear().apply()
            }
            val d = dir(ctx)
            d.mkdirs()
            val have = urls.indices.sumOf { i -> partFile(ctx, code, i).let { if (it.isFile) it.length() else 0L } }
            val free = freeBytes(ctx)
            if (free >= 0 && free < 2 * size - have) {
                p.edit().putLong("code", code).putString("state", "failed").putString("reason", "storage").apply()
                return "no_space"
            }
            val e = p.edit()
                .putLong("code", code)
                .putString("urls", urls.joinToString("\n"))
                .putString("sizes", sizes.joinToString(","))
                .putString("sha", sha)
                .putLong("size", size)
                .putInt("parts", urls.size)
                .putString("title", title)
                .putBoolean("ready", false)
                .putBoolean("notified", false)
                .putString("state", "running")
                .putString("reason", "")
                .putInt("http", 0)
            if (!sameRelease) e.putString("done", "")
            for ((k, v) in words) e.putString("w_$k", v)
            e.apply()
            stopFlag = false
            startedAt = System.currentTimeMillis()
        }
        UpdateService.begin(ctx)
        return "started"
    }

    /** Runs the download on a background thread (from [UpdateService]); [onEnd] when it stops for any reason. */
    fun runWorker(ctx: Context, onEnd: () -> Unit) {
        synchronized(lock) {
            if (worker?.isAlive == true) return
            stopFlag = false
            worker = Thread {
                try { work(ctx) } catch (e: Exception) { setState(ctx, "failed", "unknown") } finally {
                    worker = null
                    liveBytes = -1L
                    main.post(onEnd)
                }
            }.also { it.start() }
        }
    }

    private fun setState(ctx: Context, state: String, reason: String = "", http: Int = 0) {
        prefs(ctx).edit().putString("state", state).putString("reason", reason).putInt("http", http).apply()
    }

    private sealed class Got {
        object Ok : Got()
        object Network : Got()
        object Storage : Got()
        object Stopped : Got()
        object Again : Got()
        class Server(val http: Int) : Got()
    }

    private fun online(ctx: Context): Boolean = try {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val n = cm.activeNetwork
        val caps = if (n != null) cm.getNetworkCapabilities(n) else null
        caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    } catch (_: Exception) { true }

    private fun work(ctx: Context) {
        val p = prefs(ctx)
        val code = p.getLong("code", 0L)
        val urls = (p.getString("urls", "") ?: "").split('\n').filter { it.isNotBlank() }
        val sizes = longs(p.getString("sizes", ""))
        val total = p.getLong("size", 0L)
        if (code <= 0 || urls.isEmpty()) { setState(ctx, "none"); return }
        setState(ctx, "running")
        for ((i, url) in urls.withIndex()) {
            val want = sizes.getOrElse(i) { 0L }
            val f = partFile(ctx, code, i)
            if (doneSet(p).contains(i) || (want > 0 && f.isFile && f.length() == want)) continue
            var serverTries = 0
            var waitedSince = 0L
            while (true) {
                if (stopFlag) { setState(ctx, "stopped"); return }
                when (val g = fetchPart(ctx, code, url, f, want, i, urls.size, total)) {
                    is Got.Ok -> {
                        val d = doneSet(p); d.add(i)
                        p.edit().putString("done", d.joinToString(",")).apply()
                        break
                    }
                    is Got.Again -> continue
                    is Got.Stopped -> { setState(ctx, "stopped"); return }
                    is Got.Storage -> { setState(ctx, "failed", "storage"); return }
                    is Got.Server -> {
                        serverTries++
                        if (serverTries >= 3) { setState(ctx, "failed", "server", g.http); return }
                        sleepUnlessStopped(2000L * serverTries)
                    }
                    is Got.Network -> {
                        // Lost connection: wait for the network and continue from the bytes we have (Range).
                        setState(ctx, "paused", "network")
                        if (waitedSince == 0L) waitedSince = System.currentTimeMillis()
                        if (System.currentTimeMillis() - waitedSince > 6 * 3600_000L) { setState(ctx, "failed", "network"); return }
                        sleepUnlessStopped(3000L)
                        while (!stopFlag && !online(ctx)) sleepUnlessStopped(3000L)
                        if (!stopFlag) setState(ctx, "running")
                    }
                }
            }
        }
        // Every part is in: join them and check the whole file.
        setState(ctx, "verifying")
        val r = synchronized(lock) { finish(ctx) }
        if (r["state"] == "ready" && !p.getBoolean("notified", false)) {
            p.edit().putBoolean("notified", true).apply()
            Notifier.task(ctx, 7401, word(ctx, "ready", "Your SubMac update is ready. Tap to install."), word(ctx, "readyBody", ""), "update", "info")
        }
    }

    private fun sleepUnlessStopped(ms: Long) {
        var left = ms
        while (left > 0 && !stopFlag) { Thread.sleep(minOf(left, 250L)); left -= 250L }
    }

    /** One request for one part, continuing from what is on disk. */
    private fun fetchPart(ctx: Context, code: Long, url: String, f: File, want: Long, index: Int, count: Int, total: Long): Got {
        var have = if (f.isFile) f.length() else 0L
        if (want > 0 && have > want) { f.delete(); have = 0L }
        if (want > 0 && have == want) return Got.Ok
        var c: HttpURLConnection? = null
        try {
            c = URL(url).openConnection() as HttpURLConnection
            c.connectTimeout = 20_000
            c.readTimeout = 30_000
            c.instanceFollowRedirects = true
            c.setRequestProperty("Accept-Encoding", "identity")
            if (have > 0) c.setRequestProperty("Range", "bytes=$have-")
            val st = c.responseCode
            // Same rules as rangeOutcome() in lib/services/update_logic.dart.
            val append = when {
                st == 206 && have > 0 -> true
                st == 200 -> false // fresh, or the server ignored Range: this part starts over
                st == 416 && have > 0 -> return if (want <= 0 || have == want) Got.Ok else { f.delete(); Got.Again }
                else -> return Got.Server(st)
            }
            if (!append) have = 0L
            val before = (0 until count).filter { it != index }.sumOf { i -> partFile(ctx, code, i).let { if (it.isFile) it.length() else 0L } }
            c.inputStream.use { inp ->
                FileOutputStream(f, append).use { out ->
                    val buf = ByteArray(128 * 1024)
                    var last = 0L
                    var got = have
                    while (true) {
                        if (stopFlag) return Got.Stopped
                        val n = inp.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        got += n
                        val now = System.currentTimeMillis()
                        if (now - last > 500) {
                            last = now
                            liveBytes = before + got
                            onProgress?.invoke(before + got, total, "running")
                        }
                    }
                    out.flush()
                }
            }
            val len = f.length()
            if (want > 0 && len < want) return Got.Network // cut short: continue with Range
            if (want > 0 && len > want) { f.delete(); return Got.Server(st) }
            return Got.Ok
        } catch (e: IOException) {
            val m = (e.message ?: "").lowercase()
            if (m.contains("enospc") || m.contains("no space")) return Got.Storage
            return Got.Network
        } finally {
            try { c?.disconnect() } catch (_: Exception) {}
        }
    }

    /** Joins the parts (or renames the one file) and checks sha256. Under [lock]. */
    private fun finish(ctx: Context): Map<String, Any?> {
        val p = prefs(ctx)
        val code = p.getLong("code", 0L)
        val parts = p.getInt("parts", 0)
        val sha = p.getString("sha", "") ?: ""
        val f = finalFile(ctx, code)
        val tmp = File(dir(ctx), "joining-$code.tmp")
        if (parts == 1) {
            val pf = partFile(ctx, code, 0)
            if (!pf.isFile) { setState(ctx, "failed", "unknown"); return mapOf("state" to "failed") }
            if (sha256(pf) != sha) { pf.delete(); markBad(ctx); return mapOf("state" to "bad") }
            if (f.exists()) f.delete()
            if (!pf.renameTo(f)) { pf.copyTo(f, overwrite = true); pf.delete() }
        } else {
            val size = p.getLong("size", 0L)
            val free = freeBytes(ctx)
            if (free >= 0 && free < size) { setState(ctx, "failed", "storage"); return mapOf("state" to "failed") }
            val md = MessageDigest.getInstance("SHA-256")
            try {
                tmp.outputStream().use { out ->
                    val buf = ByteArray(256 * 1024)
                    for (i in 0 until parts) {
                        val pf = partFile(ctx, code, i)
                        if (!pf.isFile) { tmp.delete(); setState(ctx, "failed", "unknown"); return mapOf("state" to "failed") }
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
            } catch (e: IOException) {
                tmp.delete()
                setState(ctx, "failed", "storage")
                return mapOf("state" to "failed")
            }
            val got = md.digest().joinToString("") { "%02x".format(it) }
            for (i in 0 until parts) partFile(ctx, code, i).delete()
            if (got != sha) { tmp.delete(); markBad(ctx); return mapOf("state" to "bad") }
            if (f.exists()) f.delete()
            tmp.renameTo(f)
        }
        p.edit().putBoolean("ready", true).putString("state", "ready").putString("done", "").apply()
        return mapOf("state" to "ready")
    }

    private fun markBad(ctx: Context) {
        prefs(ctx).edit().putString("state", "bad").putBoolean("ready", false).putString("done", "").apply()
    }

    /**
     * none | running | paused | stopped | failed | verifying | bad | ready, with bytes/total and why it waits or
     * stopped (reason: network | storage | server | unknown; http). Never on the main thread.
     */
    fun status(ctx: Context): Map<String, Any?> {
        val p = prefs(ctx)
        val code = p.getLong("code", 0L)
        if (code <= 0L) return mapOf("state" to "none")
        val f = finalFile(ctx, code)
        if (p.getBoolean("ready", false) && f.isFile) {
            return mapOf("state" to "ready", "code" to code, "bytes" to f.length(), "total" to f.length())
        }
        var st = p.getString("state", "none") ?: "none"
        // The process died while downloading: what is on disk is kept; Download continues from there.
        // (The service needs a moment to start the worker after start(): not "stopped" yet.)
        val starting = System.currentTimeMillis() - startedAt < 15_000L
        if ((st == "running" || st == "paused" || st == "verifying") && worker?.isAlive != true && !starting) st = "stopped"
        if (st == "bad") return mapOf("state" to "bad", "code" to code)
        val parts = p.getInt("parts", 0)
        val onDisk = (0 until parts).sumOf { i -> partFile(ctx, code, i).let { if (it.isFile) it.length() else 0L } }
        val bytes = if (liveBytes >= 0 && st == "running") maxOf(liveBytes, onDisk) else onDisk
        return mapOf(
            "state" to st,
            "code" to code,
            "bytes" to bytes,
            "total" to p.getLong("size", 0L),
            "reason" to (p.getString("reason", "") ?: ""),
            "http" to p.getInt("http", 0),
        )
    }

    /** Stops the download; the files stay so the next start continues. */
    fun stop(ctx: Context) {
        stopFlag = true
        prefs(ctx).edit().putString("state", "stopped").apply()
        UpdateService.end(ctx)
    }

    /** Stops the download and removes every update file (a newer release, or the app is up to date). */
    fun cancel(ctx: Context) {
        stopFlag = true
        try { worker?.join(3000) } catch (_: Exception) {}
        synchronized(lock) {
            legacyCleanup(ctx)
            dir(ctx).listFiles()?.forEach { it.delete() }
            prefs(ctx).edit().clear().apply()
        }
        UpdateService.end(ctx)
    }

    /** Builds before this one used DownloadManager; forget any of their downloads. */
    private fun legacyCleanup(ctx: Context) {
        val ids = longs(prefs(ctx).getString("ids", "")).toLongArray()
        if (ids.isEmpty()) return
        try { (ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager).remove(*ids) } catch (_: Exception) {}
        prefs(ctx).edit().remove("ids").apply()
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

    private fun hex(b: ByteArray): String {
        val md = MessageDigest.getInstance("SHA-256")
        return md.digest(b).joinToString("") { "%02x".format(it) }
    }

    /** Current signer digests and rotation history (SHA-256 of each certificate). */
    @Suppress("DEPRECATION")
    private fun signers(pi: PackageInfo?): Pair<List<String>, List<String>> {
        if (pi == null) return Pair(emptyList(), emptyList())
        if (Build.VERSION.SDK_INT >= 28) {
            // Some Android versions leave signingInfo empty for a file that is not installed: use the old field.
            val si = pi.signingInfo
            if (si == null) {
                val old = (pi.signatures ?: emptyArray()).map { hex(it.toByteArray()) }
                return Pair(old, old)
            }
            val cur = (si.apkContentsSigners ?: emptyArray()).map { hex(it.toByteArray()) }
            val hist = if (si.hasMultipleSigners()) cur else (si.signingCertificateHistory ?: emptyArray()).map { hex(it.toByteArray()) }
            return Pair(cur, hist)
        }
        val cur = (pi.signatures ?: emptyArray()).map { hex(it.toByteArray()) }
        return Pair(cur, cur)
    }

    @Suppress("DEPRECATION")
    private fun archiveInfo(ctx: Context, path: String): PackageInfo? {
        val pm = ctx.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_SIGNATURES else PackageManager.GET_SIGNATURES
        return if (Build.VERSION.SDK_INT >= 33) pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(flags.toLong()))
        else pm.getPackageArchiveInfo(path, flags)
    }

    @Suppress("DEPRECATION")
    private fun appInfo(ctx: Context): PackageInfo? {
        val pm = ctx.packageManager
        return if (Build.VERSION.SDK_INT >= 33) pm.getPackageInfo(ctx.packageName, PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong()))
        else if (Build.VERSION.SDK_INT >= 28) pm.getPackageInfo(ctx.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        else pm.getPackageInfo(ctx.packageName, PackageManager.GET_SIGNATURES)
    }

    /**
     * Same rule as signersMatch() in lib/services/update_logic.dart. A file whose signer Android cannot read here
     * (apk empty while it does parse as our package) is left to Android's installer, which refuses a different key.
     */
    private fun signersMatch(app: List<String>, apk: List<String>, hist: List<String>): Boolean {
        if (apk.isEmpty() && app.isNotEmpty()) return true
        val a = app.toSet(); val b = apk.toSet()
        if (a.isEmpty() || b.isEmpty()) return false
        if (a == b) return true
        val h = hist.toSet()
        return h.containsAll(a) && h.containsAll(b)
    }

    /** The facts Dart turns into a verdict (verifyVerdict): sha256, package and signers of the file vs this app. */
    private fun verify(ctx: Context): Map<String, Any?> {
        val p = prefs(ctx)
        val code = p.getLong("code", 0L)
        val f = finalFile(ctx, code)
        if (code <= 0L || !p.getBoolean("ready", false) || !f.isFile) return mapOf("ready" to false)
        val got = sha256(f)
        val apk = archiveInfo(ctx, f.absolutePath)
        val (apkCur, apkHist) = signers(apk)
        val (appCur, _) = signers(appInfo(ctx))
        val ok = got == (p.getString("sha", "") ?: "") && apk?.packageName == ctx.packageName && signersMatch(appCur, apkCur, apkHist)
        p.edit().putString("verified", if (ok) "${f.length()}:${f.lastModified()}" else "").apply()
        return mapOf(
            "ready" to true,
            "sha256" to got,
            "expected_sha256" to (p.getString("sha", "") ?: ""),
            "package" to apk?.packageName,
            "app_package" to ctx.packageName,
            "apk_signers" to apkCur,
            "apk_history" to apkHist,
            "apk_signers_unreadable" to (apk != null && apkCur.isEmpty()),
            "app_signers" to appCur,
        )
    }

    /**
     * "started" | "needs_permission" | "not_ready" | "bad" | "bad_signer". Refuses a file that was not verified (or
     * changed since), whose sha256 does not match, or whose signer is not this app's.
     */
    private fun install(ctx: Context): String {
        val p = prefs(ctx)
        val code = p.getLong("code", 0L)
        val f = finalFile(ctx, code)
        if (code <= 0L || !p.getBoolean("ready", false) || !f.isFile) return "not_ready"
        if (p.getString("verified", "") != "${f.length()}:${f.lastModified()}") {
            if (sha256(f) != (p.getString("sha", "") ?: "")) { cancel(ctx); return "bad" }
        }
        val apk = archiveInfo(ctx, f.absolutePath)
        val (apkCur, apkHist) = signers(apk)
        val (appCur, _) = signers(appInfo(ctx))
        if (apk?.packageName != ctx.packageName || !signersMatch(appCur, apkCur, apkHist)) return "bad_signer"
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
}

/**
 * Keeps SubMac alive while an update downloads with the app in the background, with one quiet progress line
 * (words from Dart, in the app's language). Stops itself when the download ends.
 */
class UpdateService : Service() {
    companion object {
        fun begin(ctx: Context) {
            val i = Intent(ctx, UpdateService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (_: Exception) {
                // Not allowed right now (app in the background): download without the service.
                AppUpdater.runWorker(ctx.applicationContext) {}
            }
        }

        fun end(ctx: Context) {
            try { ctx.stopService(Intent(ctx, UpdateService::class.java)) } catch (_: Exception) {}
        }
    }

    private var lastNote = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    private fun note(bytes: Long, total: Long, indeterminate: Boolean): android.app.Notification {
        val title = AppUpdater.word(this, "downloading", "Downloading the SubMac update")
        val b = Notifier.builder(this, Notifier.QUIET)
            .setSmallIcon(R.drawable.ic_stat_submac)
            .setColor(0xFF17150F.toInt())
            .setContentTitle(title)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(Notifier.openIntent(this, "update", 7403))
        if (total > 0 && !indeterminate) {
            val pct = ((bytes * 100) / total).toInt().coerceIn(0, 100)
            b.setProgress(100, pct, false).setContentText("$pct%")
        } else {
            b.setProgress(0, 0, true)
        }
        return b.build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Notifier.ensureChannels(this)
        try {
            val n = note(0, 0, true)
            if (Build.VERSION.SDK_INT >= 29) startForeground(AppUpdater.NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(AppUpdater.NOTE_ID, n)
        } catch (_: Exception) {
            AppUpdater.runWorker(applicationContext) {}
            stopSelf()
            return START_NOT_STICKY
        }
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        AppUpdater.onProgress = { bytes, total, _ ->
            val now = System.currentTimeMillis()
            if (now - lastNote > 1000) {
                lastNote = now
                try { nm.notify(AppUpdater.NOTE_ID, note(bytes, total, false)) } catch (_: Exception) {}
            }
        }
        AppUpdater.runWorker(applicationContext) { stopSelf() }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        AppUpdater.onProgress = null
        super.onDestroy()
    }
}

/** Builds before 1.13.105 downloaded with DownloadManager; its "finished" broadcast is ignored now. */
class UpdateDone : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {}
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
