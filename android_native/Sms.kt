package com.telesia.app

import android.content.Context
import android.net.Uri

/** Reads text messages (only after the user allows "Read SMS" in Advanced > System permissions). */
object Sms {
    fun read(ctx: Context, limit: Int, query: String, box: String): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val uri = Uri.parse(
            when (box) {
                "sent" -> "content://sms/sent"
                "all" -> "content://sms"
                else -> "content://sms/inbox"
            }
        )
        val q = query.trim().lowercase()
        ctx.contentResolver.query(uri, arrayOf("address", "body", "date", "type", "read"), null, null, "date DESC")?.use { c ->
            val ia = c.getColumnIndex("address")
            val ib = c.getColumnIndex("body")
            val id = c.getColumnIndex("date")
            val it = c.getColumnIndex("type")
            val ir = c.getColumnIndex("read")
            var scanned = 0
            while (c.moveToNext() && out.size < limit.coerceIn(1, 200) && scanned < 3000) {
                scanned++
                val from = if (ia >= 0) c.getString(ia) ?: "" else ""
                val body = if (ib >= 0) c.getString(ib) ?: "" else ""
                if (q.isNotEmpty() && !from.lowercase().contains(q) && !body.lowercase().contains(q)) continue
                out.add(
                    mapOf(
                        "from" to from,
                        "body" to body,
                        "date" to (if (id >= 0) c.getLong(id) else 0L),
                        "sent" to (it >= 0 && c.getInt(it) == 2),
                        "read" to (ir >= 0 && c.getInt(ir) == 1)
                    )
                )
            }
        }
        return out
    }
}
