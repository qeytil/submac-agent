package com.submac.agent

import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

/** Keeps the latest notifications (on the phone only) so SubMac can answer "what did I miss?". */
class NotifListener : NotificationListenerService() {
    companion object {
        private val recent = ArrayDeque<JSONObject>()
        private const val MAX = 150

        fun enabled(ctx: Context): Boolean {
            val flat = Settings.Secure.getString(ctx.contentResolver, "enabled_notification_listeners") ?: return false
            return flat.contains(ComponentName(ctx, NotifListener::class.java).flattenToString()) || flat.contains(ctx.packageName + "/")
        }

        @Synchronized fun list(ctx: Context, limit: Int, query: String, app: String): String {
            val out = JSONArray()
            val q = query.lowercase()
            val a = app.lowercase()
            for (o in recent.reversed()) {
                if (out.length() >= limit) break
                val text = (o.optString("title") + " " + o.optString("text")).lowercase()
                if (q.isNotEmpty() && !text.contains(q)) continue
                if (a.isNotEmpty() && !o.optString("app").lowercase().contains(a) && !o.optString("pkg").lowercase().contains(a)) continue
                out.put(o)
            }
            return out.toString()
        }

        @Synchronized private fun add(o: JSONObject) {
            // Replace an update of the same notification instead of keeping both.
            recent.removeAll { it.optString("key") == o.optString("key") && it.optString("text") == o.optString("text") }
            recent.addLast(o)
            while (recent.size > MAX) recent.removeFirst()
        }
    }

    /** A bot asked to be told about notifications like this one (at most once per 10 minutes per watch). */
    private fun botWatch(pkg: String, app: String, title: String, text: String, chat: String = "") {
        try {
            val prefs = getSharedPreferences("submac_bots", Context.MODE_PRIVATE)
            val arr = JSONArray(prefs.getString("watches", "[]") ?: "[]")
            if (arr.length() == 0) return
            val hay = (title + " " + text).lowercase()
            val now = System.currentTimeMillis()
            for (i in 0 until arr.length()) {
                val w = arr.getJSONObject(i)
                val wa = w.optString("app").lowercase()
                val kw = w.optString("kw").lowercase()
                if (wa.isNotEmpty() && !app.lowercase().contains(wa) && !pkg.lowercase().contains(wa)) continue
                if (kw.isNotEmpty() && !hay.contains(kw)) continue
                // A WhatsApp watch can name a chat or contact: only that chat wakes the bot.
                val wc = w.optString("chat").lowercase()
                if (wc.isNotEmpty() && !(chat.ifEmpty { title }).lowercase().contains(wc)) continue
                // WhatsApp watches wake per chat at most every 2 minutes (customers write in bursts); others every 10.
                val key = "last_" + w.optString("bot") + "_" + w.optString("id") + (if (chat.isNotEmpty()) "_" + chat.lowercase().hashCode() else "")
                val gap = if (chat.isNotEmpty()) 2 * 60_000L else 10 * 60_000L
                if (now - prefs.getLong(key, 0L) < gap) continue
                prefs.edit().putLong(key, now).apply()
                val e = JSONObject().apply {
                    put("bot", w.optString("bot")); put("id", w.optString("id"))
                    put("app", app); put("title", title.take(200)); put("text", text.take(500))
                    if (chat.isNotEmpty()) { put("chat", chat.take(120)); put("pkg", pkg) }
                }
                TaskService.start(this, "A bot is looking at a notification")
                Bridge.send("notifEvent", e.toString())
            }
        } catch (_: Throwable) {}
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            if (sbn.packageName == packageName) return
            val n = sbn.notification ?: return
            if ((n.flags and android.app.Notification.FLAG_ONGOING_EVENT) != 0) return
            val ex = n.extras
            val title = ex.getCharSequence(android.app.Notification.EXTRA_TITLE)?.toString() ?: ""
            val text = (ex.getCharSequence(android.app.Notification.EXTRA_BIG_TEXT)
                ?: ex.getCharSequence(android.app.Notification.EXTRA_TEXT))?.toString() ?: ""
            if (title.isBlank() && text.isBlank()) return
            val label = try {
                packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
            } catch (_: Exception) { sbn.packageName }
            add(JSONObject().apply {
                put("key", sbn.key)
                put("pkg", sbn.packageName)
                put("app", label)
                put("title", title.take(200))
                put("text", text.take(600))
                put("time", sbn.postTime)
            })
            if (WhatsApp.isWa(sbn.packageName)) {
                // WhatsApp: kept per chat in SubMac's phone-only store; watches see the new message itself.
                if (!WhatsApp.capturing(this)) {
                    botWatch(sbn.packageName, label, title, text)
                } else {
                    val got = try { WhatsApp.capture(this, sbn) } catch (_: Throwable) { null }
                    if (got != null) botWatch(sbn.packageName, label, got.first, got.second, got.first)
                }
            } else {
                botWatch(sbn.packageName, label, title, text)
            }
        } catch (_: Throwable) {}
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        try { if (WhatsApp.isWa(sbn.packageName)) WhatsApp.removed(this, sbn) } catch (_: Throwable) {}
    }
}
