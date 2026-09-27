package io.github.im_fahad.owndesk.terminal

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.Base64

/** The wire encodings, checked with a software key: the Keystore only exists on a phone. */
class DeviceSshKeyTest {
    private val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    private fun readString(bytes: ByteArray, at: Int): Pair<ByteArray, Int> {
        val length = ((bytes[at].toInt() and 0xFF) shl 24) or ((bytes[at + 1].toInt() and 0xFF) shl 16) or
            ((bytes[at + 2].toInt() and 0xFF) shl 8) or (bytes[at + 3].toInt() and 0xFF)
        return bytes.copyOfRange(at + 4, at + 4 + length) to at + 4 + length
    }

    @Test
    fun `public key blob is the RFC 5656 form`() {
        val blob = DeviceSshKey.publicKeyBlob(pair.public as ECPublicKey)
        val (type, afterType) = readString(blob, 0)
        val (curve, afterCurve) = readString(blob, afterType)
        val (point, end) = readString(blob, afterCurve)
        assertEquals("ecdsa-sha2-nistp256", String(type))
        assertEquals("nistp256", String(curve))
        assertEquals(65, point.size)
        assertEquals(4, point[0].toInt())
        assertEquals(blob.size, end)
        assertEquals("ecdsa-sha2-nistp256", DeviceSshKey.typeOf(blob))
        val x = BigInteger(1, point.copyOfRange(1, 33))
        assertEquals((pair.public as ECPublicKey).w.affineX, x)
    }

    @Test
    fun `fingerprint looks like ssh-keygen's`() {
        val blob = DeviceSshKey.publicKeyBlob(pair.public as ECPublicKey)
        val fingerprint = DeviceSshKey.fingerprint(blob)
        assertTrue(fingerprint.startsWith("SHA256:"))
        assertEquals(43, fingerprint.removePrefix("SHA256:").length)
        assertTrue(!fingerprint.endsWith("="))
    }

    @Test
    fun `a DER signature becomes an SSH signature and still verifies`() {
        val data = "the exchange hash".toByteArray()
        val signer = Signature.getInstance("SHA256withECDSA").apply { initSign(pair.private); update(data) }
        val der = signer.sign()
        val blob = DeviceSshKey.signatureBlob(der)
        val (type, afterType) = readString(blob, 0)
        val (inner, end) = readString(blob, afterType)
        assertEquals("ecdsa-sha2-nistp256", String(type))
        assertEquals(blob.size, end)
        val (r, afterR) = readString(inner, 0)
        val (s, innerEnd) = readString(inner, afterR)
        assertEquals(inner.size, innerEnd)
        // Rebuild DER from r and s and check the signature is the same one.
        val rebuilt = ByteArrayOutputStream().apply {
            val body = ByteArrayOutputStream().apply {
                write(2); write(r.size); write(r)
                write(2); write(s.size); write(s)
            }.toByteArray()
            write(0x30); write(body.size); write(body)
        }.toByteArray()
        val verifier = Signature.getInstance("SHA256withECDSA").apply { initVerify(pair.public); update(data) }
        assertTrue(verifier.verify(rebuilt))
        // Shortest form: no leading zero unless the top bit needs one.
        assertTrue(r[0].toInt() != 0 || (r[1].toInt() and 0x80) != 0)
    }

    @Test
    fun `type of a blob is read from its front`() {
        val blob = ByteArrayOutputStream().apply {
            write(0); write(0); write(0); write(11); write("ssh-ed25519".toByteArray())
            write(0); write(0); write(0); write(2); write(byteArrayOf(1, 2))
        }.toByteArray()
        assertEquals("ssh-ed25519", DeviceSshKey.typeOf(blob))
        assertEquals("", DeviceSshKey.typeOf(byteArrayOf(0, 0)))
        assertEquals("", DeviceSshKey.typeOf(byteArrayOf(0, 0, 0, 9, 65)))
    }

    @Test
    fun `base64 of the blob round-trips`() {
        val blob = DeviceSshKey.publicKeyBlob(pair.public as ECPublicKey)
        assertArrayEquals(blob, Base64.getDecoder().decode(Base64.getEncoder().encodeToString(blob)))
    }
}
