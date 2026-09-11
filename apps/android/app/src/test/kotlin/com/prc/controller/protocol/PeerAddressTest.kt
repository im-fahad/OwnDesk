package com.prc.controller.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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

    /**
     * The bug these exist to prevent: a Mac paired at .55 comes back as .52 after the router
     * changes its lease, and with Tailscale off there is then nothing reachable left to try. The
     * Mac sits on the same Wi-Fi as the phone and reads as offline.
     */
    @Test
    fun `a Mac that says where it is goes to the front`() {
        val moved = peer().withDiscovered("192.168.1.52:47500")
        assertEquals("192.168.1.52:47500", moved?.addresses?.first())
        assertEquals("192.168.1.52:47500", moved?.candidates()?.first())
        // The old ones stay: away from this network they may be the only ones that work.
        assertEquals(4, moved?.addresses?.size)
    }

    @Test
    fun `hearing the same address again changes nothing`() {
        assertNull(peer().withDiscovered("192.168.1.55:47500"))
        assertNull(peer().withDiscovered("  "))
        assertNull(peer().withDiscovered(""))
    }

    /** An address already known but further down is promoted rather than duplicated. */
    @Test
    fun `a known address is promoted, not repeated`() {
        val moved = peer().withDiscovered("100.64.0.10:47500")
        assertEquals("100.64.0.10:47500", moved?.addresses?.first())
        assertEquals(3, moved?.addresses?.size)
        assertEquals(1, moved?.addresses?.count { it == "100.64.0.10:47500" })
    }

    /** A Mac that moves between networks must not collect an endless tail of dead addresses. */
    @Test
    fun `the list is capped, oldest dropped`() {
        var p = peer()
        for (i in 1..10) p = p.withDiscovered("192.168.1.$i:47500") ?: p
        assertEquals(Peer.MAX_ADDRESSES, p.addresses.size)
        assertEquals("192.168.1.10:47500", p.addresses.first())
        // The address it was paired with has fallen off the end by now.
        assertTrue("192.168.1.55:47500" !in p.addresses)
    }
}
