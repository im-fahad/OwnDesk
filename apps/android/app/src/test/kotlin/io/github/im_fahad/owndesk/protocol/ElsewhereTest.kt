package io.github.im_fahad.owndesk.protocol

import io.github.im_fahad.owndesk.net.Discovery
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A Mac's announced Tailscale addresses: only those are taken, and they survive the cap. */
class ElsewhereTest {
    private fun peer(addresses: List<String>) = Peer(deviceId = "a".repeat(64), publicKey = "k", name = "Mac", addresses = addresses, pairedAt = 0)

    @Test
    fun `only Tailscale addresses are read from the announcement`() {
        assertEquals(listOf("100.64.0.20:47500", "[fd7a:115c:a1e0::20]:47500"),
            Discovery.elsewhere("100.64.0.20:47500,[fd7a:115c:a1e0::20]:47500"))
        assertEquals(emptyList<String>(), Discovery.elsewhere("192.168.1.20:47500,8.8.8.8:47500,100.200.0.1:47500,nonsense"))
        assertEquals(emptyList<String>(), Discovery.elsewhere(null))
        assertEquals(3, Discovery.elsewhere("100.64.0.1:1,100.64.0.2:1,100.64.0.3:1,100.64.0.4:1").size)
    }

    @Test
    fun `announced addresses are added after the known ones`() {
        val updated = peer(listOf("192.168.1.20:47500")).withElsewhere(listOf("100.64.0.20:47500"))
        assertEquals(listOf("192.168.1.20:47500", "100.64.0.20:47500"), updated?.addresses)
        assertNull(updated!!.withElsewhere(listOf("100.64.0.20:47500")))
    }

    @Test
    fun `over the cap old local addresses go, never the Tailscale ones`() {
        val full = peer((1..6).map { "192.168.1.$it:47500" })
        val updated = full.withElsewhere(listOf("100.64.0.20:47500"))!!
        assertEquals(Peer.MAX_ADDRESSES, updated.addresses.size)
        assertTrue("100.64.0.20:47500" in updated.addresses)
        assertEquals("192.168.1.1:47500", updated.addresses.first())
    }
}
