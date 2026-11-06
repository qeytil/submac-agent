package com.submac.agent

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.SystemClock
import android.provider.Settings
import android.view.KeyEvent

/** Quick phone controls the agent can use without tapping through apps. */
object Device {
    fun run(ctx: Context, action: String, value: String): String {
        return try {
            when (action) {
                "status" -> status(ctx)
                "clipboard_read" -> {
                    val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    val t = cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString()
                    if (t.isNullOrEmpty()) "The clipboard is empty (Android only lets Telesia read it while Telesia is open)." else t.take(4000)
                }
                "clipboard_write" -> {
                    val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("Telesia", value))
                    "Copied to the clipboard."
                }
                "flashlight_on", "flashlight_off" -> {
                    val cam = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                    val id = cam.cameraIdList.firstOrNull() ?: return "This phone has no flashlight."
                    cam.setTorchMode(id, action == "flashlight_on")
                    if (action == "flashlight_on") "Flashlight on." else "Flashlight off."
                }
                "volume" -> {
                    val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    val pct = value.filter { it.isDigit() }.toIntOrNull()?.coerceIn(0, 100) ?: return "Give a volume from 0 to 100."
                    am.setStreamVolume(AudioManager.STREAM_MUSIC, (max * pct / 100.0).toInt(), AudioManager.FLAG_SHOW_UI)
                    "Media volume set to $pct%."
                }
                "ringer" -> {
                    val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val mode = when (value) {
                        "silent" -> AudioManager.RINGER_MODE_SILENT
                        "vibrate" -> AudioManager.RINGER_MODE_VIBRATE
                        else -> AudioManager.RINGER_MODE_NORMAL
                    }
                    try {
                        am.ringerMode = mode
                        "Ringer set to ${if (value.isEmpty()) "normal" else value}."
                    } catch (_: SecurityException) {
                        open(ctx, Settings.ACTION_SOUND_SETTINGS)
                        "Android needs Do Not Disturb access for that, so I opened Sound settings."
                    }
                }
                "media" -> {
                    val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val key = when (value) {
                        "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
                        "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
                        "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
                        "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
                        else -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                    }
                    val t = SystemClock.uptimeMillis()
                    am.dispatchMediaKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_DOWN, key, 0))
                    am.dispatchMediaKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_UP, key, 0))
                    "Done: ${if (value.isEmpty()) "play/pause" else value}."
                }
                "brightness" -> {
                    if (!Settings.System.canWrite(ctx)) {
                        val i = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, android.net.Uri.parse("package:" + ctx.packageName))
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        ctx.startActivity(i)
                        return "Android needs \"Modify system settings\" for Telesia first. I opened that screen."
                    }
                    val pct = value.filter { it.isDigit() }.toIntOrNull()?.coerceIn(0, 100) ?: return "Give a brightness from 0 to 100."
                    Settings.System.putInt(ctx.contentResolver, Settings.System.SCREEN_BRIGHTNESS_MODE, Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
                    Settings.System.putInt(ctx.contentResolver, Settings.System.SCREEN_BRIGHTNESS, (255 * pct / 100.0).toInt())
                    "Brightness set to $pct%."
                }
                "open_settings" -> {
                    val a = when (value) {
                        "wifi" -> Settings.ACTION_WIFI_SETTINGS
                        "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
                        "mobile_data" -> Settings.ACTION_DATA_ROAMING_SETTINGS
                        "airplane" -> Settings.ACTION_AIRPLANE_MODE_SETTINGS
                        "display" -> Settings.ACTION_DISPLAY_SETTINGS
                        "sound" -> Settings.ACTION_SOUND_SETTINGS
                        "battery" -> Intent.ACTION_POWER_USAGE_SUMMARY
                        "location" -> Settings.ACTION_LOCATION_SOURCE_SETTINGS
                        "apps" -> Settings.ACTION_APPLICATION_SETTINGS
                        "storage" -> Settings.ACTION_INTERNAL_STORAGE_SETTINGS
                        "dnd" -> Settings.ACTION_ZEN_MODE_PRIORITY_SETTINGS
                        "hotspot" -> Settings.ACTION_WIRELESS_SETTINGS
                        "nfc" -> Settings.ACTION_NFC_SETTINGS
                        "date" -> Settings.ACTION_DATE_SETTINGS
                        "language" -> Settings.ACTION_LOCALE_SETTINGS
                        else -> Settings.ACTION_SETTINGS
                    }
                    open(ctx, a)
                    "Opened ${if (value.isEmpty()) "Settings" else value} settings."
                }
                else -> "Unknown action $action."
            }
        } catch (e: Exception) {
            "Could not do that: ${e.message ?: e.javaClass.simpleName}"
        }
    }

    private fun open(ctx: Context, action: String) {
        val i = Intent(action)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try { ctx.startActivity(i) } catch (_: Exception) {
            ctx.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    private fun status(ctx: Context): String {
        val sb = StringBuilder()
        val bi = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = bi?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = bi?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val plugged = (bi?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
        if (level >= 0) sb.append("Battery ${level * 100 / scale}%${if (plugged) ", charging" else ""}\n")
        val st = StatFs(Environment.getDataDirectory().path)
        val free = st.availableBytes / (1024.0 * 1024 * 1024)
        val total = st.totalBytes / (1024.0 * 1024 * 1024)
        sb.append(String.format("Storage %.1f GB free of %.0f GB\n", free, total))
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        val net = when {
            caps == null -> "offline"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile data"
            else -> "online"
        }
        sb.append("Network: $net\n")
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val ringer = when (am.ringerMode) { AudioManager.RINGER_MODE_SILENT -> "silent"; AudioManager.RINGER_MODE_VIBRATE -> "vibrate"; else -> "normal" }
        val vol = am.getStreamVolume(AudioManager.STREAM_MUSIC) * 100 / am.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        sb.append("Ringer: $ringer, media volume $vol%\n")
        sb.append("Android ${Build.VERSION.RELEASE}, ${Build.MANUFACTURER} ${Build.MODEL}")
        return sb.toString()
    }
}
