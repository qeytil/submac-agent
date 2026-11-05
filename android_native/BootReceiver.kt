package com.submac.agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** After a restart or an update, turns "Hello SubMac" back on if the user had it on. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        // Alarms are wiped by a restart: if bots or offices are working, start SubMac quietly so it sets them again.
        try {
            val fp = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val bots = fp.getString("flutter.bots_v1", "") ?: ""
            val offices = fp.getString("flutter.offices_v1", "") ?: ""
            val tasks = fp.getString("flutter.scheduled", "") ?: ""
            if (bots.contains("\"active\":true") || (offices.length > 4) || tasks.length > 4) {
                // Not started from here: a receiver's process is frozen seconds after it returns (and Android 15 lets
                // no dataSync service start from a boot broadcast), so Dart never finished setting the alarms. An
                // exact alarm a few seconds from now starts SubMac with its foreground service instead (2026-11-05).
                Alarms.set(ctx, "rearm", System.currentTimeMillis() + 5000L, "Getting your bots ready")
            }
        } catch (_: Throwable) {}
        if (!WakeService.enabled(ctx)) return
        try {
            WakeService.start(ctx, "", ctx.getSharedPreferences("submac_wake", Context.MODE_PRIVATE).getFloat("sens", 0.6f), true)
        } catch (e: Exception) {
            // Newer Android versions don't allow the mic to start at boot: ask for one tap.
            Notifier.task(ctx, 7105, "", "Listening is paused. Tap to turn it on", "wake/restart", "paused")
        }
    }
}
