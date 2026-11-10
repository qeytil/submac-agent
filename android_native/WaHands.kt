package com.telesia.app

import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * Presses WhatsApp's own buttons through phone control, only for an action the user asked for (and approved).
 * Lookups are resilient: WhatsApp's view ids first (com.whatsapp:id/send ...), then content descriptions in
 * several languages, then visible text. Every action checks the result and answers in JSON:
 * {"ok": bool, "state": "...", "detail": "..."}; "ok": false always says what the user can do instead.
 *
 * Runs on Bridge's phone-control worker thread (never the main thread).
 */
class WaHands(private val a: TelesiaA11y) {
    companion object {
        // Words WhatsApp uses for these buttons (content descriptions), lowercased. English first.
        val SEND = listOf("send", "إرسال", "ارسال", "envoyer", "enviar", "senden", "gönder", "kirim", "invia", "отправить", "verzenden", "wysłij", "भेजें", "ارسال کریں", "dir", "tuma")
        val SEARCH = listOf("search", "بحث", "rechercher", "buscar", "pesquisar", "suchen", "ara", "cari", "cerca", "поиск", "zoeken", "raadi", "tafuta")
        val VOICE = listOf("voice call", "audio call", "مكالمة صوتية", "appel vocal", "llamada de voz", "chamada de voz", "sprachanruf", "sesli arama", "panggilan suara", "chiamata vocale", "аудиозвонок", "simu ya sauti", "wac cod")
        val VIDEO = listOf("video call", "مكالمة فيديو", "appel vidéo", "videollamada", "chamada de vídeo", "videoanruf", "görüntülü arama", "panggilan video", "videochiamata", "видеозвонок", "simu ya video", "wac muuqaal")
        val CALL_OK = listOf("call", "اتصال", "appeler", "llamar", "ligar", "anrufen", "ara", "panggil", "chiama", "позвонить", "piga", "wac")
        val PENDING = listOf("pending", "قيد الانتظار", "en attente", "pendiente", "ausstehend", "beklemede", "tertunda")
    }

    private fun res(ok: Boolean, state: String, detail: String = "") =
        JSONObject().apply { put("ok", ok); put("state", state); if (detail.isNotEmpty()) put("detail", detail) }.toString()

    // ------------------------------------------------------------------ finding things

    private fun root(pkg: String): AccessibilityNodeInfo? {
        val r = a.appRoot() ?: return null
        val p = try { r.packageName?.toString() ?: "" } catch (_: Throwable) { "" }
        return if (p == pkg) r else null
    }

    private fun visible(n: AccessibilityNodeInfo) = try { n.isVisibleToUser } catch (_: Throwable) { false }

    private fun byId(root: AccessibilityNodeInfo, pkg: String, vararg ids: String): AccessibilityNodeInfo? {
        for (id in ids) {
            for (p in linkedSetOf(pkg, WhatsApp.PERSONAL)) {
                val l = try { root.findAccessibilityNodeInfosByViewId("$p:id/$id") } catch (_: Throwable) { null }
                l?.firstOrNull { visible(it) }?.let { return it }
            }
        }
        return null
    }

    private fun allById(root: AccessibilityNodeInfo, pkg: String, id: String): List<AccessibilityNodeInfo> {
        for (p in linkedSetOf(pkg, WhatsApp.PERSONAL)) {
            val l = try { root.findAccessibilityNodeInfosByViewId("$p:id/$id") } catch (_: Throwable) { null }
            if (!l.isNullOrEmpty()) return l.filter { visible(it) }
        }
        return emptyList()
    }

    /** A visible node whose description (or text, when [text]) matches one of [words]: exact first, then starts-with. */
    private fun byWords(root: AccessibilityNodeInfo, words: List<String>, text: Boolean = false, clickableOnly: Boolean = false): AccessibilityNodeInfo? {
        val all = ArrayList<Pair<AccessibilityNodeInfo, String>>()
        fun go(n: AccessibilityNodeInfo, d: Int) {
            if (d > 40 || all.size > 400 || !visible(n)) return
            val l = (if (text) a.desc(n) + " " + a.txt(n) else a.desc(n)).trim().lowercase()
            if (l.isNotEmpty() && (!clickableOnly || n.isClickable)) all.add(Pair(n, l))
            for (i in 0 until a.safeCount(n)) a.child(n, i)?.let { go(it, d + 1) }
        }
        go(root, 0)
        for (w in words) all.firstOrNull { it.second == w }?.let { return it.first }
        for (w in words) all.firstOrNull { it.second.startsWith(w) }?.let { return it.first }
        return null
    }

    private fun entry(root: AccessibilityNodeInfo, pkg: String): AccessibilityNodeInfo? =
        byId(root, pkg, "entry") ?: a.firstField(root, 0)

    private fun sendButton(root: AccessibilityNodeInfo, pkg: String): AccessibilityNodeInfo? =
        byId(root, pkg, "send", "send_btn", "send_button") ?: byWords(root, SEND)

    private fun inChat(root: AccessibilityNodeInfo, pkg: String) =
        byId(root, pkg, "entry", "conversation_contact_name", "conversation_contact") != null

    /** Waits up to [ms] for WhatsApp to show a screen where [ok] holds. */
    private fun waitFor(pkg: String, ms: Long, ok: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val end = SystemClock.uptimeMillis() + ms
        while (SystemClock.uptimeMillis() < end) {
            val r = root(pkg)
            if (r != null && try { ok(r) } catch (_: Throwable) { false }) return r
            SystemClock.sleep(250)
        }
        return null
    }

    fun chatTitle(pkg: String): String {
        val r = root(pkg) ?: return ""
        return byId(r, pkg, "conversation_contact_name")?.let { a.txt(it) } ?: ""
    }

    // ------------------------------------------------------------------ sending text

    /**
     * In an open chat: makes sure [text] is in the message box (types it if WhatsApp did not prefill it),
     * presses Send and checks the box emptied and the message shows. States: sent | pending (no internet, WhatsApp
     * sends it later) | unsure | not_in_chat | no_button | typed_only.
     */
    fun sendInChat(pkg: String, text: String): String = a.safe("send on WhatsApp") {
        val r = waitFor(pkg, 9000) { inChat(it, pkg) && entry(it, pkg) != null }
            ?: return@safe res(false, "not_in_chat", "WhatsApp did not open the chat (it may be loading, or the number is not on WhatsApp).")
        val e = entry(r, pkg) ?: return@safe res(false, "not_in_chat")
        val now = a.txt(e)
        if (text.isNotEmpty() && !now.contains(text.take(15).trim())) {
            if (!a.setText(e, text)) return@safe res(false, "typed_only", "Could not type into the message box.")
            SystemClock.sleep(250)
        }
        val r2 = root(pkg) ?: r
        val b = sendButton(r2, pkg)
            ?: return@safe res(false, "no_button", "The message is typed in WhatsApp but the Send button was not found. The user can tap Send.")
        if (!a.press(b)) return@safe res(false, "no_button", "The message is typed in WhatsApp; pressing Send did not work. The user can tap Send.")
        // Check: the box empties and the newest outgoing message is ours.
        val done = waitFor(pkg, 3500) { rr ->
            val ee = entry(rr, pkg)
            ee == null || a.txt(ee).isEmpty() || !a.txt(ee).contains(text.take(15).trim())
        }
        if (done == null) return@safe res(false, "unsure", "Send was pressed but the text is still in the box. Ask the user to check WhatsApp.")
        SystemClock.sleep(500)
        val rr = root(pkg) ?: done
        val shown = allById(rr, pkg, "message_text").any { a.txt(it).contains(text.take(20).trim()) } || text.isEmpty()
        val pending = allById(rr, pkg, "status").lastOrNull()?.let { s -> PENDING.any { a.desc(s).lowercase().contains(it) } } == true
        when {
            pending -> res(true, "pending", "Queued: WhatsApp will send it as soon as the phone is online.")
            shown -> res(true, "sent")
            else -> res(true, "sent", "Send was pressed and the box emptied.")
        }
    }

    // ------------------------------------------------------------------ opening a chat by name

    /** From WhatsApp's chat list: search for [name] and open the best match. States: opened | not_found | no_search. */
    fun openByName(pkg: String, name: String): String = a.safe("open the chat") {
        val home = waitFor(pkg, 8000) { r ->
            byId(r, pkg, "menuitem_search", "my_search_bar", "search_bar", "search_icon") != null || byWords(r, SEARCH) != null || inChat(r, pkg)
        } ?: return@safe res(false, "no_search", "WhatsApp did not open.")
        var r = home
        if (inChat(r, pkg)) {
            if (chatTitle(pkg).equals(name, true)) return@safe res(true, "opened", chatTitle(pkg))
            a.global("back")
            r = waitFor(pkg, 3000) { byWords(it, SEARCH) != null || byId(it, pkg, "menuitem_search", "my_search_bar", "search_bar") != null } ?: r
        }
        val s = byId(r, pkg, "menuitem_search", "my_search_bar", "search_bar", "search_icon") ?: byWords(r, SEARCH)
            ?: return@safe res(false, "no_search", "WhatsApp's search was not found.")
        a.press(s)
        val field = waitFor(pkg, 3000) { rr -> byId(rr, pkg, "search_input", "search_src_text") != null || a.firstField(rr, 0) != null }
            ?.let { rr -> byId(rr, pkg, "search_input", "search_src_text") ?: a.firstField(rr, 0) }
            ?: return@safe res(false, "no_search", "WhatsApp's search box did not open.")
        a.setText(field, name)
        SystemClock.sleep(1300)
        val rr = root(pkg) ?: return@safe res(false, "not_found")
        val q = name.trim().lowercase()
        val rows = allById(rr, pkg, "conversations_row_contact_name") + allById(rr, pkg, "contactpicker_row_name")
        val hit = rows.firstOrNull { a.txt(it).lowercase() == q }
            ?: rows.firstOrNull { a.txt(it).lowercase().startsWith(q) }
            ?: rows.firstOrNull { a.txt(it).lowercase().contains(q) }
            ?: run {
                // Fallback: any visible text equal to the name that is not the search box itself.
                var best: AccessibilityNodeInfo? = null
                fun go(n: AccessibilityNodeInfo, d: Int) {
                    if (d > 40 || best != null || !visible(n)) return
                    if (!n.isEditable && a.txt(n).lowercase() == q) { best = n; return }
                    for (i in 0 until a.safeCount(n)) a.child(n, i)?.let { go(it, d + 1) }
                }
                go(rr, 0)
                best
            }
            ?: return@safe res(false, "not_found", "No chat called \"$name\" in WhatsApp search.")
        val label = a.txt(hit)
        a.press(hit)
        val opened = waitFor(pkg, 5000) { inChat(it, pkg) }
            ?: return@safe res(false, "not_found", "Tapped \"$label\" but the chat did not open.")
        res(true, "opened", byId(opened, pkg, "conversation_contact_name")?.let { a.txt(it) } ?: label)
    }

    // ------------------------------------------------------------------ reading a chat

    /** Reads the open chat: messages on screen, after scrolling up [pages] times (0-3) for older ones. */
    fun readChat(pkg: String, pages: Int): String = a.safe("read the chat") {
        val r0 = waitFor(pkg, 6000) { inChat(it, pkg) } ?: return@safe res(false, "not_in_chat", "No WhatsApp chat is open.")
        val title = byId(r0, pkg, "conversation_contact_name")?.let { a.txt(it) } ?: ""
        val sub = byId(r0, pkg, "conversation_contact_status")?.let { a.txt(it) } ?: ""
        val seen = LinkedHashMap<String, JSONObject>()
        val batches = ArrayList<List<JSONObject>>()
        val w = a.resources.displayMetrics.widthPixels
        fun grab() {
            val r = root(pkg) ?: return
            val list = a.mainScrollable(r, false) ?: r
            val out = ArrayList<JSONObject>()
            for (i in 0 until a.safeCount(list)) {
                val row = a.child(list, i) ?: continue
                if (!visible(row)) continue
                val texts = ArrayList<String>()
                var time = ""; var sender = ""; var status = ""; var media = ""
                var bubble: android.graphics.Rect? = null
                fun go(n: AccessibilityNodeInfo, d: Int) {
                    if (d > 20) return
                    val id = try { (n.viewIdResourceName ?: "").substringAfterLast('/') } catch (_: Throwable) { "" }
                    val t = a.txt(n)
                    when (id) {
                        "message_text", "caption" -> if (t.isNotEmpty()) { texts.add(t); bubble = a.bounds(n) }
                        "date" -> time = t
                        "name_in_group_tv", "name_in_group" -> sender = t
                        "status" -> status = a.desc(n)
                        else -> if (media.isEmpty() && a.desc(n).isNotEmpty() && id.isNotEmpty() && n.isClickable) media = a.desc(n)
                    }
                    for (k in 0 until a.safeCount(n)) a.child(n, k)?.let { go(it, d + 1) }
                }
                go(row, 0)
                val rb = bubble ?: a.bounds(row)
                val text = texts.joinToString("\n").ifEmpty { media.ifEmpty { a.label(row) } }
                if (text.isEmpty()) continue
                val out1 = if (bubble != null) (rb.left - 0) > (w - rb.right) else status.isNotEmpty()
                out.add(JSONObject().apply {
                    put("text", text.take(1500)); put("time", time)
                    put("from", if (out1) "You" else sender.ifEmpty { if (texts.isEmpty()) "" else title })
                    put("me", out1)
                    if (status.isNotEmpty()) put("status", status)
                    if (texts.isEmpty()) put("kind", "other")
                })
            }
            batches.add(out)
        }
        grab()
        for (p in 0 until pages.coerceIn(0, 3)) {
            a.scroll("up", -1, "page")
            SystemClock.sleep(400)
            grab()
        }
        // Oldest batch first, rows in screen order, duplicates dropped.
        for (b in batches.reversed()) for (m in b) {
            val k = m.optString("text") + "|" + m.optString("time")
            if (!seen.containsKey(k)) seen[k] = m
        }
        val arr = JSONArray()
        seen.values.forEach { arr.put(it) }
        JSONObject().apply { put("ok", true); put("state", "read"); put("chat", title); put("status", sub); put("messages", arr) }.toString()
    }

    // ------------------------------------------------------------------ calls

    /** In an open chat: starts a voice or video call and confirms WhatsApp's "Start call?" question. */
    fun call(pkg: String, video: Boolean): String = a.safe("start the call") {
        val r = waitFor(pkg, 6000) { inChat(it, pkg) } ?: return@safe res(false, "not_in_chat", "No WhatsApp chat is open.")
        val b = (if (video) byId(r, pkg, "menuitem_video_call", "video_call", "video_call_btn") else byId(r, pkg, "menuitem_voice_call", "voice_call", "audio_call", "voice_call_btn"))
            ?: byWords(r, if (video) VIDEO else VOICE)
            ?: return@safe res(false, "no_button", "The ${if (video) "video" else "voice"} call button was not found in this chat.")
        if (!a.press(b)) return@safe res(false, "no_button", "Pressing the call button did not work.")
        SystemClock.sleep(1200)
        // WhatsApp may ask "Start voice call?" first.
        root(pkg)?.let { rr ->
            val ok = (try { rr.findAccessibilityNodeInfosByViewId("android:id/button1").firstOrNull { visible(it) } } catch (_: Throwable) { null })
                ?: byWords(rr, CALL_OK, text = true, clickableOnly = true)
            if (ok != null && !inChat(rr, pkg)) a.press(ok)
        }
        SystemClock.sleep(1500)
        val rr = a.appRoot()
        val p = try { rr?.packageName?.toString() ?: "" } catch (_: Throwable) { "" }
        if (p == pkg && rr != null && !inChat(rr, pkg)) res(true, "calling") else res(true, "pressed", "Call button pressed; check the phone screen.")
    }

    // ------------------------------------------------------------------ sharing a file

    /**
     * After a share intent: picks the chat when WhatsApp shows its picker ([name]), then presses Send on the
     * preview. States: sent | not_found | no_button | unsure.
     */
    fun shareSend(pkg: String, name: String): String = a.safe("send the file") {
        var picked = false
        for (step in 0 until 4) {
            val r = waitFor(pkg, 8000) { rr ->
                sendButton(rr, pkg) != null || byId(rr, pkg, "contactpicker_row_name", "menuitem_search", "search_bar") != null || inChat(rr, pkg)
            } ?: return@safe res(false, "unsure", "WhatsApp did not show the send screen.")
            val isPicker = byId(r, pkg, "contactpicker_row_name") != null || (!picked && name.isNotEmpty() && byId(r, pkg, "caption", "media_caption") == null && byId(r, pkg, "entry") == null && byWords(r, SEARCH) != null)
            if (isPicker && !picked) {
                if (name.isEmpty()) return@safe res(false, "not_found", "WhatsApp is asking which chat to send to. Say the chat name.")
                val s = byId(r, pkg, "menuitem_search", "search_bar") ?: byWords(r, SEARCH)
                if (s != null) {
                    a.press(s)
                    SystemClock.sleep(700)
                    root(pkg)?.let { rr -> (byId(rr, pkg, "search_src_text", "search_input") ?: a.firstField(rr, 0))?.let { a.setText(it, name) } }
                    SystemClock.sleep(1200)
                }
                val rr = root(pkg) ?: return@safe res(false, "not_found")
                val q = name.trim().lowercase()
                val rows = allById(rr, pkg, "contactpicker_row_name")
                val hit = rows.firstOrNull { a.txt(it).lowercase() == q } ?: rows.firstOrNull { a.txt(it).lowercase().contains(q) }
                    ?: return@safe res(false, "not_found", "No chat called \"$name\" in WhatsApp's list.")
                a.press(hit)
                picked = true
                SystemClock.sleep(600)
                // The picker's own send arrow.
                root(pkg)?.let { r2 -> sendButton(r2, pkg)?.let { a.press(it) } }
                SystemClock.sleep(1200)
                continue
            }
            if (inChat(r, pkg) && sendButton(r, pkg) == null) return@safe res(true, "sent")
            val b = sendButton(r, pkg) ?: return@safe res(false, "no_button", "WhatsApp's Send button was not found; the user can tap Send.")
            if (!a.press(b)) return@safe res(false, "no_button", "Pressing Send did not work; the user can tap Send.")
            SystemClock.sleep(1500)
            val after = root(pkg)
            if (after == null || inChat(after, pkg) || sendButton(after, pkg) == null) return@safe res(true, "sent")
        }
        res(false, "unsure", "Send was pressed; ask the user to check WhatsApp.")
    }
}
