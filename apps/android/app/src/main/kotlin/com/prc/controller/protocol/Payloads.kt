package com.prc.controller.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The signaling payloads this controller sends or reads. Field names are the wire names, so the
 * JSON these produce is the JSON the schemas describe. Required fields have no defaults, which is
 * what makes a payload missing one fail to decode rather than arrive half empty.
 */

@Serializable
data class Capabilities(
    val codecs: List<String>,
    val max_height: Int,
    val max_fps: Int,
)

@Serializable
data class SessionRequestPayload(
    val client_nonce: String,
    val versions: List<Int>,
    val path: String,
    val capabilities: Capabilities,
)

@Serializable
data class SessionChallengePayload(
    val host_nonce: String,
    val client_nonce: String,
    val session_id: String,
    val version: Int,
    val expires_at: Long,
)

@Serializable
data class SessionAuthPayload(
    val client_nonce: String,
    val host_nonce: String,
)

@Serializable
data class DisplayInfo(
    val display_id: String,
    val width_px: Int,
    val height_px: Int,
    val scale: Double,
)

@Serializable
data class SessionAcceptPayload(
    val client_nonce: String,
    val host_nonce: String,
    val display: DisplayInfo,
    val resume_window_s: Int,
)

@Serializable
data class SessionRejectPayload(
    val reason: String,
)

@Serializable
data class SessionEndPayload(
    val reason: String? = null,
)

@Serializable
data class PairRequestPayload(
    val public_key: String,
    val device_name: String,
    val device_type: String,
    val pairing_session_id: String,
    val proof: String,
)

@Serializable
data class PairResultPayload(
    val approved: Boolean,
    val reason: String? = null,
    val host_public_key: String,
    val host_name: String,
    val rendezvous_url: String? = null,
)

/** The pairing payload shown by a Mac as a code or a QR image (spec section 7). */
@Serializable
data class QrPayload(
    val v: Int,
    val kind: String,
    val host_device_id: String,
    val host_key_hash: String,
    val host_name: String,
    val addresses: List<String>,
    val rendezvous_url: String? = null,
    val pairing_session_id: String,
    val pairing_code: String,
    val expires_at: Long,
) {
    fun validate() {
        if (kind != "prc-pair") throw ProtocolException("not a pairing payload")
        if (v != Envelope.PROTOCOL_VERSION) throw ProtocolException("unsupported pairing version")
        if (!host_device_id.matches(Regex("^[0-9a-f]{64}$"))) throw ProtocolException("host_device_id")
        if (host_key_hash != host_device_id) throw ProtocolException("host_key_hash")
        if (addresses.isEmpty()) throw ProtocolException("no addresses")
        if (!pairing_session_id.matches(BYTES16) || !pairing_code.matches(BYTES16)) throw ProtocolException("pairing secrets")
    }

    val pairingCodeBytes: ByteArray get() = Encoding.b64urlDecode(pairing_code)

    companion object {
        private val BYTES16 = Regex("^[A-Za-z0-9_-]{22}$")
    }
}

/** A Mac this phone has paired with. */
@Serializable
data class Peer(
    val deviceId: String,
    val publicKey: String,
    val name: String,
    val addresses: List<String>,
    @SerialName("paired_at") val pairedAt: Long,
    /** An address the owner chose by hand, such as a Tailscale one, tried before any other. */
    val preferred: String? = null,
    /** The address that worked last time, tried before the rest of the list. */
    val lastGood: String? = null,
) {
    val fingerprint: String get() = Identity.fingerprint(deviceId)

    /**
     * Every address worth trying, best first. A chosen address leads, then whatever worked last
     * time, then the ones the Mac advertised when pairing. The list is what gets probed, so a Mac
     * that moved between a home network and a tailnet is still found without anyone typing.
     */
    fun candidates(): List<String> =
        (listOfNotNull(preferred, lastGood) + addresses)
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
}
