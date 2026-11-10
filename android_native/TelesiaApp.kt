package com.telesia.app

import android.app.Application
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Owns the one Flutter engine. The screen borrows it, and the wake word, the floating
 * Live orb and background tasks keep using it after the screen is closed.
 */
class TelesiaApp : Application() {
    override fun onCreate() {
        super.onCreate()
        app = this
        Notifier.ensureChannels(this)
    }

    companion object {
        lateinit var app: TelesiaApp
        private const val ENGINE = "telesia_main"

        @JvmStatic
        fun engineIfRunning(): FlutterEngine? = FlutterEngineCache.getInstance().get(ENGINE)

        @JvmStatic
        fun engine(ctx: Context): FlutterEngine {
            FlutterEngineCache.getInstance().get(ENGINE)?.let { return it }
            val e = FlutterEngine(ctx.applicationContext)
            Bridge.attach(ctx.applicationContext, e)
            AppUpdater.attach(ctx.applicationContext, e)
            // opencode's calls work with no screen (a bot's scheduled task started by an alarm). MainActivity replaces
            // this handler with its own when the screen opens and forwards these calls to OcChannel.
            OcChannel.attach(ctx.applicationContext, e)
            e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE, e)
            return e
        }
    }
}
