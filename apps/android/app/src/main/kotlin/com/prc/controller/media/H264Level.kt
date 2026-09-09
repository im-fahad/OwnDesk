package com.prc.controller.media

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.util.Log

/**
 * How large a picture this phone's H.264 decoder will accept, in the form an offer states it.
 *
 * The level is not decoration. A Mac that cannot meet the level in the offer does not complain: it
 * quietly encodes VP8 instead, and the only symptom is a picture that costs ten times the bandwidth
 * and arrives at a third of the frame rate. Level 3.1, which Android offers by default, stops at
 * 1280x720; level 4.2 stops just short of a 1920x1200 desktop. Rather than guess again, this asks
 * the decoder and offers exactly what it says it can do.
 */
object H264Level {
    /** What SDP calls the level: the level number times ten, in hexadecimal. */
    const val DEFAULT = "2a" // 4.2, enough for 1920x1080

    private val levels = linkedMapOf(
        MediaCodecInfo.CodecProfileLevel.AVCLevel52 to 52,
        MediaCodecInfo.CodecProfileLevel.AVCLevel51 to 51,
        MediaCodecInfo.CodecProfileLevel.AVCLevel5 to 50,
        MediaCodecInfo.CodecProfileLevel.AVCLevel42 to 42,
        MediaCodecInfo.CodecProfileLevel.AVCLevel41 to 41,
        MediaCodecInfo.CodecProfileLevel.AVCLevel4 to 40,
    )

    private val cached: String by lazy { query() }

    fun best(): String = cached

    /** The two hexadecimal digits for a level number such as 51, which is level 5.1. */
    fun hex(level: Int): String = level.toString(16).padStart(2, '0')

    private fun query(): String {
        val found = try {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { !it.isEncoder && it.supportedTypes.any { type -> type.equals("video/avc", true) } }
                .flatMap { it.getCapabilitiesForType("video/avc").profileLevels.asList() }
                .mapNotNull { levels[it.level] }
                .maxOrNull()
        } catch (e: Exception) {
            null
        }
        // Capped at 5.2, the highest level libwebrtc's parser understands: claiming 6.x makes the
        // Mac discard the whole H.264 line and the session dies during negotiation. 5.2 already
        // covers 4096x2176, far beyond any desktop.
        val level = found?.coerceIn(42, 52) ?: return DEFAULT
        Log.i("PRC", "this phone decodes H.264 up to level ${level / 10}.${level % 10}")
        return hex(level)
    }
}
