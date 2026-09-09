package com.prc.controller.session

import com.prc.controller.net.Endpoints
import com.prc.controller.net.SignalingClient
import com.prc.controller.protocol.Capabilities
import com.prc.controller.protocol.Encoding
import com.prc.controller.protocol.Envelope
import com.prc.controller.protocol.EnvelopeReceiver
import com.prc.controller.protocol.EnvelopeSender
import com.prc.controller.protocol.Identity
import com.prc.controller.protocol.Peer
import com.prc.controller.protocol.ProtocolException
import com.prc.controller.protocol.ReceiveResult
import com.prc.controller.protocol.SessionAcceptPayload
import com.prc.controller.protocol.SessionAuthPayload
import com.prc.controller.protocol.SessionChallengePayload
import com.prc.controller.protocol.SessionRejectPayload
import com.prc.controller.protocol.SessionRequestPayload
import com.prc.controller.protocol.SigningIdentity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

/**
 * The authenticated handshake with a paired Mac (spec section 8), up to the point where the Mac
 * agrees to a session and says what its display looks like.
 *
 * Both sides prove possession of the key the pairing recorded: the phone signs every envelope, and
 * the challenge it answers carries a nonce the Mac chose, so a captured message cannot be replayed
 * into a new session. Video and input come next and hang off this same socket.
 */
class SessionClient(
    private val identity: SigningIdentity,
    private val resolveKey: (String) -> java.security.PublicKey?,
) {
    data class Accepted(
        val address: String,
        val path: String,
        val sessionId: String,
        val display: String,
        val roundTripMs: Long,
    )

    /** Tries each address the Mac advertises, in order, and reports the first that answers. */
    suspend fun connect(peer: Peer, onStep: (String) -> Unit): Accepted {
        var last: Exception = ProtocolException("no address answered")
        for (address in peer.addresses) {
            val url = Endpoints.url(address) ?: continue
            onStep("trying $address")
            try {
                return attempt(peer, url, address, onStep)
            } catch (e: ProtocolException) {
                last = e
                if (e.reason != "connection") throw e
            }
        }
        throw last
    }

    private suspend fun attempt(peer: Peer, url: String, address: String, onStep: (String) -> Unit): Accepted {
        val client = SignalingClient(url)
        val opened = CompletableDeferred<Unit>()
        val challenge = CompletableDeferred<SessionChallengePayload>()
        val accepted = CompletableDeferred<SessionAcceptPayload>()
        val clientNonce = Encoding.b64url(Encoding.randomBytes(16))
        val path = Endpoints.path(address)
        val receiver = EnvelopeReceiver(selfDeviceId = identity.deviceId, resolveKey = resolveKey)
        val sender = EnvelopeSender(identity)
        val started = System.currentTimeMillis()

        try {
            client.connect { event ->
                when (event) {
                    is SignalingClient.Event.Opened -> opened.complete(Unit)
                    is SignalingClient.Event.Closed -> {
                        val error = ProtocolException("connection")
                        opened.completeExceptionally(error)
                        challenge.completeExceptionally(error)
                        accepted.completeExceptionally(error)
                    }
                    is SignalingClient.Event.Message -> {
                        when (val received = receiver.receive(event.text)) {
                            is ReceiveResult.Rejected -> {
                                // A rejected envelope is not a session failure by itself; the
                                // watchdog below ends the attempt if nothing valid ever arrives.
                                onStep("ignored a message: ${received.reason}")
                            }
                            is ReceiveResult.Accepted -> {
                                val envelope = received.envelope
                                if (envelope.from != peer.deviceId) return@connect
                                when (envelope.type) {
                                    "SESSION_CHALLENGE" -> {
                                        val payload = Envelope.json.decodeFromString(
                                            SessionChallengePayload.serializer(), received.payloadJson,
                                        )
                                        if (payload.client_nonce != clientNonce || envelope.session != payload.session_id) {
                                            challenge.completeExceptionally(ProtocolException("challenge does not match this request"))
                                        } else {
                                            challenge.complete(payload)
                                        }
                                    }
                                    "SESSION_ACCEPT" -> {
                                        val payload = Envelope.json.decodeFromString(
                                            SessionAcceptPayload.serializer(), received.payloadJson,
                                        )
                                        if (payload.client_nonce != clientNonce) {
                                            accepted.completeExceptionally(ProtocolException("accept does not match this request"))
                                        } else {
                                            accepted.complete(payload)
                                        }
                                    }
                                    "SESSION_REJECT" -> {
                                        val payload = Envelope.json.decodeFromString(
                                            SessionRejectPayload.serializer(), received.payloadJson,
                                        )
                                        val error = ProtocolException(explain(payload.reason))
                                        challenge.completeExceptionally(error)
                                        accepted.completeExceptionally(error)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            try {
                withTimeout(6_000) { opened.await() }
            } catch (e: TimeoutCancellationException) {
                throw ProtocolException("connection")
            }
            onStep("connected to $address, declaring $path")

            val request = SessionRequestPayload(
                client_nonce = clientNonce,
                versions = Envelope.SUPPORTED_VERSIONS,
                path = path,
                capabilities = Capabilities(codecs = listOf("H264"), max_height = 1080, max_fps = 60),
            )
            client.send(
                sender.build(
                    "SESSION_REQUEST", peer.deviceId, "",
                    Envelope.json.encodeToString(SessionRequestPayload.serializer(), request),
                ).serialize()
            )

            val challengePayload = try {
                withTimeout(15_000) { challenge.await() }
            } catch (e: TimeoutCancellationException) {
                throw ProtocolException("the Mac did not answer the request; check that it is awake and hosting")
            }
            onStep("authenticating")

            val auth = SessionAuthPayload(clientNonce, challengePayload.host_nonce)
            client.send(
                sender.build(
                    "SESSION_AUTH", peer.deviceId, challengePayload.session_id,
                    Envelope.json.encodeToString(SessionAuthPayload.serializer(), auth),
                ).serialize()
            )

            val acceptPayload = try {
                withTimeout(15_000) { accepted.await() }
            } catch (e: TimeoutCancellationException) {
                throw ProtocolException("the Mac accepted the request but never confirmed the session")
            }

            val display = acceptPayload.display
            return Accepted(
                address = address,
                path = if (path == "lan") "Direct (LAN)" else "Direct (Tailscale or Internet)",
                sessionId = challengePayload.session_id,
                display = "${display.width_px}x${display.height_px}",
                roundTripMs = System.currentTimeMillis() - started,
            )
        } finally {
            client.close()
        }
    }

    private fun explain(reason: String): String = when (reason) {
        "untrusted" -> "that Mac does not have this phone paired"
        "revoked" -> "this phone's access was revoked on that Mac"
        "remote_access_disabled" -> "that Mac is not letting others control it; turn Remote Access on"
        "busy" -> "that Mac is already in a session"
        "auth_failed" -> "the Mac refused this phone's signature"
        "version_unsupported" -> "the two sides speak different protocol versions"
        "expired" -> "the request took too long and expired"
        "host_error" -> "the Mac hit an internal error, often a missing screen permission"
        else -> "refused: $reason"
    }

    companion object {
        fun fingerprintOf(deviceId: String): String = Identity.fingerprint(deviceId)
    }
}
