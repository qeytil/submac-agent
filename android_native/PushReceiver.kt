package com.submac.agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Plan 2.1 push: every FCM message for this app also arrives here (the same broadcast the Firebase SDK and
 * firebase_messaging listen to), even when SubMac is closed. It shows the push through [Notifier], the same
 * calm notifications bot results use, so no Flutter background isolate is needed.
 *
 * Data keys (all strings): title, body, bot_id, chat_id, kind (done|scheduled|attention|info), message_id.
 * A tap opens inbox/<inbox_id> (a SubMac team message, "From SubMac"), else conv/<chat_id>, else botchat/<bot_id>, else the app.
 */
class PushReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        try {
            val x = intent.extras ?: return
            // Only real messages (not "deleted messages" or send-event broadcasts).
            val type = x.getString("message_type")
            if (type != null && type != "gcm") return
            val notifTitle = x.getString("gcm.notification.title") ?: x.getString("gcm.n.title")
            val notifBody = x.getString("gcm.notification.body") ?: x.getString("gcm.n.body")
            val hasNotificationBlock = notifTitle != null || notifBody != null || x.getString("gcm.n.e") != null
            // A message with a notification block is drawn by Firebase itself while the app is in the
            // background; only draw it here when SubMac is on screen (Firebase draws nothing then).
            if (hasNotificationBlock && !Bridge.foreground) return
            val title = (x.getString("title") ?: notifTitle ?: "").trim()
            val body = (x.getString("body") ?: notifBody ?: "").trim()
            if (title.isEmpty() && body.isEmpty()) return
            val botId = (x.getString("bot_id") ?: "").trim()
            val chatId = (x.getString("chat_id") ?: "").trim()
            val inboxId = (x.getString("inbox_id") ?: "").trim()
            val payload = when {
                inboxId.isNotEmpty() -> "inbox/$inboxId"
                x.getString("open") == "inbox" -> "inbox"
                chatId.isNotEmpty() -> "conv/$chatId"
                botId.isNotEmpty() -> "botchat/$botId"
                else -> ""
            }
            // The same message twice (FCM retry) replaces its notification instead of stacking.
            val key = x.getString("message_id") ?: x.getString("google.message_id") ?: (title + body)
            val id = 9600 + Math.floorMod(key.hashCode(), 300)
            if (botId.isNotEmpty()) {
                Notifier.bot(ctx, id, if (title.isEmpty()) "Telesia" else title, body, payload, reply = chatId.isNotEmpty())
            } else {
                val kind = when (x.getString("kind")) {
                    "done", "scheduled", "attention", "info" -> x.getString("kind")!!
                    else -> "attention"
                }
                Notifier.task(ctx, id, if (title.isEmpty()) "Telesia" else title, body, payload, kind)
            }
        } catch (_: Throwable) {
            // A bad push must never crash the app.
        }
    }
}
