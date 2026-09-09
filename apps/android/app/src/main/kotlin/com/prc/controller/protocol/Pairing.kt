package com.prc.controller.protocol

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Pairing proof (spec section 7): possession of the code the Mac displayed, nothing more. */
object Pairing {
    const val CONTEXT = "prc-pairing-v1"

    fun proofInput(pairingSessionId: String, controllerDeviceId: String): ByteArray =
        Encoding.utf8("$CONTEXT\n$pairingSessionId\n$controllerDeviceId")

    fun proof(pairingCode: ByteArray, pairingSessionId: String, controllerDeviceId: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(pairingCode, "HmacSHA256"))
        return Encoding.b64url(mac.doFinal(proofInput(pairingSessionId, controllerDeviceId)))
    }
}
