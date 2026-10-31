package com.submac.agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build

/** Calm system notifications: a task finished, a scheduled task ran, the wake word needs a tap. */
object Notifier {
    /** v2: the soft two-note SubMac chime. Channels keep their first sound, so the id changed. */
    const val TASKS = "submac_tasks_v2"
    private const val OLD_TASKS = "submac_tasks"
    const val WAKE = "submac_wake"
    /** Everyday "done" results: silent, no pop-up. Only scheduled results and questions make a sound. */
    const val QUIET = "submac_quiet"
    /** A bot calling: rings with the phone's ringtone, at the top of the screen (or full screen if chosen). */
    const val CALLS = "submac_bot_calls"
    /** A message from a bot: like a text from a colleague. */
    const val BOTS = "submac_bot_msgs"
    /** A running task waits for the user's OK while SubMac is behind another app: pops up so the ask is never hidden. */
    const val ASKS = "submac_asks"

    fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try { nm.deleteNotificationChannel(OLD_TASKS) } catch (_: Exception) {}
        nm.createNotificationChannel(
            NotificationChannel(TASKS, "Tasks", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "When a task finishes or a scheduled task runs"
                setSound(
                    Uri.parse("android.resource://" + ctx.packageName + "/" + R.raw.submac_done),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 14, 110, 22)
                enableLights(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(QUIET, "Finished tasks", NotificationManager.IMPORTANCE_LOW).apply {
                description = "A quiet line when a task finishes while you are away"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(true)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CALLS, "Calls from bots", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "When one of your bots calls you"
                setSound(
                    android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 600, 400, 600, 400, 600)
                enableLights(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(BOTS, "Messages from bots", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "When one of your bots has something for you"
                setSound(
                    Uri.parse("android.resource://" + ctx.packageName + "/" + R.raw.submac_done),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 14, 110, 22)
                enableLights(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(ASKS, "Needs your OK", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "When a task waits for your OK while you are in another app"
                setSound(
                    Uri.parse("android.resource://" + ctx.packageName + "/" + R.raw.submac_done),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 14, 110, 22)
                enableLights(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(WAKE, "Hello SubMac", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Shown while SubMac listens for its name"
                setShowBadge(false)
                setSound(null, null)
            }
        )
    }

    fun openIntent(ctx: Context, payload: String, req: Int): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        i.putExtra("submac_payload", payload)
        return PendingIntent.getActivity(ctx, req, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    @Suppress("DEPRECATION")
    fun builder(ctx: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, channel) else Notification.Builder(ctx)

    /** A quiet notification: one plain line that says what matters. Never the full reply. */
    fun task(ctx: Context, id: Int, title: String, body: String, payload: String, kind: String = "done") {
        ensureChannels(ctx)
        val prefs = ctx.getSharedPreferences("submac_notes", Context.MODE_PRIVATE)
        if (kind == "paused") {
            // "Listening is paused" at most once every 6 hours.
            val last = prefs.getLong("paused_at", 0L)
            if (System.currentTimeMillis() - last < 6 * 3600_000L) return
            prefs.edit().putLong("paused_at", System.currentTimeMillis()).apply()
        }
        val loud = kind == "scheduled" || kind == "attention" || kind == "approval"
        var line = (if (body.isNotBlank()) body else title).replace(Regex("\\s+"), " ").trim()
        if (line.length > 110) line = line.substring(0, 108).trimEnd() + "…"
        val b = builder(ctx, if (kind == "approval") ASKS else if (loud) TASKS else QUIET)
            .setSmallIcon(R.drawable.ic_stat_submac)
            .setColor(0xFF17150F.toInt())
            // One plain line that says what matters ("Your image is ready"). No big custom card.
            .setContentTitle(line)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setGroup("submac_tasks")
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(openIntent(ctx, payload, id))
        // On the lock screen show only the brand, never what the task was about.
        b.setPublicVersion(
            builder(ctx, TASKS)
                .setSmallIcon(R.drawable.ic_stat_submac)
                .setColor(0xFF17150F.toInt())
                .setContentTitle("SubMac")
                .setContentText("Something is ready for you.")
                .build()
        )
        val n = b.build()
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            nm.notify(id, n)
        } catch (_: SecurityException) {
        }
    }

    /** A bot calls the user. Answer opens the call; Decline tells the bot (it texts instead). Stops ringing after 35 s. */
    fun ring(ctx: Context, id: Int, botId: String, name: String, reason: String, full: Boolean) {
        ensureChannels(ctx)
        val answer = openIntent(ctx, "botcall/$botId", id + 1)
        val ringing = openIntent(ctx, "botring/$botId", id + 2)
        val decline = PendingIntent.getBroadcast(
            ctx, id + 3,
            Intent(ctx, AlarmReceiver::class.java).putExtra("decline", botId).putExtra("note", id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        var line = reason.replace(Regex("\\s+"), " ").trim()
        if (line.length > 110) line = line.substring(0, 108).trimEnd() + "…"
        @Suppress("DEPRECATION")
        val b = builder(ctx, CALLS)
            .setSmallIcon(R.drawable.ic_stat_submac)
            .setColor(0xFF17150F.toInt())
            .setContentTitle(name)
            .setContentText(if (line.isEmpty()) "Calling you" else line)
            .setCategory(Notification.CATEGORY_CALL)
            .setPriority(Notification.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(ringing)
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(ctx, R.drawable.ic_stat_submac), "Decline", decline).build())
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(ctx, R.drawable.ic_stat_submac), "Answer", answer).build())
        if (Build.VERSION.SDK_INT >= 26) b.setTimeoutAfter(35_000)
        if (full) b.setFullScreenIntent(ringing, true)
        val n = b.build()
        n.flags = n.flags or Notification.FLAG_INSISTENT
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            nm.notify(id, n)
        } catch (_: SecurityException) {
        }
        // The missed-call timer lives here, not in Dart, so a call never rings forever when Android stops the app.
        try {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
            val at = System.currentTimeMillis() + 36_000
            val p = missedIntent(ctx, id, botId, name, reason)
            if (Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()) am.setExactAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP, at, p)
            else am.setAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP, at, p)
        } catch (_: Throwable) {}
    }

    private fun missedIntent(ctx: Context, id: Int, botId: String = "", name: String = "", reason: String = ""): PendingIntent =
        PendingIntent.getBroadcast(
            ctx, id + 4,
            Intent(ctx, AlarmReceiver::class.java).putExtra("missed", botId).putExtra("note", id).putExtra("name", name).putExtra("reason", reason),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    fun ringCancel(ctx: Context, id: Int) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try { nm.cancel(id) } catch (_: Throwable) {}
        // Answered or declined: the missed-call timer goes too.
        try {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
            am.cancel(missedIntent(ctx, id))
        } catch (_: Throwable) {}
    }

    /** Nobody answered: the ringing stops and a calm "Missed call" stays, even if SubMac itself was stopped. */
    fun missed(ctx: Context, id: Int, botId: String, name: String, reason: String) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try { nm.cancel(id) } catch (_: Throwable) {}
        bot(ctx, id + 1000, name, if (reason.isBlank()) "Missed call" else "Missed call. $reason", "botchat/$botId")
    }

    /** A bot's message: its name, then one or two lines of what it has for the user. [reply] adds an inline Reply field. */
    fun bot(ctx: Context, id: Int, name: String, body: String, payload: String, reply: Boolean = false) {
        ensureChannels(ctx)
        var line = body.replace(Regex("\\s+"), " ").trim()
        if (line.length > 220) line = line.substring(0, 218).trimEnd() + "…"
        val b = builder(ctx, BOTS)
            .setSmallIcon(R.drawable.ic_stat_submac)
            .setColor(0xFF17150F.toInt())
            .setContentTitle(name)
            .setContentText(line)
            .setStyle(Notification.BigTextStyle().bigText(line))
            .setAutoCancel(true)
            .setShowWhen(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(openIntent(ctx, payload, id))
        if (reply && payload.isNotEmpty()) {
            val input = android.app.RemoteInput.Builder("reply_text").setLabel("Reply to $name").build()
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
            val pi = PendingIntent.getBroadcast(
                ctx, id + 50_000,
                Intent(ctx, AlarmReceiver::class.java).putExtra("reply_to", payload).putExtra("note", id).putExtra("name", name),
                flags
            )
            b.addAction(
                Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(ctx, R.drawable.ic_stat_submac), "Reply", pi)
                    .addRemoteInput(input).build()
            )
        }
        b.setPublicVersion(
            builder(ctx, BOTS).setSmallIcon(R.drawable.ic_stat_submac).setColor(0xFF17150F.toInt())
                .setContentTitle(name).setContentText("New message").build()
        )
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            nm.notify(id, b.build())
        } catch (_: SecurityException) {
        }
    }

    /** A bot asks before something risky (send, pay, delete, publish): Approve or Deny right here. */
    fun approval(ctx: Context, id: Int, approvalId: String, name: String, title: String, body: String) {
        ensureChannels(ctx)
        fun act(ok: Boolean): PendingIntent = PendingIntent.getBroadcast(
            ctx, id * 2 + (if (ok) 1 else 0),
            Intent(ctx, AlarmReceiver::class.java).putExtra("approval", approvalId).putExtra("ok", ok).putExtra("note", id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        var line = title.replace(Regex("\\s+"), " ").trim()
        if (line.length > 140) line = line.substring(0, 138).trimEnd() + "…"
        var more = body.replace(Regex("\\s+"), " ").trim()
        if (more.length > 400) more = more.substring(0, 398).trimEnd() + "…"
        val b = builder(ctx, BOTS)
            .setSmallIcon(R.drawable.ic_stat_submac)
            .setColor(0xFF17150F.toInt())
            .setContentTitle(name)
            .setContentText(line)
            .setStyle(Notification.BigTextStyle().bigText(if (more.isEmpty()) line else "$line\n$more"))
            .setAutoCancel(true)
            .setShowWhen(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(openIntent(ctx, "approvals", id))
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(ctx, R.drawable.ic_stat_submac), "Not now", act(false)).build())
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(ctx, R.drawable.ic_stat_submac), "Approve", act(true)).build())
        b.setPublicVersion(
            builder(ctx, BOTS).setSmallIcon(R.drawable.ic_stat_submac).setColor(0xFF17150F.toInt())
                .setContentTitle(name).setContentText("Needs your OK").build()
        )
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            nm.notify(id, b.build())
        } catch (_: SecurityException) {
        }
    }

    /** After an inline reply: the notification says it was sent, then goes away. */
    fun replied(ctx: Context, id: Int, name: String) {
        ensureChannels(ctx)
        val b = builder(ctx, BOTS)
            .setSmallIcon(R.drawable.ic_stat_submac)
            .setColor(0xFF17150F.toInt())
            .setContentTitle(name)
            .setContentText("Sent")
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
        if (Build.VERSION.SDK_INT >= 26) b.setTimeoutAfter(2_500)
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            nm.notify(id, b.build())
        } catch (_: SecurityException) {
        }
    }

    /** Back in the app: clear the result notifications (never the running-task or wake-word ones). */
    fun clearTasks(ctx: Context) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                for (s in nm.activeNotifications) {
                    val ch = s.notification.channelId
                    if (ch == TASKS || ch == QUIET || ch == BOTS) nm.cancel(s.tag, s.id)
                }
            }
        } catch (_: Throwable) {}
    }
}
