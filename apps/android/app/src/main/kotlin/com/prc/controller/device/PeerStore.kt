package com.prc.controller.device

import android.content.Context
import com.prc.controller.protocol.Envelope
import com.prc.controller.protocol.Identity
import com.prc.controller.protocol.Peer
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.security.PublicKey

/** The Macs this phone may control. Small enough to rewrite whole on every change. */
class PeerStore(context: Context) {
    private val file = File(context.filesDir, "peers.json")
    private var peers: MutableList<Peer> = load()

    fun all(): List<Peer> = peers.toList()

    fun peer(deviceId: String): Peer? = peers.firstOrNull { it.deviceId == deviceId }

    /** Only a paired Mac's key resolves, so anything else fails the receiver's sender check. */
    fun publicKey(deviceId: String): PublicKey? =
        peer(deviceId)?.let { runCatching { Identity.publicKeyFromB64(it.publicKey) }.getOrNull() }

    fun save(peer: Peer) {
        peers.removeAll { it.deviceId == peer.deviceId }
        peers.add(peer)
        write()
    }

    /** Records an address the owner typed, or clears it when the text is blank. */
    fun setPreferred(deviceId: String, address: String?) {
        val peer = peer(deviceId) ?: return
        save(peer.copy(preferred = address?.trim()?.takeIf { it.isNotEmpty() }))
    }

    /** Remembers what worked, so the next connection starts with it. */
    fun setLastGood(deviceId: String, address: String) {
        val peer = peer(deviceId) ?: return
        if (peer.lastGood == address) return
        save(peer.copy(lastGood = address))
    }

    fun forget(deviceId: String) {
        peers.removeAll { it.deviceId == deviceId }
        write()
    }

    private fun load(): MutableList<Peer> = try {
        if (!file.exists()) mutableListOf()
        else Envelope.json.decodeFromString(ListSerializer(Peer.serializer()), file.readText()).toMutableList()
    } catch (e: Exception) {
        mutableListOf()
    }

    private fun write() {
        file.writeText(Envelope.json.encodeToString(ListSerializer(Peer.serializer()), peers))
    }
}
