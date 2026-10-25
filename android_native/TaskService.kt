package com.submac.agent

import android.app.AlarmManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Keeps SubMac alive while a task runs with the app closed, showing one calm line. */
class TaskService : Service() {
    companion object {
        private const val NOTE_ID = 7201
        @Volatile var text = "Working on your task"

        fun start(ctx: Context, line: String) {
            text = line
            val i = Intent(ctx, TaskService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (_: Exception) {
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, TaskService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Notifier.ensureChannels(this)
        val n = Notifier.builder(this, Notifier.WAKE)
            .setSmallIcon(R.drawable.ic_stat_submac).setColor(0xFF17150F.toInt())
            .setContentTitle(text)
            .setColor(0xFF17150F.toInt())
            .setOngoing(true)
            .setContentIntent(Notifier.openIntent(this, "tasks", 7202))
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(NOTE_ID, n)
        } catch (_: Exception) {
            stopSelf()
        }
        return START_NOT_STICKY
    }
}

/** Fires a scheduled task: wakes SubMac (even if closed) and hands the task id to Dart. */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        // "Decline" on a bot's ringing call: stop ringing and tell the bot (it sends a text instead).
        val declined = intent.getStringExtra("decline")
        if (declined != null) {
            Notifier.ringCancel(ctx, intent.getIntExtra("note", 0))
            SubMacApp.engine(ctx)
            Bridge.send("botDecline", declined)
            return
        }
        // A bot's call rang out with no answer.
        val missed = intent.getStringExtra("missed")
        if (missed != null) {
            val note = intent.getIntExtra("note", 0)
            Notifier.missed(ctx, note, missed, intent.getStringExtra("name") ?: "SubMac", intent.getStringExtra("reason") ?: "")
            if (SubMacApp.engineIfRunning() != null) Bridge.send("botMissed", missed)
            return
        }
        // Approve / Deny on a bot's request.
        val approval = intent.getStringExtra("approval")
        if (approval != null) {
            Notifier.ringCancel(ctx, intent.getIntExtra("note", 0))
            SubMacApp.engine(ctx)
            Bridge.send("approval", mapOf("id" to approval, "ok" to intent.getBooleanExtra("ok", false)))
            return
        }
        // A reply typed right in a bot's notification.
        val replyTo = intent.getStringExtra("reply_to")
        if (replyTo != null) {
            val text = android.app.RemoteInput.getResultsFromIntent(intent)?.getCharSequence("reply_text")?.toString()?.trim() ?: ""
            Notifier.replied(ctx, intent.getIntExtra("note", 0), intent.getStringExtra("name") ?: "SubMac")
            if (text.isNotEmpty()) {
                TaskService.start(ctx, "Sending your reply")
                SubMacApp.engine(ctx)
                Bridge.send("notifReply", mapOf("to" to replyTo, "text" to text))
            }
            return
        }
        val id = intent.getStringExtra("id") ?: return
        TaskService.start(ctx, "Running a scheduled task")
        SubMacApp.engine(ctx)
        Bridge.send("alarm", id)
    }
}

object Alarms {
    private fun pi(ctx: Context, id: String): PendingIntent {
        val i = Intent(ctx, AlarmReceiver::class.java).putExtra("id", id)
        return PendingIntent.getBroadcast(ctx, id.hashCode(), i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun set(ctx: Context, id: String, at: Long) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val p = pi(ctx, id)
        val exact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()
        if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, p)
        else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, p)
    }

    fun cancel(ctx: Context, id: String) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(pi(ctx, id))
    }
}
