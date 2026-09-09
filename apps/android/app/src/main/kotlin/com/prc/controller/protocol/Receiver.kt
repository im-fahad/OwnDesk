package com.prc.controller.protocol

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import java.security.PublicKey

/**
 * Receiver rules for signaling envelopes (spec section 6), applied in this order. Every failure is
 * final for that message. This mirrors the TypeScript and Swift receivers and is checked against
 * the same vectors, so all three agree on what is acceptable.
 */
sealed class ReceiveResult {
    data class Accepted(val envelope: Envelope, val payloadJson: String) : ReceiveResult()
    data class Rejected(val reason: String, val detail: String? = null) : ReceiveResult()
}

class EnvelopeReceiver(
    private val selfDeviceId: String,
    private val resolveKey: (String) -> PublicKey?,
    private val now: () -> Long = { System.currentTimeMillis() },
    private val maxSkewMs: Long = Envelope.MAX_CLOCK_SKEW_MS,
    private val acceptPairRequests: Boolean = false,
) {
    private val lastSeq = HashMap<String, Long>()

    fun receive(raw: String): ReceiveResult {
        val bytes = Encoding.utf8(raw)
        if (bytes.size > Envelope.MAX_ENVELOPE_BYTES) return ReceiveResult.Rejected("too_large")

        val obj = try {
            Envelope.json.parseToJsonElement(raw) as? JsonObject ?: return ReceiveResult.Rejected("malformed", "not an object")
        } catch (e: Exception) {
            return ReceiveResult.Rejected("malformed", "not json")
        }
        val env = shape(obj) ?: return ReceiveResult.Rejected("malformed", "field types")

        if (env.v !in Envelope.SUPPORTED_VERSIONS) return ReceiveResult.Rejected("unsupported_version")
        if (env.to != selfDeviceId) return ReceiveResult.Rejected("wrong_recipient")
        if (env.type !in Envelope.TYPES) return ReceiveResult.Rejected("unknown_type")

        var payloadJson: String? = null
        val key: PublicKey
        if (env.type == "PAIR_REQUEST") {
            // A pairing request carries its own key, so it is the one message from a stranger. The
            // key must hash to the sender id, and the host still asks its owner to approve.
            if (!acceptPairRequests) return ReceiveResult.Rejected("unknown_sender", "pairing not open")
            val json = try { env.payloadJson() } catch (e: Exception) { return ReceiveResult.Rejected("invalid_payload") }
            val request = try {
                Envelope.json.decodeFromString(PairRequestPayload.serializer(), json)
            } catch (e: Exception) {
                return ReceiveResult.Rejected("invalid_payload", "PAIR_REQUEST")
            }
            val raw65 = try { Encoding.b64urlDecode(request.public_key) } catch (e: Exception) {
                return ReceiveResult.Rejected("invalid_payload", "public_key")
            }
            val derived = try { Identity.deviceId(raw65) } catch (e: Exception) {
                return ReceiveResult.Rejected("invalid_payload", "public_key")
            }
            if (derived != env.from) return ReceiveResult.Rejected("unknown_sender", "public_key does not match from")
            key = try { Identity.publicKey(raw65) } catch (e: Exception) {
                return ReceiveResult.Rejected("invalid_payload", "public_key")
            }
            payloadJson = json
        } else {
            key = resolveKey(env.from) ?: return ReceiveResult.Rejected("unknown_sender")
        }

        val sig = try { Encoding.b64urlDecode(env.sig) } catch (e: Exception) {
            return ReceiveResult.Rejected("bad_signature")
        }
        if (!Identity.verify(key, env.signingInput(), sig)) return ReceiveResult.Rejected("bad_signature")

        if (Math.abs(now() - env.ts) > maxSkewMs) return ReceiveResult.Rejected("stale_timestamp")

        val seqKey = "${env.from}|${env.session}"
        if (env.seq <= (lastSeq[seqKey] ?: 0L)) return ReceiveResult.Rejected("replayed")

        if (payloadJson == null) {
            val json = try { env.payloadJson() } catch (e: Exception) { return ReceiveResult.Rejected("invalid_payload") }
            if (!payloadValid(env.type, json)) return ReceiveResult.Rejected("invalid_payload", env.type)
            payloadJson = json
        }

        // Only a fully accepted message advances the counter; replaying a rejected one gains nothing.
        lastSeq[seqKey] = env.seq
        return ReceiveResult.Accepted(env, payloadJson)
    }

    fun forgetSession(from: String, session: String) {
        lastSeq.remove("$from|$session")
    }

    /**
     * The shape the envelope schema describes. A field of the wrong form is malformed, which is a
     * different answer from a signature that fails to verify: a 64-byte signature encodes to
     * exactly 86 base64url characters, so anything else never reaches the verifier.
     */
    private fun shape(obj: JsonObject): Envelope? {
        fun str(name: String): String? = (obj[name] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
        fun num(name: String): Long? = (obj[name] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
        val v = (obj["v"] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: return null
        val session = str("session") ?: return null
        return Envelope(
            v = v,
            type = str("type")?.takeIf { it.matches(TYPE_NAME) } ?: return null,
            from = str("from")?.takeIf { it.matches(DEVICE_ID) } ?: return null,
            to = str("to")?.takeIf { it.matches(DEVICE_ID) } ?: return null,
            session = session.takeIf { it.isEmpty() || it.matches(BYTES16) } ?: return null,
            seq = num("seq")?.takeIf { it >= 1 } ?: return null,
            ts = num("ts")?.takeIf { it >= 0 } ?: return null,
            payload = str("payload")?.takeIf { it.matches(BASE64URL) } ?: return null,
            sig = str("sig")?.takeIf { it.matches(SIGNATURE) } ?: return null,
        )
    }

    private fun payloadValid(type: String, json: String): Boolean {
        val j = Envelope.json
        return try {
            when (type) {
                "SESSION_REQUEST" -> j.decodeFromString(SessionRequestPayload.serializer(), json)
                "SESSION_CHALLENGE" -> j.decodeFromString(SessionChallengePayload.serializer(), json)
                "SESSION_AUTH" -> j.decodeFromString(SessionAuthPayload.serializer(), json)
                "SESSION_ACCEPT" -> j.decodeFromString(SessionAcceptPayload.serializer(), json)
                "SESSION_REJECT" -> j.decodeFromString(SessionRejectPayload.serializer(), json)
                "SESSION_END" -> j.decodeFromString(SessionEndPayload.serializer(), json)
                "PAIR_RESULT" -> j.decodeFromString(PairResultPayload.serializer(), json)
                // Media messages are carried through untouched until the video half is built.
                else -> j.parseToJsonElement(json) as? JsonObject ?: throw ProtocolException("not an object")
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private companion object {
        val DEVICE_ID = Regex("^[0-9a-f]{64}$")
        val TYPE_NAME = Regex("^[A-Z_]{1,32}$")
        val BYTES16 = Regex("^[A-Za-z0-9_-]{22}$")
        val SIGNATURE = Regex("^[A-Za-z0-9_-]{86}$")
        val BASE64URL = Regex("^[A-Za-z0-9_-]*$")
    }
}
