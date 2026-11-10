package com.telesia.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/** Home-screen widget: Ask, Scan and Live, one tap each. */
class QuickWidget : AppWidgetProvider() {
    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val v = RemoteViews(ctx.packageName, R.layout.telesia_widget)
            v.setOnClickPendingIntent(R.id.w_ask, open(ctx, "widget/ask", 1))
            v.setOnClickPendingIntent(R.id.w_scan, open(ctx, "widget/scan", 2))
            v.setOnClickPendingIntent(R.id.w_live, open(ctx, "live", 3))
            mgr.updateAppWidget(id, v)
        }
    }

    private fun open(ctx: Context, payload: String, code: Int): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        i.putExtra("telesia_payload", payload)
        return PendingIntent.getActivity(ctx, code, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}
