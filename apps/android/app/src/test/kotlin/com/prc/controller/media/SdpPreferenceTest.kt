package com.prc.controller.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class SdpPreferenceTest {

    private fun sdp(videoLine: String, vararg rtpmaps: String) =
        (listOf("v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111", videoLine) + rtpmaps).joinToString("\r\n")

    @Test
    fun `H264 moves to the front of the video line`() {
        val offer = sdp(
            "m=video 9 UDP/TLS/RTP/SAVPF 96 98 100",
            "a=rtpmap:96 VP8/90000",
            "a=rtpmap:98 H264/90000",
            "a=rtpmap:100 VP9/90000",
        )
        val line = SdpPreference.preferH264(offer).split("\r\n").first { it.startsWith("m=video") }
        assertEquals("m=video 9 UDP/TLS/RTP/SAVPF 98 96 100", line)
    }

    @Test
    fun `every H264 payload type is promoted, keeping their order`() {
        val offer = sdp(
            "m=video 9 UDP/TLS/RTP/SAVPF 96 98 102 104",
            "a=rtpmap:96 VP8/90000",
            "a=rtpmap:98 H264/90000",
            "a=rtpmap:102 H264/90000",
            "a=rtpmap:104 AV1/90000",
        )
        val line = SdpPreference.preferH264(offer).split("\r\n").first { it.startsWith("m=video") }
        assertEquals("m=video 9 UDP/TLS/RTP/SAVPF 98 102 96 104", line)
    }

    @Test
    fun `nothing is dropped, so a peer without H264 still has something to agree on`() {
        val offer = sdp(
            "m=video 9 UDP/TLS/RTP/SAVPF 96 98",
            "a=rtpmap:96 VP8/90000",
            "a=rtpmap:98 H264/90000",
        )
        val line = SdpPreference.preferH264(offer).split("\r\n").first { it.startsWith("m=video") }
        assertTrue(line.contains("96"))
        assertTrue(line.contains("98"))
    }

    @Test
    fun `the H264 level is raised so 1080p is allowed`() {
        val offer = sdp(
            "m=video 9 UDP/TLS/RTP/SAVPF 96 98",
            "a=rtpmap:96 VP8/90000",
            "a=rtpmap:98 H264/90000",
            "a=fmtp:98 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
        )
        val out = SdpPreference.preferH264(offer, level = "2a")
        assertTrue("level was left at 3.1: $out", out.contains("profile-level-id=42e02a"))
        assertTrue("the profile changed", out.contains("42e0"))
        assertTrue("other parameters were lost", out.contains("packetization-mode=1"))
    }

    @Test
    fun `a level that is already high enough is left alone`() {
        val offer = sdp(
            "m=video 9 UDP/TLS/RTP/SAVPF 98",
            "a=rtpmap:98 H264/90000",
            "a=fmtp:98 profile-level-id=640c34",
        )
        assertTrue(SdpPreference.preferH264(offer, level = "2a").contains("profile-level-id=640c34"))
    }

    @Test
    fun `a phone that decodes more is offered more`() {
        val offer = sdp(
            "m=video 9 UDP/TLS/RTP/SAVPF 98",
            "a=rtpmap:98 H264/90000",
            "a=fmtp:98 profile-level-id=42e01f",
        )
        // 1920x1200 needs more than level 4.2, which is why the level is asked for rather than fixed.
        assertTrue(SdpPreference.preferH264(offer, level = "33").contains("profile-level-id=42e033"))
    }

    @Test
    fun `a level number becomes the two digits SDP uses`() {
        assertEquals("2a", H264Level.hex(42))
        assertEquals("33", H264Level.hex(51))
        assertEquals("34", H264Level.hex(52))
    }

    @Test
    fun `an offer without H264 is left exactly as it was`() {
        val offer = sdp("m=video 9 UDP/TLS/RTP/SAVPF 96", "a=rtpmap:96 VP8/90000")
        assertEquals(offer, SdpPreference.preferH264(offer))
    }

    @Test
    fun `an offer with no video is left exactly as it was`() {
        val offer = listOf("v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111").joinToString("\r\n")
        assertEquals(offer, SdpPreference.preferH264(offer))
    }
}
