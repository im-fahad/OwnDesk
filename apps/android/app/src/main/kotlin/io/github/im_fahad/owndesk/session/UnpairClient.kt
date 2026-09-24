package io.github.im_fahad.owndesk.session

import io.github.im_fahad.owndesk.net.Endpoints
import io.github.im_fahad.owndesk.net.SignalingClient
import io.github.im_fahad.owndesk.protocol.EnvelopeSender
import io.github.im_fahad.owndesk.protocol.SigningIdentity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Tells a paired Mac that this phone has removed the pairing, so the Mac removes it too and neither
 * side keeps a trust the other has dropped. It is best effort: a Mac that is off, asleep, or not
 * letting others control it cannot be told, and the caller says so.
 */
class UnpairClient(private val identity: SigningIdentity) {

    /** True once a Mac at one of [addresses] took the UNPAIR and closed, which it does after removing this phone. */
    suspend fun unpair(hostDeviceId: String, addresses: List<String>, timeoutMs: Long = 4_000): Boolean =
        withContext(Dispatchers.IO) {
            val address = Endpoints.firstReachable(addresses) ?: return@withContext false
            val url = Endpoints.url(address) ?: return@withContext false
            val client = SignalingClient(url)
            val opened = CompletableDeferred<Boolean>()
            val closed = CompletableDeferred<Unit>()
            try {
                client.connect { event ->
                    when (event) {
                        is SignalingClient.Event.Opened -> opened.complete(true)
                        is SignalingClient.Event.Closed -> {
                            opened.complete(false)
                            closed.complete(Unit)
                        }
                        is SignalingClient.Event.Message -> Unit
                    }
                }
                if (withTimeoutOrNull(timeoutMs) { opened.await() } != true) return@withContext false
                client.send(EnvelopeSender(identity).build("UNPAIR", hostDeviceId, "", "{}").serialize())
                withTimeoutOrNull(timeoutMs) { closed.await() } != null
            } finally {
                client.close()
            }
        }
}
