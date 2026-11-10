package com.telesia.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build

/**
 * Calm system notifications (docs/notifications.md). Who it is from decides the channel and the look:
 * Agent (Telesia itself: title "Telesia", Telesia red), Bots (the bot's name and its avatar colour), Teams (one
 * conversation per team, "<Bot>: message", inline Reply) and Background work (the silent running line).
 */
object Notifier {
    /** Agent: Telesia's own results (its chats, its scheduled tasks). v2 of the channels (2026-11-05): the new light
     *  chime (res/raw/telesia_chime.wav). A channel keeps its first sound, so the ids changed and the old ones go. */
    const val TASKS = "telesia_agent_v2"
    const val AGENT = TASKS
    /** Ids from before the chime: deleted on start. */
    private val RETIRED = arrayOf("telesia_tasks", "telesia_tasks_v2", "telesia_bot_msgs")
    const val WAKE = "telesia_wake"
    /** Everyday "done" results: silent, no pop-up. Only scheduled results and questions make a sound. */
    const val QUIET = "telesia_quiet"
    /** A bot calling: rings with the phone's ringtone, at the top of the screen (or full screen if chosen). */
    const val CALLS = "telesia_bot_calls"
    /** A message from a bot: like a text from a colleague. */
    const val BOTS = "telesia_bots_v2"
    /** A team chat: one conversation per team. */
    const val TEAMS = "telesia_teams_v2"
    /** A team post marked [needs you]: pops up. */
    const val TEAMS_NEEDS = "telesia_teams_needs_v2"
    /** Work running with Telesia closed ("Nova · Hourly news"): silent, low, no badge. */
    const val WORK = "telesia_work_v2"
    /** A running task waits for the user's OK while Telesia is behind another app: pops up so the ask is never hidden. */
    const val ASKS = "telesia_asks"

    /** Telesia red: the agent's accent, so its notifications never look like a bot's. */
    val AGENT_RED: Int = 0xFFC2361B.toInt()
    private val INK: Int = 0xFF17150F.toInt()
    private const val TEAM_PREFS = "telesia_team_notes"
    /** The owner's own line in a team conversation (a reply typed in the notification). */
    private const val ME = "@you"

    private fun chimeUri(ctx: Context): Uri = Uri.parse("android.resource://" + ctx.packageName + "/" + R.raw.telesia_chime)

    private fun soundAttrs(): AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private fun chimed(ctx: Context, id: String, name: String, importance: Int, about: String): NotificationChannel =
        NotificationChannel(id, name, importance).apply {
            description = about
            setSound(chimeUri(ctx), soundAttrs())
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 14, 110, 22)
            enableLights(false)
        }

    fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        for (old in RETIRED) {
            try { nm.deleteNotificationChannel(old) } catch (_: Exception) {}
        }
        nm.createNotificationChannel(chimed(ctx, AGENT, "Telesia", NotificationManager.IMPORTANCE_DEFAULT,
            "Telesia's own results: a task finished, a scheduled task's result"))
        nm.createNotificationChannel(chimed(ctx, BOTS, "Bots", NotificationManager.IMPORTANCE_DEFAULT,
            "When one of your bots has something for you"))
        nm.createNotificationChannel(chimed(ctx, TEAMS, "Teams", NotificationManager.IMPORTANCE_DEFAULT,
            "Messages in your team chats"))
        nm.createNotificationChannel(chimed(ctx, TEAMS_NEEDS, "Teams: needs you", NotificationManager.IMPORTANCE_HIGH,
            "A teammate needs your answer or decision"))
        nm.createNotificationChannel(
            NotificationChannel(WORK, "Background work", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown quietly while a bot, a team or a scheduled task works with Telesia closed"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
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
            NotificationChannel(ASKS, "Needs your OK", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "When a task waits for your OK while you are in another app"
                setSound(
                    Uri.parse("android.resource://" + ctx.packageName + "/" + R.raw.telesia_done),
                    soundAttrs()
                )
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 14, 110, 22)
                enableLights(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(WAKE, "Hello Telesia", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Shown while Telesia listens for its name"
                setShowBadge(false)
                setSound(null, null)
            }
        )
    }

    fun openIntent(ctx: Context, payload: String, req: Int): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        i.putExtra("telesia_payload", payload)
        return PendingIntent.getActivity(ctx, req, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    @Suppress("DEPRECATION")
    fun builder(ctx: Context, channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, channel) else Notification.Builder(ctx)

    /** A quiet notification: one plain line that says what matters. Never the full reply. */
    fun task(ctx: Context, id: Int, title: String, body: String, payload: String, kind: String = "done") {
        ensureChannels(ctx)
        val prefs = ctx.getSharedPreferences("telesia_notes", Context.MODE_PRIVATE)
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
            .setSmallIcon(R.drawable.ic_stat_telesia)
            .setColor(AGENT_RED)
            // One plain line that says what matters ("Your image is ready"). No big custom card.
            .setContentTitle(line)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setGroup("telesia_tasks")
            .setCategory(Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(openIntent(ctx, payload, id))
        // On the lock screen show only the brand, never what the task was about.
        b.setPublicVersion(
            builder(ctx, TASKS)
                .setSmallIcon(R.drawable.ic_stat_telesia)
                .setColor(0xFF17150F.toInt())
                .setContentTitle("Telesia")
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
            .setSmallIcon(R.drawable.ic_stat_telesia)
            .setColor(0xFF17150F.toInt())
            .setContentTitle(name)
            .setContentText(if (line.isEmpty()) "Calling you" else line)
            .setCategory(Notification.CATEGORY_CALL)
            .setPriority(Notification.PRIORITY_MAX)
            .setOngoing(true)
            .setAutoCancel(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(ringing)
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(ctx, R.drawable.ic_stat_telesia), "Decline", decline).build())
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(ctx, R.drawable.ic_stat_telesia), "Answer", answer).build())
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

    /** Nobody answered: the ringing stops and a calm "Missed call" stays, even if Telesia itself was stopped. */
    fun missed(ctx: Context, id: Int, botId: String, name: String, reason: String) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try { nm.cancel(id) } catch (_: Throwable) {}
        bot(ctx, id + 1000, name, if (reason.isBlank()) "Missed call" else "Missed call. $reason", "botchat/$botId")
    }

    /** A bot's message: its name, then one or two lines of what it has for the user. [reply] adds an inline Reply field. */
    fun bot(ctx: Context, id: Int, name: String, body: String, payload: String, reply: Boolean = false) {
        from(ctx, id, BOTS, name, body, payload, reply, "", 0, false)
    }

    /** The inline Reply field: the typed text goes to AlarmReceiver ("reply_to" = the payload), even with Telesia closed. */
    private fun replyAction(ctx: Context, id: Int, payload: String, name: String): Notification.Action {
        val input = android.app.RemoteInput.Builder("reply_text").setLabel("Reply to $name").build()
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        else PendingIntent.FLAG_UPDATE_CURRENT
        val pi = PendingIntent.getBroadcast(
            ctx, id + 50_000,
            Intent(ctx, AlarmReceiver::class.java).putExtra("reply_to", payload).putExtra("note", id).putExtra("name", name),
            flags
        )
        return Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(ctx, R.drawable.ic_stat_telesia), "Reply", pi)
            .addRemoteInput(input).build()
    }

    /** A round face for a bot: its first letter on its avatar colour. Null when there is none (the agent). */
    private fun face(initial: String, color: Int): android.graphics.drawable.Icon? {
        if (initial.isEmpty() || color == 0) return null
        return try {
            val size = 128
            val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
            val canvas = android.graphics.Canvas(bmp)
            val p = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
            p.color = color
            canvas.drawCircle(size / 2f, size / 2f, size / 2f, p)
            val lum = (android.graphics.Color.red(color) * 299 + android.graphics.Color.green(color) * 587 +
                android.graphics.Color.blue(color) * 114) / 1000
            p.color = if (lum > 160) 0xFF1B1A18.toInt() else 0xFFFBF8F2.toInt()
            p.textSize = size * 0.46f
            p.textAlign = android.graphics.Paint.Align.CENTER
            p.typeface = android.graphics.Typeface.create(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD)
            val y = size / 2f - (p.descent() + p.ascent()) / 2f
            canvas.drawText(initial, size / 2f, y, p)
            android.graphics.drawable.Icon.createWithBitmap(bmp)
        } catch (_: Throwable) {
            null
        }
    }

    private fun post(ctx: Context, id: Int, n: Notification) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            nm.notify(id, n)
        } catch (_: SecurityException) {
        }
    }

    /**
     * A result or a message from the agent ([channel] AGENT: "Telesia", red) or a bot (BOTS: its name, its face).
     * [body] is the short summary Dart made (1 to 3 lines). [high]: it needs the owner (the pop-up channel).
     */
    fun from(
        ctx: Context, id: Int, channel: String, title: String, body: String, payload: String,
        reply: Boolean, initial: String, color: Int, high: Boolean
    ) {
        ensureChannels(ctx)
        val agent = channel == AGENT
        var text = body.trim()
        if (text.length > 300) text = text.substring(0, 298).trimEnd() + "…"
        var first = text
        val nl = text.indexOf('\n')
        if (nl > 0) first = text.substring(0, nl).trim()
        val ch = if (high) ASKS else channel
        val accent = if (agent) AGENT_RED else if (color != 0) color else INK
        val name = if (title.isBlank()) "Telesia" else title
        val b = builder(ctx, ch)
            .setSmallIcon(R.drawable.ic_stat_telesia)
            .setColor(accent)
            .setContentTitle(name)
            .setContentText(first)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setShowWhen(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setGroup(if (agent) "telesia_agent" else "telesia_bots")
            .setContentIntent(openIntent(ctx, payload, id))
        val icon = face(initial, color)
        if (icon != null) b.setLargeIcon(icon)
        if (reply && payload.isNotEmpty()) b.addAction(replyAction(ctx, id, payload, name))
        b.setPublicVersion(
            builder(ctx, ch).setSmallIcon(R.drawable.ic_stat_telesia).setColor(accent)
                .setContentTitle(name).setContentText(if (agent) "Something is ready for you." else "New message").build()
        )
        post(ctx, id, b.build())
    }

    private fun clean(s: String): String = s.replace('\u001E', ' ').replace('\u001F', ' ').trim()

    /** The last few lines of a team's conversation: sender, text, time, initial, colour. */
    private fun teamRows(ctx: Context, teamId: String): ArrayList<List<String>> {
        val raw = ctx.getSharedPreferences(TEAM_PREFS, Context.MODE_PRIVATE).getString("t_" + teamId, "") ?: ""
        val out = ArrayList<List<String>>()
        if (raw.isEmpty()) return out
        for (e in raw.split('\u001E')) {
            val f = e.split('\u001F')
            if (f.size >= 5) out.add(f)
        }
        return out
    }

    private fun saveTeamRows(ctx: Context, teamId: String, rows: List<List<String>>) {
        val raw = rows.joinToString("\u001E") { it.joinToString("\u001F") }
        ctx.getSharedPreferences(TEAM_PREFS, Context.MODE_PRIVATE).edit().putString("t_" + teamId, raw).apply()
    }

    @Suppress("DEPRECATION")
    private fun teamStyle(team: String, rows: List<List<String>>): Notification.MessagingStyle {
        val style = if (Build.VERSION.SDK_INT >= 28) {
            Notification.MessagingStyle(android.app.Person.Builder().setName("You").build())
        } else {
            Notification.MessagingStyle("You")
        }
        style.setConversationTitle(team)
        if (Build.VERSION.SDK_INT >= 28) style.setGroupConversation(true)
        for (r in rows) {
            val at = r[2].toLongOrNull() ?: System.currentTimeMillis()
            val own = r[0] == ME
            if (Build.VERSION.SDK_INT >= 28) {
                var person: android.app.Person? = null
                if (!own) {
                    val pb = android.app.Person.Builder().setName(r[0]).setKey(r[0])
                    val ic = face(r[3], r[4].toIntOrNull() ?: 0)
                    if (ic != null) pb.setIcon(ic)
                    person = pb.build()
                }
                style.addMessage(Notification.MessagingStyle.Message(r[1], at, person))
            } else {
                style.addMessage(r[1], at, if (own) null else r[0])
            }
        }
        return style
    }

    /**
     * A team chat post: one notification per team (titled with the team's name), the latest lines as a conversation
     * ("Nova: the draft is ready"), an inline Reply that posts to the team chat. [needs]: a "[needs you]" post pops up.
     * [own]: the owner's reply from the notification, shown in the conversation without a sound.
     */
    fun team(
        ctx: Context, id: Int, teamId: String, team: String, sender: String, text: String,
        initial: String, color: Int, needs: Boolean, own: Boolean = false
    ) {
        ensureChannels(ctx)
        val rows = teamRows(ctx, teamId)
        rows.add(listOf(if (own) ME else clean(sender), clean(text), System.currentTimeMillis().toString(), clean(initial), color.toString()))
        val keep: List<List<String>> = if (rows.size > 6) ArrayList(rows.subList(rows.size - 6, rows.size)) else rows
        saveTeamRows(ctx, teamId, keep)
        val name = if (team.isBlank()) "Team" else team
        val payload = "office/" + teamId
        val line = if (own) "You: " + clean(text) else clean(sender) + ": " + clean(text)
        val b = builder(ctx, if (needs) TEAMS_NEEDS else TEAMS)
            .setSmallIcon(R.drawable.ic_stat_telesia)
            .setColor(INK)
            .setContentTitle(name)
            .setContentText(line)
            .setStyle(teamStyle(name, keep))
            .setOnlyAlertOnce(own)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setGroup("telesia_team_" + teamId)
            .setContentIntent(openIntent(ctx, payload, id))
            .addAction(replyAction(ctx, id, payload, name))
        b.setPublicVersion(
            builder(ctx, TEAMS).setSmallIcon(R.drawable.ic_stat_telesia).setColor(INK)
                .setContentTitle(name).setContentText(if (needs) "Needs you" else "New message").build()
        )
        post(ctx, id, b.build())
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
            .setSmallIcon(R.drawable.ic_stat_telesia)
            .setColor(0xFF17150F.toInt())
            .setContentTitle(name)
            .setContentText(line)
            .setStyle(Notification.BigTextStyle().bigText(if (more.isEmpty()) line else "$line\n$more"))
            .setAutoCancel(true)
            .setShowWhen(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(openIntent(ctx, "approvals", id))
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(ctx, R.drawable.ic_stat_telesia), "Not now", act(false)).build())
            .addAction(Notification.Action.Builder(android.graphics.drawable.Icon.createWithResource(ctx, R.drawable.ic_stat_telesia), "Approve", act(true)).build())
        b.setPublicVersion(
            builder(ctx, BOTS).setSmallIcon(R.drawable.ic_stat_telesia).setColor(0xFF17150F.toInt())
                .setContentTitle(name).setContentText("Needs your OK").build()
        )
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            nm.notify(id, b.build())
        } catch (_: SecurityException) {
        }
    }

    /**
     * After an inline reply. A team: the owner's line joins the team's conversation (the answers follow as new posts).
     * A bot or Telesia: the notification shows "You: <text>" for a moment, then goes; the answer comes as a new one.
     */
    fun replied(ctx: Context, id: Int, name: String, text: String = "", to: String = "") {
        ensureChannels(ctx)
        if (to.startsWith("office/") && text.isNotEmpty()) {
            team(ctx, id, to.substring(7), name, "", text, "", 0, false, true)
            return
        }
        val agent = name == "Telesia"
        val b = builder(ctx, if (agent) AGENT else BOTS)
            .setSmallIcon(R.drawable.ic_stat_telesia)
            .setColor(if (agent) AGENT_RED else INK)
            .setContentTitle(name)
            .setContentText(if (text.isEmpty()) "Sent" else "You: " + clean(text))
            .setSubText("Sent")
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
        if (Build.VERSION.SDK_INT >= 26) b.setTimeoutAfter(4_000)
        post(ctx, id, b.build())
    }

    /** Back in the app: clear the result notifications (never the running-task or wake-word ones). */
    fun clearTasks(ctx: Context) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                for (s in nm.activeNotifications) {
                    val ch = s.notification.channelId
                    if (ch == TASKS || ch == QUIET || ch == BOTS || ch == TEAMS || ch == TEAMS_NEEDS) nm.cancel(s.tag, s.id)
                }
            }
        } catch (_: Throwable) {}
        // The team conversations start over: what was in them is on screen now.
        try { ctx.getSharedPreferences(TEAM_PREFS, Context.MODE_PRIVATE).edit().clear().apply() } catch (_: Throwable) {}
    }
}
