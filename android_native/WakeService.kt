package com.submac.agent

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import org.json.JSONArray
import org.json.JSONObject
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File

/**
 * "Hello SubMac": listens offline (Vosk) in a foreground service and wakes Live.
 * Built not to go deaf: it lets go of the mic during calls, when another app records and
 * while Live talks, then takes it back, and restarts itself after any audio error.
 */
class WakeService : Service() {
    companion object {
        private const val NOTE_ID = 7101
        private const val PREFS = "submac_wake"
        @Volatile var paused = false
        @Volatile var sensitivity = 0.6f
        @Volatile var state = "off"
        /** Live is on: keep a microphone foreground service so Android lets Live hear you from any app. */
        @Volatile var liveHold = false
        @Volatile private var running = false

        // Vosk only knows dictionary words, so the name is matched as "sub mac". The look-alike words
        // (submit, subway, big mac...) are there so they get recognised as themselves, not as SubMac:
        // tested offline on 112 clips, 42/42 wake phrases heard and 0/70 look-alikes triggered.
        private val PHRASES = listOf(
            "hey sub mac", "hello sub mac", "hi sub mac", "okay sub mac", "sub mac",
            "hey sub mack", "hello sub mack", "sub mack",
            "submit", "subway", "submarine", "subject", "summit", "big mac", "mac", "sub", "some", "hello", "hey"
        )

        fun start(ctx: Context, model: String, sens: Float, screenOff: Boolean) {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            if (model.isNotEmpty()) p.putString("model", model)
            p.putFloat("sens", sens).putBoolean("screenOff", screenOff).putBoolean("enabled", true).apply()
            sensitivity = sens
            paused = false
            val i = Intent(ctx, WakeService::class.java)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }

        fun stop(ctx: Context) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("enabled", false).apply()
            moveTo("off")
            if (liveHold) {
                instance?.stopWorker()
                return
            }
            ctx.stopService(Intent(ctx, WakeService::class.java))
        }

        fun live(ctx: Context, on: Boolean) {
            liveHold = on
            if (on) {
                paused = true
                val i = Intent(ctx, WakeService::class.java).setAction("live")
                try {
                    if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
                } catch (_: Exception) {
                }
            } else if (enabled(ctx)) {
                paused = false
                instance?.updateNote()
            } else {
                ctx.stopService(Intent(ctx, WakeService::class.java))
            }
        }

        @Volatile private var instance: WakeService? = null

        fun enabled(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("enabled", false)

        private fun moveTo(s: String) {
            if (state == s) return
            state = s
            Bridge.send("wakeState", s)
        }
    }

    private var worker: Thread? = null
    @Volatile private var stopping = false
    private var wakeLock: PowerManager.WakeLock? = null
    private val main = Handler(Looper.getMainLooper())
    private var lastTrigger = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "pause" -> paused = true
            "resume" -> paused = false
            "off" -> {
                stop(this)
                return START_NOT_STICKY
            }
            "end_live" -> {
                val m = HashMap<String, Any?>()
                m["action"] = "end"
                Bridge.send("overlay", m)
                return START_NOT_STICKY
            }
        }
        instance = this
        if (!goForeground()) {
            stopSelf()
            return START_NOT_STICKY
        }
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        sensitivity = prefs.getFloat("sens", sensitivity)
        if (!running && enabled(this)) {
            running = true
            stopping = false
            if (prefs.getBoolean("screenOff", true)) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "submac:wake").also { it.setReferenceCounted(false); it.acquire() }
            }
            worker = Thread({ loop(prefs.getString("model", "") ?: "") }, "submac-wake").also { it.start() }
        }
        updateNote()
        return START_STICKY
    }

    private fun note(): Notification {
        val pauseI = Intent(this, WakeService::class.java).setAction(if (paused) "resume" else "pause")
        val offI = Intent(this, WakeService::class.java).setAction("off")
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val text = when {
            paused -> "Paused"
            state == "mic_busy" -> "Waiting for the microphone"
            state == "call" -> "Paused during your call"
            else -> "Say \u201CHello SubMac\u201D"
        }
        if (liveHold) {
            val endI = Intent(this, WakeService::class.java).setAction("end_live")
            return Notifier.builder(this, Notifier.WAKE)
                .setSmallIcon(R.drawable.ic_stat_submac).setColor(0xFFC2361B.toInt())
                .setContentTitle("SubMac Live is on")
                .setContentText("Tap to open")
                .setColor(0xFFC2361B.toInt())
                .setOngoing(true)
                .setContentIntent(Notifier.openIntent(this, "live", 7106))
                .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(this, applicationInfo.icon), "End call", PendingIntent.getService(this, 7107, endI, flags)).build())
                .build()
        }
        @Suppress("DEPRECATION")
        return Notifier.builder(this, Notifier.WAKE)
            .setSmallIcon(R.drawable.ic_stat_submac).setColor(0xFFC2361B.toInt())
            .setContentTitle("SubMac is listening")
            .setContentText(text)
            .setColor(0xFFC2361B.toInt())
            .setOngoing(true)
            .setContentIntent(Notifier.openIntent(this, "settings/wake", 7102))
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(this, applicationInfo.icon), if (paused) "Resume" else "Pause", PendingIntent.getService(this, 7103, pauseI, flags)).build())
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(this, applicationInfo.icon), "Turn off", PendingIntent.getService(this, 7104, offI, flags)).build())
            .build()
    }

    fun updateNote() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            nm.notify(NOTE_ID, note())
        } catch (_: Exception) {
        }
    }

    private fun goForeground(): Boolean {
        return try {
            Notifier.ensureChannels(this)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTE_ID, note(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTE_ID, note())
            }
            true
        } catch (e: Exception) {
            // Android blocks starting the mic from the background (e.g. right after a restart).
            moveTo("needs_tap")
            Notifier.task(this, 7105, "", "Listening is paused. Open SubMac to turn it back on.", "wake/restart", "paused")
            false
        }
    }

    private fun loop(modelPath: String) {
        try {
            LibVosk.setLogLevel(LogLevel.WARNINGS)
        } catch (_: Throwable) {
        }
        val dir = File(modelPath)
        if (modelPath.isEmpty() || !dir.isDirectory) {
            moveTo("no_model")
            return
        }
        var model: Model? = null
        var backoff = 500L
        while (!stopping) {
            var rec: AudioRecord? = null
            var recognizer: Recognizer? = null
            try {
                if (model == null) {
                    moveTo("loading")
                    model = Model(dir.absolutePath)
                }
                // Hold the mic only while it's ours to hold.
                if (paused) { moveTo("paused"); main.post { updateNote() }; Thread.sleep(400); continue }
                if (inCall()) { moveTo("call"); main.post { updateNote() }; Thread.sleep(1000); continue }

                val grammar = JSONArray(PHRASES + "[unk]").toString()
                recognizer = Recognizer(model, 16000f, grammar)
                recognizer.setWords(true)
                val minBuf = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                val bufBytes = maxOf(minBuf, 16000 * 2 / 5)
                rec = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufBytes * 2)
                if (rec.state != AudioRecord.STATE_INITIALIZED) throw IllegalStateException("mic not ready")
                // Phone noise suppression and gain help in a loud room (when the phone has them).
                try { if (android.media.audiofx.NoiseSuppressor.isAvailable()) android.media.audiofx.NoiseSuppressor.create(rec.audioSessionId)?.enabled = true } catch (_: Throwable) {}
                try { if (android.media.audiofx.AutomaticGainControl.isAvailable()) android.media.audiofx.AutomaticGainControl.create(rec.audioSessionId)?.enabled = true } catch (_: Throwable) {}
                rec.startRecording()
                moveTo("listening")
                main.post { updateNote() }
                backoff = 500L
                val buf = ShortArray(1600) // 100 ms
                var silentMs = 0
                var checkMs = 0
                while (!stopping && !paused) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n < 0) throw IllegalStateException("mic read $n")
                    if (n == 0) { Thread.sleep(20); continue }
                    // All-zero audio means Android gave the mic to someone else: let go and retry.
                    var peak = 0
                    for (i in 0 until n) { val a = Math.abs(buf[i].toInt()); if (a > peak) peak = a }
                    silentMs = if (peak == 0) silentMs + 100 else 0
                    if (silentMs >= 2500) { moveTo("mic_busy"); main.post { updateNote() }; break }
                    checkMs += 100
                    if (checkMs >= 1000) { checkMs = 0; if (inCall()) break }
                    if (recognizer.acceptWaveForm(buf, n)) {
                        if (heard(recognizer.result, final = true)) { recognizer.reset(); trigger() }
                    } else if (sensitivity >= 0.75f) {
                        if (heard(recognizer.partialResult, final = false)) { recognizer.reset(); trigger() }
                    }
                }
            } catch (e: InterruptedException) {
                break
            } catch (e: Throwable) {
                moveTo("retrying")
                try { Thread.sleep(backoff) } catch (_: InterruptedException) { break }
                backoff = minOf(backoff * 2, 10000L)
            } finally {
                try { rec?.stop() } catch (_: Throwable) {}
                try { rec?.release() } catch (_: Throwable) {}
                try { recognizer?.close() } catch (_: Throwable) {}
            }
            if (state == "mic_busy") try { Thread.sleep(2000) } catch (_: InterruptedException) { break }
        }
        try { model?.close() } catch (_: Throwable) {}
    }

    private fun inCall(): Boolean {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return am.mode == AudioManager.MODE_IN_CALL || am.mode == AudioManager.MODE_IN_COMMUNICATION
    }

    /** True when the recognizer heard the name with enough confidence for the current sensitivity. */
    private fun heard(json: String, final: Boolean): Boolean {
        val o = try { JSONObject(json) } catch (_: Exception) { return false }
        val text = (if (final) o.optString("text") else o.optString("partial")).lowercase().trim()
        if (!text.contains("sub mac") && !text.contains("sub mack")) return false
        if (!final) return true
        val words = o.optJSONArray("result") ?: return true
        var sum = 0.0
        var cnt = 0
        for (i in 0 until words.length()) {
            val w = words.optJSONObject(i) ?: continue
            val word = w.optString("word")
            if (word == "sub" || word == "mac" || word == "mack") { sum += w.optDouble("conf", 1.0); cnt++ }
        }
        if (cnt == 0) return false
        val threshold = 0.92 - 0.45 * sensitivity
        return sum / cnt >= threshold
    }

    private fun trigger() {
        val now = System.currentTimeMillis()
        if (now - lastTrigger < 2500) return
        lastTrigger = now
        paused = true // Live takes the mic; Dart resumes us when the call ends.
        main.post {
            Chime.play(this)
            Overlay.show(this, "popup")
            Overlay.update("Listening", 0f, "", "", false, false)
            Bridge.send("wake", "hello submac")
            updateNote()
            // Safety: if Live never starts, take the mic back.
            main.postDelayed({
                if (paused && !Overlay.liveActive) {
                    Overlay.hide()
                    paused = false
                    updateNote()
                }
            }, 20000)
        }
    }

    fun stopWorker() {
        stopping = true
        running = false
        worker?.interrupt()
        try { wakeLock?.release() } catch (_: Exception) {}
        updateNote()
    }

    override fun onDestroy() {
        instance = null
        liveHold = false
        stopping = true
        running = false
        worker?.interrupt()
        try { wakeLock?.release() } catch (_: Exception) {}
        if (state != "off") moveTo("stopped")
        super.onDestroy()
    }
}
