package com.prc.controller.device

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.prc.controller.protocol.Identity
import com.prc.controller.protocol.SigningIdentity
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * This phone's identity, held in the Android Keystore. The private key is generated there and
 * cannot be read out, which is the same promise the Macs get from the Secure Enclave: losing the
 * app's files cannot leak the key, and a pairing is only ever as good as the hardware holding it.
 */
class KeystoreIdentity private constructor(
    private val privateKey: PrivateKey,
    override val publicKeyRaw: ByteArray,
) : SigningIdentity {

    override val deviceId: String = Identity.deviceId(publicKeyRaw)

    val fingerprint: String get() = Identity.fingerprint(deviceId)

    override fun sign(data: ByteArray): ByteArray {
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(privateKey)
        signer.update(data)
        return Identity.rawFromDer(signer.sign())
    }

    companion object {
        private const val ALIAS = "prc-device-identity"

        /** Loads the identity, creating it on first run. */
        fun load(): KeystoreIdentity {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val entry = store.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry ?: return create()
            return KeystoreIdentity(entry.privateKey, Identity.publicKeyRaw(entry.certificate.publicKey))
        }

        private fun create(): KeystoreIdentity {
            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            generator.initialize(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .build()
            )
            val pair = generator.generateKeyPair()
            return KeystoreIdentity(pair.private, Identity.publicKeyRaw(pair.public))
        }

        /** What the Macs will show next to this phone's fingerprint. */
        fun deviceName(context: Context): String {
            val chosen = Settings.Global.getString(context.contentResolver, "device_name")
            val name = chosen?.takeIf { it.isNotBlank() } ?: "${Build.MANUFACTURER} ${Build.MODEL}"
            return name.trim().take(64)
        }
    }
}
