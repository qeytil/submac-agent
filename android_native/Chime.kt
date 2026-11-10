package com.telesia.app

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer

/** The soft two-note Telesia wake chime (res/raw/telesia_wake.wav). */
object Chime {
    fun play(ctx: Context) {
        try {
            val id = ctx.resources.getIdentifier("telesia_wake", "raw", ctx.packageName)
            if (id == 0) return
            val mp = MediaPlayer()
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            val fd = ctx.resources.openRawResourceFd(id)
            mp.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
            fd.close()
            mp.setVolume(0.8f, 0.8f)
            mp.setOnCompletionListener { it.release() }
            mp.prepare()
            mp.start()
        } catch (_: Exception) {
        }
    }
}
