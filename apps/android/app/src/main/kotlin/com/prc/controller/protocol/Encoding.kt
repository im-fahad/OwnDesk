package com.prc.controller.protocol

import java.security.SecureRandom

/** Encodings shared by every implementation of the protocol (spec section 5.2). */
object Encoding {
    private val B64URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    fun utf8(s: String): ByteArray = s.toByteArray(Charsets.UTF_8)

    /** Rejects malformed input rather than substituting replacement characters. */
    fun utf8Decode(bytes: ByteArray): String {
        val decoder = Charsets.UTF_8.newDecoder()
        return try {
            decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        } catch (e: Exception) {
            throw ProtocolException("invalid_utf8")
        }
    }

    /** base64url without padding, RFC 4648 section 5. */
    fun b64url(bytes: ByteArray): String {
        val out = StringBuilder((bytes.size * 4 + 2) / 3)
        var i = 0
        while (i + 2 < bytes.size) {
            val n = (bytes[i].toInt() and 0xFF shl 16) or (bytes[i + 1].toInt() and 0xFF shl 8) or (bytes[i + 2].toInt() and 0xFF)
            out.append(B64URL_ALPHABET[n ushr 18 and 63]).append(B64URL_ALPHABET[n ushr 12 and 63])
            out.append(B64URL_ALPHABET[n ushr 6 and 63]).append(B64URL_ALPHABET[n and 63])
            i += 3
        }
        when (bytes.size - i) {
            1 -> {
                val n = bytes[i].toInt() and 0xFF shl 16
                out.append(B64URL_ALPHABET[n ushr 18 and 63]).append(B64URL_ALPHABET[n ushr 12 and 63])
            }
            2 -> {
                val n = (bytes[i].toInt() and 0xFF shl 16) or (bytes[i + 1].toInt() and 0xFF shl 8)
                out.append(B64URL_ALPHABET[n ushr 18 and 63]).append(B64URL_ALPHABET[n ushr 12 and 63])
                out.append(B64URL_ALPHABET[n ushr 6 and 63])
            }
        }
        return out.toString()
    }

    fun b64urlDecode(s: String): ByteArray {
        if (s.length % 4 == 1) throw ProtocolException("invalid_base64url")
        val values = IntArray(s.length)
        for (i in s.indices) {
            val v = B64URL_ALPHABET.indexOf(s[i])
            if (v < 0) throw ProtocolException("invalid_base64url")
            values[i] = v
        }
        val out = ByteArray(s.length * 3 / 4)
        var o = 0
        var i = 0
        while (i + 3 < values.size) {
            val n = (values[i] shl 18) or (values[i + 1] shl 12) or (values[i + 2] shl 6) or values[i + 3]
            out[o++] = (n ushr 16).toByte(); out[o++] = (n ushr 8 and 0xFF).toByte(); out[o++] = (n and 0xFF).toByte()
            i += 4
        }
        when (values.size - i) {
            2 -> out[o] = ((values[i] shl 2) or (values[i + 1] ushr 4)).toByte()
            3 -> {
                out[o++] = ((values[i] shl 2) or (values[i + 1] ushr 4)).toByte()
                out[o] = ((values[i + 1] shl 4) or (values[i + 2] ushr 2)).toByte()
            }
        }
        return out
    }

    fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            out.append("0123456789abcdef"[v ushr 4]).append("0123456789abcdef"[v and 15])
        }
        return out.toString()
    }

    fun hexDecode(hex: String): ByteArray {
        if (hex.length % 2 != 0) throw ProtocolException("invalid_hex")
        val out = ByteArray(hex.length / 2)
        for (i in out.indices) {
            val v = hex.substring(i * 2, i * 2 + 2).toIntOrNull(16) ?: throw ProtocolException("invalid_hex")
            out[i] = v.toByte()
        }
        return out
    }

    /** Length mismatch returns false at once, which leaks only the length. */
    fun constantTimeEqual(a: ByteArray, b: ByteArray): Boolean {
        if (a.size != b.size) return false
        var diff = 0
        for (i in a.indices) diff = diff or (a[i].toInt() xor b[i].toInt())
        return diff == 0
    }

    private val random = SecureRandom()

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }
}

class ProtocolException(val reason: String) : Exception(reason)
