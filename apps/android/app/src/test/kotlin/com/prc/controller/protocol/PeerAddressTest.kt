package com.prc.controller.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/** Which address a Mac is tried on, and in what order. */
class PeerAddressTest {

    private fun peer(preferred: String? = null, lastGood: String? = null) = Peer(
        deviceId = "a".repeat(64),
        publicKey = "k",
        name = "Mac mini",
        addresses = listOf("192.168.1.55:47500", "100.64.0.10:47500", "[fd7a:115c:a1e0::1]:47500"),
        pairedAt = 0,
        preferred = preferred,
        lastGood = lastGood,
    )

    @Test
    fun `without a choice the advertised addresses are tried in order`() {
        assertEquals(
            listOf("192.168.1.55:47500", "100.64.0.10:47500", "[fd7a:115c:a1e0::1]:47500"),
            peer().candidates(),
        )
    }

    @Test
    fun `a chosen address leads, and is not repeated further down`() {
        val candidates = peer(preferred = "100.64.0.10:47500").candidates()
        assertEquals("100.64.0.10:47500", candidates.first())
        assertEquals(3, candidates.size)
    }

    @Test
    fun `what worked last time is tried before the rest`() {
        val candidates = peer(lastGood = "100.64.0.10:47500").candidates()
        assertEquals("100.64.0.10:47500", candidates.first())
    }

    @Test
    fun `a chosen address outranks what worked last time`() {
        val candidates = peer(preferred = "10.0.0.9:47500", lastGood = "192.168.1.55:47500").candidates()
        assertEquals(listOf("10.0.0.9:47500", "192.168.1.55:47500"), candidates.take(2))
    }

    @Test
    fun `an address the owner typed with stray spaces still counts`() {
        assertEquals("100.64.0.10:47500", peer(preferred = "  100.64.0.10:47500  ").candidates().first())
    }

    @Test
    fun `an empty choice is ignored rather than tried`() {
        assertEquals("192.168.1.55:47500", peer(preferred = "   ").candidates().first())
    }
}
