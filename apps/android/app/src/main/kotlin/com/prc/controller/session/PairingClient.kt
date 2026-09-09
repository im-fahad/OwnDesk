package com.prc.controller.session

import com.prc.controller.net.Endpoints
import com.prc.controller.net.SignalingClient
import com.prc.controller.protocol.Encoding
import com.prc.controller.protocol.Envelope
import com.prc.controller.protocol.EnvelopeReceiver
import com.prc.controller.protocol.EnvelopeSender
import com.prc.controller.protocol.Identity
import com.prc.controller.protocol.PairRequestPayload
import com.prc.controller.protocol.PairResultPayload
import com.prc.controller.protocol.Pairing
import com.prc.controller.protocol.Peer
import com.prc.controller.protocol.ProtocolException
import com.prc.controller.protocol.QrPayload
import com.prc.controller.protocol.ReceiveResult
import com.prc.controller.protocol.SigningIdentity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import java.security.PublicKey

/**
 * Pairs this phone with a Mac from the code that Mac displays (spec section 7).
 *
 * The code proves the two devices are in the same room: the phone answers with an HMAC over it, so
 * a stranger who reached the Mac's port cannot pair. In the other direction the Mac's key must hash
 * to the id printed in the code, so a fake Mac on the network cannot collect the request. Both
 * people still compare fingerprints on screen, which is what defeats an attacker holding the code.
 */
class PairingClient(
    private val identity: SigningIdentity,
    private val deviceName: String,
) {
    data class Outcome(val peer: Peer, val address: String)

    companion object {
        fun parse(text: String): QrPayload {
            val trimmed = text.trim()
            val qr = try {
                Envelope.json.decodeFromString(QrPayload.serializer(), trimmed)
            } catch (e: Exception) {
                throw ProtocolException("not a pairing code")
            }
            qr.validate()
            return qr
        }
    }

    suspend fun pair(qr: QrPayload, timeoutMs: Long = 130_000): Outcome {
        if (System.currentTimeMillis() >= qr.expires_at) throw ProtocolException("this code has expired")
        var last: Exception = ProtocolException("no address answered")
        for (address in qr.addresses) {
            val url = Endpoints.url(address) ?: continue
            try {
                return attempt(qr, url, address, timeoutMs)
            } catch (e: ProtocolException) {
                last = e
                if (e.reason != "connection") throw e
            }
        }
        throw last
    }

    private suspend fun attempt(qr: QrPayload, url: String, address: String, timeoutMs: Long): Outcome {
        val client = SignalingClient(url)
        val opened = CompletableDeferred<Unit>()
        val result = CompletableDeferred<PairResultPayload>()
        // Until the result arrives the phone knows only the Mac's id, so the key the result carries
        // is accepted for verification exactly when it hashes to that id.
        var hostKey: PublicKey? = null
        val receiver = EnvelopeReceiver(
            selfDeviceId = identity.deviceId,
            resolveKey = { from -> if (from == qr.host_device_id) hostKey else null },
        )

        try {
            client.connect { event ->
                when (event) {
                    is SignalingClient.Event.Opened -> opened.complete(Unit)
                    is SignalingClient.Event.Closed -> {
                        val error = ProtocolException("connection")
                        opened.completeExceptionally(error)
                        result.completeExceptionally(error)
                    }
                    is SignalingClient.Event.Message -> {
                        val envelope = runCatching {
                            Envelope.json.decodeFromString(Envelope.serializer(), event.text)
                        }.getOrNull()
                        if (envelope == null || envelope.type != "PAIR_RESULT") return@connect
                        val payload = runCatching {
                            Envelope.json.decodeFromString(PairResultPayload.serializer(), envelope.payloadJson())
                        }.getOrNull()
                        val raw = payload?.let { runCatching { Encoding.b64urlDecode(it.host_public_key) }.getOrNull() }
                        if (payload == null || raw == null || runCatching { Identity.deviceId(raw) }.getOrNull() != qr.host_device_id) {
                            result.completeExceptionally(ProtocolException("that Mac's key does not match the code"))
                            return@connect
                        }
                        hostKey = runCatching { Identity.publicKey(raw) }.getOrNull()
                        when (val received = receiver.receive(event.text)) {
                            is ReceiveResult.Accepted -> result.complete(payload)
                            is ReceiveResult.Rejected ->
                                result.completeExceptionally(ProtocolException("pairing reply rejected: ${received.reason}"))
                        }
                    }
                }
            }

            try {
                withTimeout(6_000) { opened.await() }
            } catch (e: TimeoutCancellationException) {
                throw ProtocolException("connection")
            }

            val proof = Pairing.proof(qr.pairingCodeBytes, qr.pairing_session_id, identity.deviceId)
            val request = PairRequestPayload(
                public_key = identity.publicKeyB64,
                device_name = deviceName,
                device_type = "android",
                pairing_session_id = qr.pairing_session_id,
                proof = proof,
            )
            val sender = EnvelopeSender(identity)
            val envelope = sender.build(
                "PAIR_REQUEST", qr.host_device_id, "",
                Envelope.json.encodeToString(PairRequestPayload.serializer(), request),
            )
            client.send(envelope.serialize())

            val payload = try {
                withTimeout(timeoutMs) { result.await() }
            } catch (e: TimeoutCancellationException) {
                throw ProtocolException("the Mac did not answer; approve the request on it")
            }
            if (!payload.approved) throw ProtocolException("refused by the Mac: ${payload.reason ?: "denied"}")

            val peer = Peer(
                deviceId = qr.host_device_id,
                publicKey = payload.host_public_key,
                name = payload.host_name,
                addresses = qr.addresses,
                pairedAt = System.currentTimeMillis(),
            )
            return Outcome(peer, address)
        } finally {
            client.close()
        }
    }
}
