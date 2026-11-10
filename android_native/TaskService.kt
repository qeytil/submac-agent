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
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps Telesia alive while a task runs with the app closed, showing one calm line.
 * It also holds a partial wake lock while it runs (2026-11-05): a foreground service alone keeps the process, not the
 * CPU, so with the screen off (Doze) a bot's scheduled task used to stall until the phone woke up or the app opened.
 */
class TaskService : Service() {
    companion object {
        private const val NOTE_ID = 7201
        /** The longest a single hold lasts; every new start or update renews it. */
        private const val HOLD_MS = 30L * 60L * 1000L
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
            } catch (_: Exception) {
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

    private var wakeLock: PowerManager.WakeLock? = null

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
        } catch (_: Exception) {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
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
