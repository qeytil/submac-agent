package com.telesia.app

import android.app.KeyguardManager
import android.app.Notification
import android.app.RemoteInput
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.notification.StatusBarNotification
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * WhatsApp and WhatsApp Business on the user's own phone (no WhatsApp Web, no unofficial client, no Meta API).
 *
 * - Incoming messages come from WhatsApp's own notifications (notification access) and are kept in a small
 *   phone-only store: the newest [PER_CHAT] per chat, for [KEEP_MS] (7 days). It lives in the app's private
 *   files and is never synced anywhere.
 * - Quick reply uses the notification's own Reply action (RemoteInput) while that notification is still showing.
 * - Opening a chat, sharing a file and starting a call use WhatsApp's public intents; pressing Send / Call is
 *   done by [WaHands] through phone control (accessibility), only when the user asked for it.
 */
object WhatsApp {
    const val PERSONAL = "com.whatsapp"
    const val BUSINESS = "com.whatsapp.w4b"
    val PKGS = setOf(PERSONAL, BUSINESS)
    private const val KEEP_MS = 7L * 24 * 3600 * 1000
    private const val PER_CHAT = 40
    private const val MAX_CHATS = 150
    private const val FILE = "wa_chats.json"

    /** chat key -> {key, pkg, name, group, phone, unread, last, msgs:[{f, t, at, me}]} */
    private val chats = LinkedHashMap<String, JSONObject>()
    /** chat key -> the live notification's Reply action. In memory only: it dies with the notification. */
    private val replies = HashMap<String, Notification.Action>()
    private var loaded = false
    private val io = Executors.newSingleThreadExecutor()

    fun isWa(pkg: String?) = pkg != null && pkg in PKGS
    fun appName(pkg: String) = if (pkg == BUSINESS) "WhatsApp Business" else "WhatsApp"

    private fun prefs(ctx: Context) = ctx.getSharedPreferences("telesia_wa", Context.MODE_PRIVATE)
    fun capturing(ctx: Context) = prefs(ctx).getBoolean("capture", true)
    fun setCapturing(ctx: Context, on: Boolean) {
        prefs(ctx).edit().putBoolean("capture", on).apply()
        if (!on) clear(ctx)
    }

    fun installed(ctx: Context, pkg: String): Boolean = try {
        ctx.packageManager.getPackageInfo(pkg, 0); true
    } catch (_: Throwable) { false }

    fun locked(ctx: Context): Boolean = try {
        (ctx.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
    } catch (_: Throwable) { false }

    // ------------------------------------------------------------------ store

    @Synchronized private fun load(ctx: Context) {
        if (loaded) return
        loaded = true
        try {
            val f = File(ctx.filesDir, FILE)
            if (!f.exists()) return
            val arr = JSONArray(f.readText())
            for (i in 0 until arr.length()) {
                val c = arr.getJSONObject(i)
                chats[c.optString("key")] = c
            }
            expire()
        } catch (_: Throwable) {}
    }

    private fun expire() {
        val cut = System.currentTimeMillis() - KEEP_MS
        val it = chats.entries.iterator()
        while (it.hasNext()) {
            val c = it.next().value
            val msgs = c.optJSONArray("msgs") ?: JSONArray()
            val keep = JSONArray()
            for (i in 0 until msgs.length()) {
                val m = msgs.getJSONObject(i)
                if (m.optLong("at") >= cut) keep.put(m)
            }
            c.put("msgs", keep)
            if (keep.length() == 0 && c.optLong("last") < cut) it.remove()
        }
    }

    private fun save(ctx: Context) {
        val snap = synchronized(this) { JSONArray().also { a -> chats.values.forEach { a.put(it) } }.toString() }
        val dir = ctx.filesDir
        io.execute {
            try {
                val tmp = File(dir, "$FILE.tmp")
                tmp.writeText(snap)
                tmp.renameTo(File(dir, FILE))
            } catch (_: Throwable) {}
        }
    }

    @Synchronized fun clear(ctx: Context) {
        chats.clear()
        replies.clear()
        loaded = true
        try { File(ctx.filesDir, FILE).delete() } catch (_: Throwable) {}
    }

    /** "123456789@s.whatsapp.net" -> "123456789". Newer "@lid" ids are not phone numbers and give "". */
    fun phoneOf(jid: String): String = Regex("^(\\d{6,15})@s\\.whatsapp\\.net$").find(jid)?.groupValues?.get(1) ?: ""

    /** "Ali (3 messages)" -> "Ali"; "Family: Amina" (old group style) -> group "Family", sender "Amina". */
    private fun cleanTitle(t: String) = t.replace(Regex("\\s*\\(\\d+\\s+\\S+\\)\\s*$"), "").trim()

    private fun chatKey(pkg: String, jid: String, name: String) = pkg + "|" + (if (jid.contains('@')) jid else name.lowercase())

    /**
     * Takes one WhatsApp notification into the store. Returns (chat name, newest new incoming text) when it
     * brought a new message from someone else (for bot watches), else null.
     */
    fun capture(ctx: Context, sbn: StatusBarNotification): Pair<String, String>? {
        val n = sbn.notification ?: return null
        if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return null
        val ex = n.extras ?: return null
        val pkg = sbn.packageName
        val rawTitle = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val conv = ex.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString() ?: ""
        val jid = (if (Build.VERSION.SDK_INT >= 26) n.shortcutId else null) ?: sbn.tag ?: ""
        var group = jid.endsWith("@g.us") || (Build.VERSION.SDK_INT >= 28 && ex.getBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION))
        val title = cleanTitle(rawTitle)
        // WhatsApp's own status notifications ("Checking for new messages", backups) carry no chat.
        if (title.isEmpty() || (title.equals("WhatsApp", true) || title.equals("WhatsApp Business", true)) && conv.isEmpty()) return null

        // The messages in the notification (MessagingStyle), oldest first.
        val found = ArrayList<JSONObject>()
        try {
            @Suppress("DEPRECATION")
            val arr = ex.getParcelableArray(Notification.EXTRA_MESSAGES)
            if (arr != null) for (p in arr) {
                val b = p as? Bundle ?: continue
                val text = b.getCharSequence("text")?.toString() ?: continue
                var sender = b.getCharSequence("sender")?.toString()
                if (sender == null && Build.VERSION.SDK_INT >= 28) {
                    sender = (b.get("sender_person") as? android.app.Person)?.name?.toString()
                }
                found.add(JSONObject().apply {
                    put("f", sender ?: "You"); put("t", text.take(1500)); put("at", b.getLong("time", sbn.postTime)); put("me", sender == null)
                })
            }
        } catch (_: Throwable) {}
        var name = if (group) conv.ifEmpty { title } else title
        if (found.isEmpty()) {
            val text = (ex.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: ex.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
            if (text.isBlank()) return null
            var sender = title
            // Old style group titles: "Group: Sender" or "Sender @ Group".
            if (conv.isEmpty()) {
                val c = title.indexOf(": ")
                val at = title.indexOf(" @ ")
                if (c > 0) { group = true; name = title.substring(0, c); sender = title.substring(c + 2) }
                else if (at > 0) { group = true; name = title.substring(at + 3); sender = title.substring(0, at) }
            }
            found.add(JSONObject().apply { put("f", sender); put("t", text.take(1500)); put("at", sbn.postTime); put("me", false) })
        }
        if (name.isEmpty()) return null

        synchronized(this) {
            load(ctx)
            val key = chatKey(pkg, jid, name)
            val c = chats.remove(key) ?: JSONObject().apply { put("key", key); put("msgs", JSONArray()) }
            c.put("pkg", pkg); c.put("name", name.take(120)); c.put("group", group)
            val ph = phoneOf(jid)
            if (ph.isNotEmpty()) c.put("phone", ph)
            if (jid.isNotEmpty()) c.put("jid", jid)
            val msgs = c.optJSONArray("msgs") ?: JSONArray()
            val seen = HashSet<String>()
            for (i in 0 until msgs.length()) { val m = msgs.getJSONObject(i); seen.add(m.optLong("at").toString() + m.optString("t")) }
            var newest: String? = null
            var incomingNow = 0
            for (m in found) {
                if (!m.optBoolean("me")) incomingNow++
                if (seen.add(m.optLong("at").toString() + m.optString("t"))) {
                    msgs.put(m)
                    if (!m.optBoolean("me")) newest = (if (group) m.optString("f") + ": " else "") + m.optString("t")
                }
            }
            // Keep the newest PER_CHAT, in time order.
            val list = ArrayList<JSONObject>()
            for (i in 0 until msgs.length()) list.add(msgs.getJSONObject(i))
            list.sortBy { it.optLong("at") }
            val keep = JSONArray()
            for (m in list.takeLast(PER_CHAT)) keep.put(m)
            c.put("msgs", keep)
            c.put("unread", maxOf(incomingNow, n.number))
            c.put("last", maxOf(c.optLong("last"), sbn.postTime))
            chats[key] = c
            while (chats.size > MAX_CHATS) chats.remove(chats.keys.first())
            // The Reply action, while this notification lives.
            val reply = n.actions?.firstOrNull { a ->
                a.remoteInputs?.isNotEmpty() == true &&
                    (Build.VERSION.SDK_INT < 28 || a.semanticAction == Notification.Action.SEMANTIC_ACTION_REPLY || a.semanticAction == 0)
            }
            if (reply != null) replies[key] = reply
            expire()
            save(ctx)
            val nw = newest
            return if (nw != null) Pair(name, nw) else null
        }
    }

    /** The user opened or dismissed the chat's notification: nothing is unread there now and the reply action is gone. */
    fun removed(ctx: Context, sbn: StatusBarNotification) {
        try {
            val n = sbn.notification ?: return
            if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
            val jid = (if (Build.VERSION.SDK_INT >= 26) n.shortcutId else null) ?: sbn.tag ?: ""
            val ex = n.extras
            val title = cleanTitle(ex?.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: "")
            val conv = ex?.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString() ?: ""
            synchronized(this) {
                load(ctx)
                val key = chatKey(sbn.packageName, jid, conv.ifEmpty { title })
                replies.remove(key)
                chats[key]?.let { it.put("unread", 0); save(ctx) }
            }
        } catch (_: Throwable) {}
    }

    /** Adds a message Telesia sent, so the chat history the agent sees includes it. */
    @Synchronized fun noteSent(ctx: Context, key: String, text: String) {
        load(ctx)
        val c = chats[key] ?: return
        val msgs = c.optJSONArray("msgs") ?: JSONArray()
        msgs.put(JSONObject().apply { put("f", "You"); put("t", text.take(1500)); put("at", System.currentTimeMillis()); put("me", true) })
        c.put("msgs", msgs)
        c.put("unread", 0)
        save(ctx)
    }

    /** Best chat for a name, number or key: exact key, then phone digits, then exact name, then the name containing it. */
    @Synchronized private fun find(query: String, pkg: String): JSONObject? {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return null
        val all = chats.values.filter { pkg.isEmpty() || it.optString("pkg") == pkg }.sortedByDescending { it.optLong("last") }
        all.firstOrNull { it.optString("key").lowercase() == q }?.let { return it }
        val digits = q.filter { it.isDigit() }
        if (digits.length >= 6) all.firstOrNull { it.optString("phone").isNotEmpty() && (it.optString("phone").endsWith(digits) || digits.endsWith(it.optString("phone"))) }?.let { return it }
        all.firstOrNull { it.optString("name").lowercase() == q }?.let { return it }
        return all.firstOrNull { it.optString("name").lowercase().contains(q) }
    }

    /** Chats for the inbox tool, newest first, each with its newest [perChat] messages. */
    @Synchronized fun list(ctx: Context, pkg: String, query: String, unreadOnly: Boolean, limit: Int, perChat: Int): String {
        load(ctx)
        expire()
        val q = query.trim().lowercase()
        val out = JSONArray()
        for (c in chats.values.sortedByDescending { it.optLong("last") }) {
            if (out.length() >= limit) break
            if (pkg.isNotEmpty() && c.optString("pkg") != pkg) continue
            if (unreadOnly && c.optInt("unread") <= 0) continue
            if (q.isNotEmpty() && !c.optString("name").lowercase().contains(q) && !c.optString("phone").contains(q.filter { it.isDigit() }.ifEmpty { "\u0000" })) continue
            val msgs = c.optJSONArray("msgs") ?: JSONArray()
            val tail = JSONArray()
            for (i in maxOf(0, msgs.length() - perChat) until msgs.length()) tail.put(msgs.getJSONObject(i))
            out.put(JSONObject(c.toString()).apply {
                put("msgs", tail)
                put("total", msgs.length())
                put("app", appName(c.optString("pkg")))
                put("quickReply", replies.containsKey(c.optString("key")))
            })
        }
        return out.toString()
    }

    /** Info about one chat (for name -> phone lookups before opening it). */
    @Synchronized fun chatInfo(ctx: Context, query: String, pkg: String): String {
        load(ctx)
        val c = find(query, pkg) ?: return "{}"
        return JSONObject().apply {
            put("key", c.optString("key")); put("name", c.optString("name")); put("phone", c.optString("phone"))
            put("pkg", c.optString("pkg")); put("group", c.optBoolean("group")); put("quickReply", replies.containsKey(c.optString("key")))
        }.toString()
    }

    /**
     * Replies through the chat's live notification (works on a locked screen and without opening WhatsApp).
     * Returns "sent:<chat name>", "no-live" (no notification with a Reply button right now), "none" (no such chat)
     * or "error:<why>".
     */
    fun quickReply(ctx: Context, query: String, pkg: String, text: String): String {
        val found: Pair<JSONObject, Notification.Action> = synchronized(this) {
            load(ctx)
            val c = find(query, pkg) ?: return "none"
            val a = replies[c.optString("key")] ?: return "no-live"
            Pair(c, a)
        }
        val c = found.first
        val action = found.second
        return try {
            val inputs = action.remoteInputs ?: return "no-live"
            val intent = Intent()
            val b = Bundle()
            for (ri in inputs) b.putCharSequence(ri.resultKey, text)
            RemoteInput.addResultsToIntent(inputs, intent, b)
            action.actionIntent.send(ctx, 0, intent)
            synchronized(this) { replies.remove(c.optString("key")) }
            noteSent(ctx, c.optString("key"), text)
            "sent:" + c.optString("name")
        } catch (e: Throwable) {
            synchronized(this) { replies.remove(c.optString("key")) }
            "error:" + (e.message ?: e.javaClass.simpleName)
        }
    }

    @Synchronized fun count(ctx: Context): Int { load(ctx); return chats.size }

    // ------------------------------------------------------------------ intents

    private fun starter(ctx: Context): Context = TelesiaA11y.instance ?: ctx

    /** Opens the chat with [phone] (digits with country code), with [text] typed in when given. */
    fun openChat(ctx: Context, pkg: String, phone: String, text: String): String {
        if (!installed(ctx, pkg)) return "not-installed"
        val q = "phone=" + phone + (if (text.isNotEmpty()) "&text=" + Uri.encode(text) else "")
        val tries = listOf("https://api.whatsapp.com/send?$q", "whatsapp://send?$q")
        for (u in tries) {
            try {
                val i = Intent(Intent.ACTION_VIEW, Uri.parse(u)).setPackage(pkg)
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                starter(ctx).startActivity(i)
                return "ok"
            } catch (_: Throwable) {}
        }
        return "error"
    }

    /** Opens WhatsApp on its chat list (a fresh start, so search is at hand). */
    fun openHome(ctx: Context, pkg: String): String {
        if (!installed(ctx, pkg)) return "not-installed"
        return try {
            val i = ctx.packageManager.getLaunchIntentForPackage(pkg) ?: return "error"
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            starter(ctx).startActivity(i)
            "ok"
        } catch (_: Throwable) { "error" }
    }

    /**
     * Shares a file into WhatsApp. With [phone], WhatsApp goes straight to that chat's preview; without it,
     * WhatsApp shows its chat picker. Files are served by [WaFiles] from Telesia's cache, read-only.
     */
    fun shareFile(ctx: Context, pkg: String, path: String, mime: String, phone: String, caption: String): String {
        if (!installed(ctx, pkg)) return "not-installed"
        val src = File(path)
        if (!src.exists() || !src.isFile) return "no-file"
        if (src.length() > 95L * 1024 * 1024) return "too-big"
        return try {
            val dir = File(ctx.cacheDir, "wa_share")
            dir.mkdirs()
            dir.listFiles()?.forEach { if (System.currentTimeMillis() - it.lastModified() > 24 * 3600_000L) it.delete() }
            val safe = src.name.replace(Regex("[^A-Za-z0-9._ -]"), "_").ifEmpty { "file" }
            val out = File(dir, safe)
            src.copyTo(out, overwrite = true)
            val uri = Uri.parse("content://" + WaFiles.authority(ctx) + "/" + Uri.encode(safe))
            val type = mime.ifEmpty { WaFiles.mimeOf(safe) }
            val i = Intent(Intent.ACTION_SEND).setType(type).setPackage(pkg)
            i.putExtra(Intent.EXTRA_STREAM, uri)
            if (caption.isNotEmpty()) i.putExtra(Intent.EXTRA_TEXT, caption)
            if (phone.isNotEmpty()) i.putExtra("jid", "$phone@s.whatsapp.net")
            i.clipData = ClipData.newRawUri(safe, uri)
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            starter(ctx).startActivity(i)
            "ok"
        } catch (e: Throwable) { "error:" + (e.message ?: e.javaClass.simpleName) }
    }

    /** Everything the setup screen and the status action show. */
    fun status(ctx: Context): String = JSONObject().apply {
        put("personal", installed(ctx, PERSONAL))
        put("business", installed(ctx, BUSINESS))
        put("notifRead", NotifListener.enabled(ctx))
        put("phoneControl", TelesiaA11y.instance != null)
        put("locked", locked(ctx))
        put("capture", capturing(ctx))
        put("chats", count(ctx))
    }.toString()

    fun mimeFor(path: String): String {
        val ext = path.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }
}
