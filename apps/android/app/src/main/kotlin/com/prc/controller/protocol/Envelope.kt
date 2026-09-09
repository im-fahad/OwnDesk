package com.prc.controller.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The signaling envelope (spec section 6). Every control-plane message between two devices is one
 * of these, signed by the sender over a fixed joined string rather than over the JSON, so no
 * canonical JSON form is needed anywhere.
 */
@Serializable
data class Envelope(
    val v: Int,
    val type: String,
    val from: String,
    val to: String,
    val session: String,
    val seq: Long,
    val ts: Long,
    val payload: String,
    val sig: String,
) {
    companion object {
        const val PROTOCOL_VERSION = 1
        const val SIGNALING_CONTEXT = "prc-signaling-v1"
        const val MAX_ENVELOPE_BYTES = 65536
        const val MAX_CLOCK_SKEW_MS = 300_000L
        val SUPPORTED_VERSIONS = listOf(1)

        val TYPES = setOf(
            "PAIR_REQUEST", "PAIR_RESULT", "SESSION_REQUEST", "SESSION_CHALLENGE", "SESSION_AUTH",
            "SESSION_ACCEPT", "SESSION_REJECT", "SDP_OFFER", "SDP_ANSWER", "ICE_CANDIDATE",
            "SESSION_RESUME", "SESSION_END",
        )

        val json = Json { ignoreUnknownKeys = false; encodeDefaults = true; explicitNulls = true }

        /** The bytes that are signed: the context label and the fields, joined by newlines. */
        fun signingInput(
            v: Int, type: String, from: String, to: String, session: String, seq: Long, ts: Long, payload: String,
        ): ByteArray = Encoding.utf8(
            listOf(SIGNALING_CONTEXT, v.toString(), type, from, to, session, seq.toString(), ts.toString(), payload)
                .joinToString("\n")
        )

        fun encodePayload(json: String): String = Encoding.b64url(Encoding.utf8(json))
    }

    fun signingInput(): ByteArray = signingInput(v, type, from, to, session, seq, ts, payload)

    fun payloadJson(): String = Encoding.utf8Decode(Encoding.b64urlDecode(payload))

    fun serialize(): String = json.encodeToString(serializer(), this)
}

/** Builds and signs outgoing envelopes, counting seq per recipient and session. */
class EnvelopeSender(
    private val identity: SigningIdentity,
    private val now: () -> Long = { System.currentTimeMillis() },
) {
    private val seq = HashMap<String, Long>()

    val deviceId: String get() = identity.deviceId

    fun build(type: String, to: String, session: String, payloadJson: String): Envelope {
        val key = "$to|$session"
        val next = (seq[key] ?: 0L) + 1
        seq[key] = next
        val payload = Envelope.encodePayload(payloadJson)
        val input = Envelope.signingInput(
            Envelope.PROTOCOL_VERSION, type, identity.deviceId, to, session, next, now(), payload,
        )
        // Rebuild with the same timestamp the signature covers.
        val ts = readTimestamp(input)
        val sig = Encoding.b64url(identity.sign(input))
        return Envelope(Envelope.PROTOCOL_VERSION, type, identity.deviceId, to, session, next, ts, payload, sig)
    }

    /** The timestamp is inside the signed string, so it is read back rather than sampled twice. */
    private fun readTimestamp(input: ByteArray): Long =
        Encoding.utf8Decode(input).split("\n")[7].toLong()

    /** A retry outside any session is a fresh attempt, and the host resets its own counter too. */
    fun resetAttempt(to: String) {
        seq.remove("$to|")
    }

    fun forgetSession(to: String, session: String) {
        seq.remove("$to|$session")
    }
}
