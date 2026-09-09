package com.prc.controller.protocol

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.PublicKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec

/**
 * Device identity: ECDSA P-256 with SHA-256 (spec section 5.2).
 *
 *   public key  = 65-byte X9.63 uncompressed point, base64url
 *   device id   = lowercase hex SHA-256 of those 65 bytes
 *   fingerprint = first 12 hex characters as XXXX-XXXX-XXXX, upper case
 *   signature   = raw r||s, 64 bytes, base64url
 *
 * Java speaks DER for ECDSA signatures and structured keys, so this file is mostly the translation
 * between that and the wire encodings, which are the same on every platform.
 */
object Identity {
    const val PUBLIC_KEY_BYTES = 65
    const val SIGNATURE_BYTES = 64
    private const val FIELD_BYTES = 32

    val p256Params: ECParameterSpec by lazy {
        val params = AlgorithmParameters.getInstance("EC")
        params.init(ECGenParameterSpec("secp256r1"))
        params.getParameterSpec(ECParameterSpec::class.java)
    }

    fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    fun deviceId(publicKeyRaw: ByteArray): String {
        require(publicKeyRaw)
        return Encoding.hex(sha256(publicKeyRaw))
    }

    fun require(publicKeyRaw: ByteArray) {
        if (publicKeyRaw.size != PUBLIC_KEY_BYTES || publicKeyRaw[0] != 0x04.toByte()) {
            throw ProtocolException("invalid_public_key")
        }
    }

    fun fingerprint(deviceId: String): String {
        if (!deviceId.matches(Regex("^[0-9a-f]{64}$"))) throw ProtocolException("invalid_device_id")
        val h = deviceId.substring(0, 12).uppercase()
        return "${h.substring(0, 4)}-${h.substring(4, 8)}-${h.substring(8, 12)}"
    }

    /** The 65-byte point for a Java public key. */
    fun publicKeyRaw(key: PublicKey): ByteArray {
        val point = (key as java.security.interfaces.ECPublicKey).w
        val out = ByteArray(PUBLIC_KEY_BYTES)
        out[0] = 0x04
        fieldBytes(point.affineX).copyInto(out, 1)
        fieldBytes(point.affineY).copyInto(out, 1 + FIELD_BYTES)
        return out
    }

    fun publicKey(raw: ByteArray): PublicKey {
        require(raw)
        val x = BigInteger(1, raw.copyOfRange(1, 1 + FIELD_BYTES))
        val y = BigInteger(1, raw.copyOfRange(1 + FIELD_BYTES, PUBLIC_KEY_BYTES))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), p256Params))
    }

    fun publicKeyFromB64(b64: String): PublicKey = publicKey(Encoding.b64urlDecode(b64))

    fun verify(publicKey: PublicKey, data: ByteArray, signatureRaw: ByteArray): Boolean {
        if (signatureRaw.size != SIGNATURE_BYTES) return false
        return try {
            val verifier = Signature.getInstance("SHA256withECDSA")
            verifier.initVerify(publicKey)
            verifier.update(data)
            verifier.verify(derFromRaw(signatureRaw))
        } catch (e: Exception) {
            false
        }
    }

    private fun fieldBytes(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == FIELD_BYTES -> bytes
            // A leading zero byte appears whenever the high bit is set; drop it.
            bytes.size > FIELD_BYTES -> bytes.copyOfRange(bytes.size - FIELD_BYTES, bytes.size)
            else -> ByteArray(FIELD_BYTES).also { bytes.copyInto(it, FIELD_BYTES - bytes.size) }
        }
    }

    /** DER SEQUENCE { INTEGER r, INTEGER s } to the fixed 64 bytes the wire format uses. */
    fun rawFromDer(der: ByteArray): ByteArray {
        var i = 0
        if (der[i++] != 0x30.toByte()) throw ProtocolException("bad_signature")
        var length = der[i++].toInt() and 0xFF
        if (length and 0x80 != 0) {
            val n = length and 0x7F
            length = 0
            repeat(n) { length = (length shl 8) or (der[i++].toInt() and 0xFF) }
        }
        fun integer(): ByteArray {
            if (der[i++] != 0x02.toByte()) throw ProtocolException("bad_signature")
            val len = der[i++].toInt() and 0xFF
            val value = der.copyOfRange(i, i + len)
            i += len
            return value
        }
        val r = integer()
        val s = integer()
        val out = ByteArray(SIGNATURE_BYTES)
        fieldBytes(BigInteger(1, r)).copyInto(out, 0)
        fieldBytes(BigInteger(1, s)).copyInto(out, FIELD_BYTES)
        return out
    }

    fun derFromRaw(raw: ByteArray): ByteArray {
        val r = derInteger(raw.copyOfRange(0, FIELD_BYTES))
        val s = derInteger(raw.copyOfRange(FIELD_BYTES, SIGNATURE_BYTES))
        val body = r + s
        return byteArrayOf(0x30, body.size.toByte()) + body
    }

    private fun derInteger(value: ByteArray): ByteArray {
        var start = 0
        while (start < value.size - 1 && value[start] == 0.toByte()) start++
        var body = value.copyOfRange(start, value.size)
        // DER integers are signed, so a leading high bit needs a zero byte in front.
        if (body[0].toInt() and 0x80 != 0) body = byteArrayOf(0) + body
        return byteArrayOf(0x02, body.size.toByte()) + body
    }
}

/** Something that can sign for this device. The Keystore and the test key both provide it. */
interface SigningIdentity {
    val deviceId: String
    val publicKeyRaw: ByteArray
    val publicKeyB64: String get() = Encoding.b64url(publicKeyRaw)

    /** Returns the raw 64-byte r||s signature. */
    fun sign(data: ByteArray): ByteArray
}
