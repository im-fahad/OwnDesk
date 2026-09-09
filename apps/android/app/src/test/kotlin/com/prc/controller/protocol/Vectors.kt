package com.prc.controller.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.ECPrivateKeySpec

/** Loads the vectors that the TypeScript, Swift and Kotlin implementations all run. */
object Vectors {
    private val dir = File(System.getProperty("prc.vectors") ?: error("prc.vectors not set"))
    val json = Json { ignoreUnknownKeys = true }

    fun load(name: String): JsonElement = json.parseToJsonElement(File(dir, name).readText())
}

/**
 * A test-only identity built from a vector key. Real devices keep the private key in the Android
 * Keystore and can never export it, which is why this lives in the test source set alone.
 */
class TestIdentity(x: String, y: String, d: String) : SigningIdentity {
    private val privateKey = KeyFactory.getInstance("EC").generatePrivate(
        ECPrivateKeySpec(BigInteger(1, Encoding.b64urlDecode(d)), Identity.p256Params)
    )
    override val publicKeyRaw: ByteArray =
        byteArrayOf(0x04) + Encoding.b64urlDecode(x) + Encoding.b64urlDecode(y)
    override val deviceId: String = Identity.deviceId(publicKeyRaw)

    override fun sign(data: ByteArray): ByteArray {
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(privateKey)
        signer.update(data)
        return Identity.rawFromDer(signer.sign())
    }
}
