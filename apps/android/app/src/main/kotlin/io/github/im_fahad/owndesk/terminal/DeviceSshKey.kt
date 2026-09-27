package io.github.im_fahad.owndesk.terminal

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import com.jcraft.jsch.Identity
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Base64

/**
 * This phone's SSH key: the key a Mac's `authorized_keys` lists to let it log in.
 *
 * It is a key of its own, not the phone's OwnDesk identity. The two sign for different protocols,
 * and keeping them apart means nothing signed for one can ever be replayed as the other.
 *
 * P-256 in the Android Keystore, where the private key is generated and cannot be read out: the
 * same promise the iPhone gets from its Secure Enclave. OpenSSH knows it as `ecdsa-sha2-nistp256`.
 * The SSH library only ever asks it to sign, which is what [Identity] is for.
 */
class DeviceSshKey private constructor(
    private val privateKey: PrivateKey,
    val publicKey: ECPublicKey,
    /** "hardware" when the key lives in a secure element or TEE, "software" otherwise. */
    val storage: String,
) : Identity {

    private val blob: ByteArray = publicKeyBlob(publicKey)

    /** OpenSSH's fingerprint, as `ssh-keygen -l` prints it. */
    val fingerprint: String get() = fingerprint(blob)

    /** The line for a Mac's `~/.ssh/authorized_keys`: type, key and a comment naming this phone. */
    fun authorizedKeysLine(comment: String): String {
        val clean = comment.replace('\n', ' ').trim()
        val line = "$ALGORITHM ${Base64.getEncoder().encodeToString(blob)}"
        return if (clean.isEmpty()) line else "$line $clean"
    }

    override fun setPassphrase(passphrase: ByteArray?): Boolean = true

    override fun getPublicKeyBlob(): ByteArray = blob

    override fun getSignature(data: ByteArray): ByteArray = getSignature(data, ALGORITHM)

    override fun getSignature(data: ByteArray, alg: String): ByteArray {
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(privateKey)
        signer.update(data)
        return signatureBlob(signer.sign())
    }

    @Deprecated("JSch keeps this on the interface; nothing here is encrypted")
    override fun decrypt(): Boolean = true

    override fun getAlgName(): String = ALGORITHM

    override fun getName(): String = "owndesk-terminal"

    override fun isEncrypted(): Boolean = false

    override fun clear() {}

    companion object {
        const val ALGORITHM = "ecdsa-sha2-nistp256"
        private const val CURVE = "nistp256"
        private const val ALIAS = "owndesk-terminal-key"

        /** Loads the key, creating it on first use. */
        fun load(): DeviceSshKey {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val entry = store.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry ?: return create()
            return DeviceSshKey(entry.privateKey, entry.certificate.publicKey as ECPublicKey, storageOf(entry.privateKey))
        }

        private fun create(): DeviceSshKey {
            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            generator.initialize(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .build()
            )
            val pair = generator.generateKeyPair()
            return DeviceSshKey(pair.private, pair.public as ECPublicKey, storageOf(pair.private))
        }

        private fun storageOf(key: PrivateKey): String = try {
            val factory = KeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
            @Suppress("DEPRECATION")
            if (factory.getKeySpec(key, KeyInfo::class.java).isInsideSecureHardware) "hardware" else "software"
        } catch (e: Exception) {
            "software"
        }

        /** RFC 5656: string "ecdsa-sha2-nistp256", string "nistp256", string Q where Q is 0x04 ‖ X ‖ Y. */
        fun publicKeyBlob(key: ECPublicKey): ByteArray {
            val point = ByteArrayOutputStream().apply {
                write(4)
                write(fixed(key.w.affineX, 32))
                write(fixed(key.w.affineY, 32))
            }.toByteArray()
            return ByteArrayOutputStream().apply {
                writeString(ALGORITHM.toByteArray())
                writeString(CURVE.toByteArray())
                writeString(point)
            }.toByteArray()
        }

        /**
         * The signature as SSH wants it: string "ecdsa-sha2-nistp256", string (mpint r ‖ mpint s).
         * Java hands back DER, a SEQUENCE of two INTEGERs, which is the same two numbers in a
         * different wrapper.
         */
        fun signatureBlob(der: ByteArray): ByteArray {
            val (r, s) = derIntegers(der)
            val inner = ByteArrayOutputStream().apply {
                writeString(mpint(r))
                writeString(mpint(s))
            }.toByteArray()
            return ByteArrayOutputStream().apply {
                writeString(ALGORITHM.toByteArray())
                writeString(inner)
            }.toByteArray()
        }

        /** "SHA256:" and the unpadded base64 of the SHA-256 of the key's wire encoding. */
        fun fingerprint(blob: ByteArray): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(blob)
            return "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(digest)
        }

        /** The SSH key type named at the front of a wire-encoded public key. */
        fun typeOf(blob: ByteArray): String {
            if (blob.size < 4) return ""
            val length = ((blob[0].toInt() and 0xFF) shl 24) or ((blob[1].toInt() and 0xFF) shl 16) or
                ((blob[2].toInt() and 0xFF) shl 8) or (blob[3].toInt() and 0xFF)
            if (length < 0 || 4 + length > blob.size) return ""
            return String(blob, 4, length, Charsets.US_ASCII)
        }

        private fun derIntegers(der: ByteArray): Pair<BigInteger, BigInteger> {
            var index = 0
            require(der[index++] == 0x30.toByte()) { "not a DER sequence" }
            index += lengthBytes(der, index)
            require(der[index++] == 0x02.toByte()) { "no r" }
            val rLength = readLength(der, index)
            index += lengthBytes(der, index)
            val r = BigInteger(1, der.copyOfRange(index, index + rLength))
            index += rLength
            require(der[index++] == 0x02.toByte()) { "no s" }
            val sLength = readLength(der, index)
            index += lengthBytes(der, index)
            val s = BigInteger(1, der.copyOfRange(index, index + sLength))
            return r to s
        }

        private fun readLength(der: ByteArray, index: Int): Int {
            val first = der[index].toInt() and 0xFF
            if (first < 0x80) return first
            var length = 0
            for (i in 1..(first and 0x7F)) length = (length shl 8) or (der[index + i].toInt() and 0xFF)
            return length
        }

        private fun lengthBytes(der: ByteArray, index: Int): Int {
            val first = der[index].toInt() and 0xFF
            return if (first < 0x80) 1 else 1 + (first and 0x7F)
        }

        /** SSH's mpint: big-endian two's complement, shortest form, no leading zero unless needed. */
        private fun mpint(value: BigInteger): ByteArray = value.toByteArray()

        private fun fixed(value: BigInteger, size: Int): ByteArray {
            val raw = value.toByteArray()
            if (raw.size == size) return raw
            val out = ByteArray(size)
            if (raw.size > size) {
                System.arraycopy(raw, raw.size - size, out, 0, size)
            } else {
                System.arraycopy(raw, 0, out, size - raw.size, raw.size)
            }
            return out
        }

        private fun ByteArrayOutputStream.writeString(bytes: ByteArray) {
            write(bytes.size ushr 24)
            write(bytes.size ushr 16)
            write(bytes.size ushr 8)
            write(bytes.size)
            write(bytes)
        }
    }
}
