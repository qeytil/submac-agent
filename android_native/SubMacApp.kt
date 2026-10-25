package com.submac.agent

import android.app.Application
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Owns the one Flutter engine. The screen borrows it, and the wake word, the floating
 * Live orb and background tasks keep using it after the screen is closed.
 */
class SubMacApp : Application() {
    override fun onCreate() {
        super.onCreate()
        app = this
        Notifier.ensureChannels(this)
    }

    companion object {
        lateinit var app: SubMacApp
        private const val ENGINE = "submac_main"

        @JvmStatic
        fun engineIfRunning(): FlutterEngine? = FlutterEngineCache.getInstance().get(ENGINE)

        @JvmStatic
        fun engine(ctx: Context): FlutterEngine {
            FlutterEngineCache.getInstance().get(ENGINE)?.let { return it }
            val e = FlutterEngine(ctx.applicationContext)
            Bridge.attach(ctx.applicationContext, e)
            AppUpdater.attach(ctx.applicationContext, e)
            e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE, e)
            return e
        }
    }
}
