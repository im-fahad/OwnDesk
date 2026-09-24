package io.github.im_fahad.owndesk.device

import android.content.Context
import io.github.im_fahad.owndesk.protocol.Envelope
import io.github.im_fahad.owndesk.protocol.Identity
import io.github.im_fahad.owndesk.protocol.Peer
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.security.PublicKey

/**
 * The Macs this phone may control. Small enough to read and rewrite whole on every call.
 *
 * Nothing is cached. The home screen and the session screen each hold a store, and a Mac removed in
 * one, because it turned the phone away, must be gone from the other too. A cached list would keep
 * showing it and, worse, write it back the next time that Mac was seen on the network.
 */
class PeerStore(private val file: File) {
    constructor(context: Context) : this(File(context.filesDir, "peers.json"))

    fun all(): List<Peer> = synchronized(lock) { load() }

    fun peer(deviceId: String): Peer? = all().firstOrNull { it.deviceId == deviceId }

    /** Only a paired Mac's key resolves, so anything else fails the receiver's sender check. */
    fun publicKey(deviceId: String): PublicKey? =
        peer(deviceId)?.let { runCatching { Identity.publicKeyFromB64(it.publicKey) }.getOrNull() }

    fun save(peer: Peer) = update { peers ->
        peers.removeAll { it.deviceId == peer.deviceId }
        peers.add(peer)
        true
    }

    /**
     * Records where a Mac says it is right now, learned from its own advertisement. It goes first,
     * because a live answer beats whatever was true when the pairing happened, and the list is
     * capped so a Mac that moves between networks does not collect an endless tail of addresses
     * nobody can reach. Returns whether anything actually changed, so callers can leave the screen
     * alone when it did not.
     */
    fun noteDiscovered(deviceId: String, address: String): Boolean = update { peers ->
        val index = peers.indexOfFirst { it.deviceId == deviceId }
        val updated = peers.getOrNull(index)?.withDiscovered(address) ?: return@update false
        peers[index] = updated
        true
    }

    /** Records an address the owner typed, or clears it when the text is blank. */
    fun setPreferred(deviceId: String, address: String?) = update { peers ->
        val index = peers.indexOfFirst { it.deviceId == deviceId }
        if (index < 0) return@update false
        peers[index] = peers[index].copy(preferred = address?.trim()?.takeIf { it.isNotEmpty() })
        true
    }

    /** Remembers what worked, so the next connection starts with it. */
    fun setLastGood(deviceId: String, address: String) = update { peers ->
        val index = peers.indexOfFirst { it.deviceId == deviceId }
        if (index < 0 || peers[index].lastGood == address) return@update false
        peers[index] = peers[index].copy(lastGood = address)
        true
    }

    fun forget(deviceId: String) = update { peers -> peers.removeAll { it.deviceId == deviceId } }

    /** Reads, changes, and writes back only when [change] says something changed. */
    private fun update(change: (MutableList<Peer>) -> Boolean): Boolean = synchronized(lock) {
        val peers = load()
        val changed = change(peers)
        if (changed) write(peers)
        changed
    }

    private fun load(): MutableList<Peer> = try {
        if (!file.exists()) mutableListOf()
        else Envelope.json.decodeFromString(ListSerializer(Peer.serializer()), file.readText()).toMutableList()
    } catch (e: Exception) {
        mutableListOf()
    }

    private fun write(peers: List<Peer>) {
        file.writeText(Envelope.json.encodeToString(ListSerializer(Peer.serializer()), peers))
    }

    private companion object {
        /** One lock for every store on this file, whichever screen holds it. */
        val lock = Any()
    }
}
