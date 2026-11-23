package com.telesia.app

import android.app.AlarmManager
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log

/**
 * Keeps Telesia alive while a task runs with the app closed, showing one calm line.
 * It also holds a partial wake lock while it runs (2026-11-05): a foreground service alone keeps the process, not the
 * CPU, so with the screen off (Doze) a bot's scheduled task used to stall until the phone woke up or the app opened.
 */
class TaskService : Service() {
    companion object {
        private const val NOTE_ID = 7201
        /** The longest a single hold lasts; a timer in the service renews it even when nothing else calls in. */
        private const val HOLD_MS = 30L * 60L * 1000L
        private const val RENEW_MS = 10L * 60L * 1000L
        @Volatile var text = "Telesia is active"
        @Volatile private var running = false

        fun start(ctx: Context, line: String) {
            text = line
            // Already in the foreground: only the line changes (no second start from the background).
            val live = instance
            if (running && live != null) {
                live.refresh()
                return
            }
            val i = Intent(ctx, TaskService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (e: Exception) {
                // Never fail in silence: on Android 14+ a dataSync foreground service may be refused if this is
                // called from the background. Callers now start the hold while Telesia is still on screen, but a
                // refusal must still be visible in logcat rather than leaving a task to die with no explanation.
                Log.w("TelesiaTask", "could not start the keep-alive service: $e")
            }
        }

        fun stop(ctx: Context) {
            // Marked stopped at once: a start right after this must start the service again, not only change the line
            // of a service that is about to go.
            running = false
            instance = null
            ctx.stopService(Intent(ctx, TaskService::class.java))
        }

        @Volatile private var instance: TaskService? = null
    }

    override fun onCreate() {
        super.onCreate()
        // If Android restarts this service after a process kill (START_STICKY), bring Dart back with it: an active
        // task is otherwise a notification with nobody behind it, and the Stop button has no runner to reach.
        TelesiaApp.engine(applicationContext)
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    /** A long opencode turn can go quiet for a long time; keep the CPU awake without relying on Dart to renew. */
    private val renew = object : Runnable {
        override fun run() {
            hold()
            handler.postDelayed(this, RENEW_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun note(): Notification {
        Notifier.ensureChannels(this)
        // Always "Telesia is active" (owner 2026-11-07); the bot and its task are the second line, "Nova · Hourly news".
        // The result comes as its own notification when the work ends.
        val line = text.trim()
        val b = Notifier.builder(this, Notifier.WORK)
            .setSmallIcon(R.drawable.ic_stat_telesia)
            .setColor(0xFF17150F.toInt())
            .setContentTitle("Telesia is active")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(Notifier.openIntent(this, "tasks", 7202))
        if (line.isNotEmpty() && !line.equals("Telesia is active", ignoreCase = true)) b.setContentText(line)
        // Stop without hunting for the app or a chat: the broadcast reaches Dart even after recents were cleared.
        val stop = PendingIntent.getBroadcast(
            this, NOTE_ID + 1,
            Intent(this, AlarmReceiver::class.java).putExtra("stop_all", "1"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        b.addAction(Notification.Action.Builder(
            android.graphics.drawable.Icon.createWithResource(this, android.R.drawable.ic_media_stop), "Stop", stop).build())
        if (Build.VERSION.SDK_INT >= 31) b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        return b.build()
    }

    /** New line on the running notification, and the wake lock renewed. */
    fun refresh() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            nm.notify(NOTE_ID, note())
        } catch (_: Exception) {
        }
        hold()
    }

    private fun hold() {
        try {
            val w = wakeLock ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "telesia:task").also { it.setReferenceCounted(false) }
            wakeLock = w
            w.acquire(HOLD_MS)
        } catch (_: Exception) {
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = note()
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(NOTE_ID, n)
            instance = this
            running = true
            hold()
            handler.removeCallbacks(renew)
            handler.postDelayed(renew, RENEW_MS)
        } catch (e: Exception) {
            Log.w("TelesiaTask", "could not go foreground: $e")
            stopSelf()
        }
        // A task outlives the service being recycled by Android; a restart must reassert the hold, not vanish.
        return START_STICKY
    }

    /** Swiping Telesia away from recents must not take a running task with it. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
            nm.notify(NOTE_ID, note())
            hold()
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        running = false
        handler.removeCallbacks(renew)
        if (instance === this) instance = null
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        super.onDestroy()
    }
}

/** Fires a scheduled task: wakes Telesia (even if closed) and hands the task id to Dart. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        // Stop from the ongoing "Telesia is active" notification. Works with the app minimized or cleared from
        // recents: the broadcast wakes the headless engine and Dart stops the runs, which releases the hold.
        if (intent.getStringExtra("stop_all") != null) {
            TelesiaApp.engine(ctx)
            Bridge.send("stopAll")
            return
        }
        // "Decline" on a bot's ringing call: stop ringing and tell the bot (it sends a text instead).
        val declined = intent.getStringExtra("decline")
        if (declined != null) {
            Notifier.ringCancel(ctx, intent.getIntExtra("note", 0))
            TelesiaApp.engine(ctx)
            Bridge.send("botDecline", declined)
            return
        }
        // A bot's call rang out with no answer.
        val missed = intent.getStringExtra("missed")
        if (missed != null) {
            val note = intent.getIntExtra("note", 0)
            Notifier.missed(ctx, note, missed, intent.getStringExtra("name") ?: "Telesia", intent.getStringExtra("reason") ?: "")
            if (TelesiaApp.engineIfRunning() != null) Bridge.send("botMissed", missed)
            return
        }
        // Approve / Deny on a bot's request.
        val approval = intent.getStringExtra("approval")
        if (approval != null) {
            Notifier.ringCancel(ctx, intent.getIntExtra("note", 0))
            TelesiaApp.engine(ctx)
            Bridge.send("approval", mapOf("id" to approval, "ok" to intent.getBooleanExtra("ok", false)))
            return
        }
        // A reply typed right in a bot's notification.
        val replyTo = intent.getStringExtra("reply_to")
        if (replyTo != null) {
            val text = android.app.RemoteInput.getResultsFromIntent(intent)?.getCharSequence("reply_text")?.toString()?.trim() ?: ""
            val name = intent.getStringExtra("name") ?: "Telesia"
            Notifier.replied(ctx, intent.getIntExtra("note", 0), name, text, replyTo)
            if (text.isNotEmpty()) {
                // The app may be closed: the foreground service and its wake lock carry the answer (headless engine).
                TaskService.start(ctx, "$name · Your reply")
                TelesiaApp.engine(ctx)
                Bridge.send("notifReply", mapOf("to" to replyTo, "text" to text))
            }
            return
        }
        val id = intent.getStringExtra("id") ?: return
        // The line Dart gave when it set the alarm ("<Bot name> · <task title>"); Dart updates it once it runs.
        val label = intent.getStringExtra("label") ?: ""
        TaskService.start(ctx, if (label.isEmpty()) "Telesia · Getting ready" else label)
        TelesiaApp.engine(ctx)
        Bridge.send("alarm", id)
    }
}

object Alarms {
    private fun pi(ctx: Context, id: String, label: String = ""): PendingIntent {
        val i = Intent(ctx, AlarmReceiver::class.java).putExtra("id", id)
        if (label.isNotEmpty()) i.putExtra("label", label)
        return PendingIntent.getBroadcast(ctx, id.hashCode(), i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun set(ctx: Context, id: String, at: Long, label: String = "") {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val p = pi(ctx, id, label)
        val exact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()
        if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, p)
        else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, p)
    }

    fun cancel(ctx: Context, id: String) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pi(ctx, id))
    }
}
