package com.prc.controller.media

/**
 * Puts H.264 first in an offer.
 *
 * Both Macs encode H.264 in hardware, and this phone decodes it in hardware, but a WebRTC offer
 * lists whatever the platform happens to prefer, and Android's default order starts with VP8. The
 * far side politely obliges, so the Mac ends up encoding VP8 in software and the picture arrives
 * slower for no reason. Measured over a tailnet before this: VP8 at seventeen frames a second.
 *
 * Only the order changes. Nothing is removed, so a peer without H.264 still finds common ground.
 */
object SdpPreference {

    /**
     * Level 3.1, which Android offers by default, tops out at 1280x720. A Mac asked for a 1080p
     * desktop cannot meet it, so it quietly encodes VP8 instead: the negotiation succeeds, the
     * picture arrives, and only the frame rate says anything is wrong. Level 4.2 covers 1920x1080
     * at sixty, and any phone that can decode this stream can decode that level.
     */
    private const val LEVEL_4_2 = "2a"

    fun preferH264(sdp: String): String {
        val lines = raiseH264Level(sdp).split("\r\n")
        val videoIndex = lines.indexOfFirst { it.startsWith("m=video") }
        if (videoIndex < 0) return sdp

        val h264 = payloadTypesFor("H264", lines)
        if (h264.isEmpty()) return sdp

        val parts = lines[videoIndex].split(" ")
        if (parts.size < 4) return sdp
        val head = parts.take(3)
        val payloads = parts.drop(3)
        val reordered = h264.filter { it in payloads } + payloads.filterNot { it in h264 }
        if (reordered == payloads) return sdp

        val updated = lines.toMutableList()
        updated[videoIndex] = (head + reordered).joinToString(" ")
        return updated.joinToString("\r\n")
    }

    private fun raiseH264Level(sdp: String): String = sdp.split("\r\n").joinToString("\r\n") { line ->
        if (!line.startsWith("a=fmtp:") || !line.contains("profile-level-id=")) return@joinToString line
        val id = line.substringAfter("profile-level-id=").take(6)
        if (id.length != 6) return@joinToString line
        val level = id.substring(4).toIntOrNull(16) ?: return@joinToString line
        // Only ever raise it: a level already high enough is left alone.
        if (level >= LEVEL_4_2.toInt(16)) return@joinToString line
        line.replace("profile-level-id=$id", "profile-level-id=${id.substring(0, 4)}$LEVEL_4_2")
    }

    /** Every payload type whose rtpmap names this codec, in the order the offer lists them. */
    private fun payloadTypesFor(codec: String, lines: List<String>): List<String> =
        lines.mapNotNull { line ->
            if (!line.startsWith("a=rtpmap:")) return@mapNotNull null
            val body = line.removePrefix("a=rtpmap:")
            val payload = body.substringBefore(' ')
            val name = body.substringAfter(' ').substringBefore('/')
            if (name.equals(codec, ignoreCase = true)) payload else null
        }
}
