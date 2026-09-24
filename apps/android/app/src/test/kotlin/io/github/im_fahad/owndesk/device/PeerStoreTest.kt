package io.github.im_fahad.owndesk.device

import io.github.im_fahad.owndesk.protocol.Peer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The home screen and the session screen each hold a store; they must agree on what is paired. */
class PeerStoreTest {

    private fun file() = File.createTempFile("peers", ".json").apply { delete(); deleteOnExit() }

    private fun mac(id: Char) = Peer(
        deviceId = id.toString().repeat(64),
        publicKey = "k",
        name = "Mac $id",
        addresses = listOf("192.168.1.55:47500"),
        pairedAt = 0,
    )

    @Test
    fun `a Mac removed by one screen is gone from the other`() {
        val file = file()
        val home = PeerStore(file)
        home.save(mac('a'))
        home.save(mac('b'))
        assertEquals(2, home.all().size)

        PeerStore(file).forget(mac('a').deviceId)

        assertNull(home.peer(mac('a').deviceId))
        assertEquals(listOf(mac('b').deviceId), home.all().map { it.deviceId })
    }

    @Test
    fun `seeing a removed Mac on the network does not bring it back`() {
        val file = file()
        val home = PeerStore(file)
        home.save(mac('a'))
        PeerStore(file).forget(mac('a').deviceId)

        assertFalse(home.noteDiscovered(mac('a').deviceId, "192.168.1.60:47500"))
        assertTrue(PeerStore(file).all().isEmpty())
    }

    @Test
    fun `changes made through one store are seen through another`() {
        val file = file()
        PeerStore(file).save(mac('a'))
        assertTrue(PeerStore(file).noteDiscovered(mac('a').deviceId, "192.168.1.60:47500"))
        assertEquals("192.168.1.60:47500", PeerStore(file).peer(mac('a').deviceId)?.addresses?.first())
    }
}
