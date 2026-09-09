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
     * Level 3.1, which Android offers by default, tops out at 1280x720, and a Mac that cannot meet
     * the level in the offer quietly sends VP8 instead. The level offered is therefore the highest
     * this phone's own decoder reports, which covers a 1920x1200 desktop as easily as a 1080p one.
     */
    fun preferH264(sdp: String, level: String = H264Level.best()): String {
        // The level is raised first, and that result is what gets returned even when the order
        // already puts H.264 first: returning the original here would quietly undo it.
        val raised = raiseH264Level(sdp, level)
        val lines = raised.split("\r\n")
        val videoIndex = lines.indexOfFirst { it.startsWith("m=video") }
        if (videoIndex < 0) return raised

        val h264 = payloadTypesFor("H264", lines)
        if (h264.isEmpty()) return raised

        val parts = lines[videoIndex].split(" ")
        if (parts.size < 4) return raised
        val head = parts.take(3)
        val payloads = parts.drop(3)
        val reordered = h264.filter { it in payloads } + payloads.filterNot { it in h264 }
        if (reordered == payloads) return raised

        val updated = lines.toMutableList()
        updated[videoIndex] = (head + reordered).joinToString(" ")
        return updated.joinToString("\r\n")
    }

    private fun raiseH264Level(sdp: String, level: String): String = sdp.split("\r\n").joinToString("\r\n") { line ->
        if (!line.startsWith("a=fmtp:") || !line.contains("profile-level-id=")) return@joinToString line
        val id = line.substringAfter("profile-level-id=").take(6)
        if (id.length != 6) return@joinToString line
        val offered = id.substring(4).toIntOrNull(16) ?: return@joinToString line
        val wanted = level.toIntOrNull(16) ?: return@joinToString line
        // Only ever raise it: a level already high enough is left alone.
        if (offered >= wanted) return@joinToString line
        line.replace("profile-level-id=$id", "profile-level-id=${id.substring(0, 4)}$level")
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
