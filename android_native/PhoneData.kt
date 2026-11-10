package com.telesia.app

import android.content.ContentValues
import android.content.Context
import android.provider.CalendarContract
import android.provider.ContactsContract
import java.util.TimeZone

/** Calendar and contacts on the phone (plan 4, tier A). Every account on the device, Google included; no sign-in. */
object PhoneData {
    /** Events from [fromMs] for [days] days, optionally matching [query] in title, place or notes. */
    fun events(ctx: Context, fromMs: Long, days: Int, query: String, limit: Int): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val end = fromMs + days.coerceIn(1, 366).toLong() * 86_400_000L
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also {
            android.content.ContentUris.appendId(it, fromMs)
            android.content.ContentUris.appendId(it, end)
        }.build()
        val cols = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.EVENT_LOCATION,
            CalendarContract.Instances.DESCRIPTION,
            CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
        )
        val q = query.trim().lowercase()
        ctx.contentResolver.query(uri, cols, null, null, "${CalendarContract.Instances.BEGIN} ASC")?.use { c ->
            while (c.moveToNext() && out.size < limit.coerceIn(1, 200)) {
                val title = c.getString(1) ?: ""
                val place = c.getString(5) ?: ""
                val notes = c.getString(6) ?: ""
                if (q.isNotEmpty() && !title.lowercase().contains(q) && !place.lowercase().contains(q) && !notes.lowercase().contains(q)) continue
                out.add(
                    mapOf(
                        "id" to c.getLong(0),
                        "title" to title,
                        "start" to c.getLong(2),
                        "end" to c.getLong(3),
                        "allDay" to (c.getInt(4) == 1),
                        "place" to place,
                        "notes" to (if (notes.length > 300) notes.substring(0, 300) + "…" else notes),
                        "calendar" to (c.getString(7) ?: ""),
                    )
                )
            }
        }
        return out
    }

    /** The calendar new events go into: the primary writable one, else the first writable one. */
    private fun writableCalendar(ctx: Context): Long? {
        val cols = arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.IS_PRIMARY, CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
        var first: Long? = null
        ctx.contentResolver.query(CalendarContract.Calendars.CONTENT_URI, cols, "${CalendarContract.Calendars.VISIBLE} = 1", null, null)?.use { c ->
            while (c.moveToNext()) {
                if (c.getInt(2) < CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR) continue
                val id = c.getLong(0)
                if (c.getInt(1) == 1) return id
                if (first == null) first = id
            }
        }
        return first
    }

    /** Adds an event straight into the calendar. Returns the new event id, or an error text. */
    fun addEvent(ctx: Context, title: String, startMs: Long, endMs: Long, allDay: Boolean, place: String, notes: String): String {
        val cal = writableCalendar(ctx) ?: return "error:no_calendar"
        val v = ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, cal)
            put(CalendarContract.Events.TITLE, title)
            put(CalendarContract.Events.DTSTART, startMs)
            put(CalendarContract.Events.DTEND, if (endMs > startMs) endMs else startMs + 3_600_000L)
            put(CalendarContract.Events.ALL_DAY, if (allDay) 1 else 0)
            put(CalendarContract.Events.EVENT_TIMEZONE, if (allDay) "UTC" else TimeZone.getDefault().id)
            if (place.isNotEmpty()) put(CalendarContract.Events.EVENT_LOCATION, place)
            if (notes.isNotEmpty()) put(CalendarContract.Events.DESCRIPTION, notes)
        }
        val uri = ctx.contentResolver.insert(CalendarContract.Events.CONTENT_URI, v) ?: return "error:insert_failed"
        return uri.lastPathSegment ?: "ok"
    }

    /** Contacts whose name, phone or email matches [query]. */
    fun contacts(ctx: Context, query: String, limit: Int): List<Map<String, Any?>> {
        val byId = LinkedHashMap<Long, MutableMap<String, Any?>>()
        val q = query.trim()
        val uri = if (q.isEmpty()) ContactsContract.Contacts.CONTENT_URI
        else ContactsContract.Contacts.CONTENT_FILTER_URI.buildUpon().appendPath(q).build()
        ctx.contentResolver.query(uri, arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.DISPLAY_NAME_PRIMARY), null, null,
            "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} ASC")?.use { c ->
            while (c.moveToNext() && byId.size < limit.coerceIn(1, 100)) {
                byId[c.getLong(0)] = mutableMapOf("name" to (c.getString(1) ?: ""), "phones" to ArrayList<String>(), "emails" to ArrayList<String>())
            }
        }
        if (byId.isEmpty()) return emptyList()
        val ids = byId.keys.joinToString(",")
        ctx.contentResolver.query(ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.CONTACT_ID, ContactsContract.CommonDataKinds.Phone.NUMBER),
            "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} IN ($ids)", null, null)?.use { c ->
            while (c.moveToNext()) {
                @Suppress("UNCHECKED_CAST")
                val l = byId[c.getLong(0)]?.get("phones") as? ArrayList<String> ?: continue
                val n = c.getString(1) ?: continue
                if (!l.contains(n) && l.size < 4) l.add(n)
            }
        }
        ctx.contentResolver.query(ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Email.CONTACT_ID, ContactsContract.CommonDataKinds.Email.ADDRESS),
            "${ContactsContract.CommonDataKinds.Email.CONTACT_ID} IN ($ids)", null, null)?.use { c ->
            while (c.moveToNext()) {
                @Suppress("UNCHECKED_CAST")
                val l = byId[c.getLong(0)]?.get("emails") as? ArrayList<String> ?: continue
                val e = c.getString(1) ?: continue
                if (!l.contains(e) && l.size < 3) l.add(e)
            }
        }
        return byId.values.toList()
    }
}
