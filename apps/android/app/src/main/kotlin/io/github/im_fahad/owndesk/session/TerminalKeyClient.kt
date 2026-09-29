package io.github.im_fahad.owndesk.session

import io.github.im_fahad.owndesk.net.Endpoints
import io.github.im_fahad.owndesk.net.SignalingClient
import io.github.im_fahad.owndesk.protocol.Envelope
import io.github.im_fahad.owndesk.protocol.EnvelopeReceiver
import io.github.im_fahad.owndesk.protocol.EnvelopeSender
import io.github.im_fahad.owndesk.protocol.ReceiveResult
import io.github.im_fahad.owndesk.protocol.SigningIdentity
import io.github.im_fahad.owndesk.protocol.TerminalKeyRequestPayload
import io.github.im_fahad.owndesk.protocol.TerminalKeyResultPayload
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.security.PublicKey

/**
 * Asks a paired Mac to let this phone's SSH key open terminals there (spec section 7.7), so nobody
 * has to paste a line into Terminal on the Mac. The Mac asks the person in front of it and installs
 * the key only when they allow it; this waits for that, up to the two minutes the Mac waits.
 */
class TerminalKeyClient(private val identity: SigningIdentity) {
    sealed class Outcome {
        data class Answered(val result: TerminalKeyResultPayload) : Outcome()
        /** None of the Mac's addresses answered: it is off, asleep, or not letting others in. */
        object Unreachable : Outcome()
        /** Connected, but no signed answer came back in time. */
        object NoAnswer : Outcome()
    }

    /** Only an answer signed with [hostKey], the Mac's own paired key, is taken. */
    suspend fun request(
        key: String, hostDeviceId: String, hostKey: PublicKey, addresses: List<String>, timeoutMs: Long = 130_000,
    ): Outcome = withContext(Dispatchers.IO) {
        val address = Endpoints.firstReachable(addresses) ?: return@withContext Outcome.Unreachable
        val url = Endpoints.url(address) ?: return@withContext Outcome.Unreachable
        val receiver = EnvelopeReceiver(identity.deviceId, resolveKey = { if (it == hostDeviceId) hostKey else null })
        val client = SignalingClient(url)
        val opened = CompletableDeferred<Boolean>()
        val answer = CompletableDeferred<TerminalKeyResultPayload?>()
        try {
            client.connect { event ->
                when (event) {
                    is SignalingClient.Event.Opened -> opened.complete(true)
                    is SignalingClient.Event.Closed -> {
                        opened.complete(false)
                        answer.complete(null)
                    }
                    is SignalingClient.Event.Message -> {
                        val received = receiver.receive(event.text)
                        if (received is ReceiveResult.Accepted && received.envelope.type == "TERMINAL_KEY_RESULT") {
                            answer.complete(runCatching {
                                Envelope.json.decodeFromString(TerminalKeyResultPayload.serializer(), received.payloadJson)
                            }.getOrNull())
                        }
                    }
                }
            }
            if (withTimeoutOrNull(6_000) { opened.await() } != true) return@withContext Outcome.Unreachable
            val payload = Envelope.json.encodeToString(TerminalKeyRequestPayload.serializer(), TerminalKeyRequestPayload(key))
            client.send(EnvelopeSender(identity).build("TERMINAL_KEY_REQUEST", hostDeviceId, "", payload).serialize())
            val result = withTimeoutOrNull(timeoutMs) { answer.await() }
            if (result == null) Outcome.NoAnswer else Outcome.Answered(result)
        } finally {
            client.close()
        }
    }
}
