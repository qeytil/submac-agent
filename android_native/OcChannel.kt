package com.telesia.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The opencode calls of "telesia/native" (ocStart, ocToken, ocStop, ocStatus). They need only the app context, so they
 * work with no screen: a bot's scheduled task starts the engine from an alarm while Telesia is closed (2026-11-05).
 * They used to live only in MainActivity.configureFlutterEngine, so an engine started headless by an alarm had no
 * handler: the first opencode call failed and the bot's task never ran until the app was opened.
 *
 * TelesiaApp.engine() attaches this handler to every engine it creates. MainActivity replaces it with its own handler
 * (for screen actions) and sends these four calls here.
 */
object OcChannel {
    private const val NAME = "telesia/native"

    fun attach(ctx: Context, engine: FlutterEngine) {
        val app = ctx.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, NAME)
        ch.setMethodCallHandler { call, result ->
            try {
                if (!handle(app, call, result)) result.notImplemented()
            } catch (e: Throwable) {
                result.error("failed", e.message ?: e.toString(), null)
            }
        }
    }

    /** Handles one opencode call. False when [call] is not one of them. */
    fun handle(ctx: Context, call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "ocStart" -> {
                val base = call.argument<String>("baseUrl") ?: ""
                val token = call.argument<String>("token") ?: ""
                val pass = call.argument<String>("password") ?: ""
                val want = num(call.argument<Any>("port"), 4096).toInt()
                val cwd = call.argument<String>("cwd")
                val skills = (call.argument<Map<String, Any?>>("skills") ?: emptyMap())
                    .mapNotNull { (k, v) -> (v as? String)?.let { k to it } }.toMap()
                // One opencode provider per allowance lane (owner 2026-11-03, OcLane).
                val providers = (call.argument<List<Any?>>("providers") ?: emptyList()).mapNotNull { p ->
                    (p as? Map<*, *>)?.entries?.mapNotNull { (k, v) -> if (k is String && v is String) k to v else null }?.toMap()
                }
                val models = (call.argument<List<Any?>>("models") ?: emptyList()).mapNotNull { it as? String }
                // The user's own providers (BYOK, owner 2026-11-03): config JSON and their keys for the environment.
                val byok = call.argument<String>("byokProviders") ?: ""
                val byokEnv = (call.argument<Map<String, Any?>>("byokEnv") ?: emptyMap())
                    .mapNotNull { (k, v) -> (v as? String)?.let { k to it } }.toMap()
                // How long a reply may be (owner 2026-11-06, OutputLimits in the app): Telesia's models' output limit and
                // opencode's own ceiling (OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX). 0 = not given (older app code).
                val modelOutput = num(call.argument<Any>("modelOutput"), 0).toInt()
                val outputTokenMax = num(call.argument<Any>("outputTokenMax"), 0).toInt()
                val main = Handler(Looper.getMainLooper())
                Thread {
                    try {
                        val port = OpenCode.start(ctx, base, token, pass, want, cwd, skills, providers, models, byok, byokEnv,
                            modelOutput, outputTokenMax)
                        val health = OpenCode.waitHealthy(60000)
                        main.post {
                            result.success(mapOf("ok" to (health != null), "port" to port, "health" to health, "log" to OpenCode.lastLog()))
                        }
                    } catch (e: Throwable) {
                        main.post { result.success(mapOf("ok" to false, "error" to e.toString(), "log" to OpenCode.lastLog())) }
                    }
                }.start()
            }
            "ocToken" -> {
                call.argument<String>("baseUrl")?.let { if (it.isNotEmpty()) LocalProxy.upstream = it }
                call.argument<String>("token")?.let { if (it.isNotEmpty()) LocalProxy.token = it }
                // Every prompt pushes the token just before it is sent. That is the earliest reliable moment a turn
                // exists, and Dart is still on screen then: raise the foreground service here, not in the lifecycle's
                // paused callback. From Android 14 a dataSync FGS started from the background is refused, which used to
                // leave a minimized Telesia with no service and no wake lock — Android froze it and the opencode child
                // process died with it, so the task stopped. A start here is idempotent (a running service only refreshes).
                TaskService.start(ctx, "Working on your task")
                result.success(true)
            }
            "ocStop" -> {
                OpenCode.stop()
                result.success(true)
            }
            "ocStatus" -> result.success(mapOf("installed" to OpenCode.installed(ctx), "running" to OpenCode.running(),
                "port" to OpenCode.port, "log" to OpenCode.lastLog()))
            else -> return false
        }
        return true
    }

    private fun num(v: Any?, fallback: Long): Long = when (v) {
        is Int -> v.toLong()
        is Long -> v
        is Double -> v.toLong()
        is String -> v.toLongOrNull() ?: fallback
        else -> fallback
    }
}
