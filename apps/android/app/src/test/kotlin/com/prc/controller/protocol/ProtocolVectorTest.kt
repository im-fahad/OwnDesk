package com.prc.controller.protocol

import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.PublicKey

/**
 * These run the protocol package's shared vectors. If the phone disagrees with them it disagrees
 * with both Macs, so this is the check that matters most in this module.
 */
class ProtocolVectorTest {

    @Test
    fun `device ids and fingerprints match the vectors`() {
        val keys = Vectors.load("identity.json").jsonObject["keys"]!!.jsonObject
        assertTrue(keys.isNotEmpty())
        for ((name, entry) in keys) {
            val o = entry.jsonObject
            val raw = Encoding.b64urlDecode(o["public_key"]!!.jsonPrimitive.content)
            assertEquals("device id for $name", o["device_id"]!!.jsonPrimitive.content, Identity.deviceId(raw))
            assertEquals("fingerprint for $name", o["fingerprint"]!!.jsonPrimitive.content, Identity.fingerprint(Identity.deviceId(raw)))
        }
    }

    @Test
    fun `malformed public keys are refused`() {
        val bad = Vectors.load("identity.json").jsonObject["invalid_public_keys"]!!.jsonArray
        assertTrue(bad.isNotEmpty())
        for (entry in bad) {
            val encoded = entry.jsonObject["public_key"]!!.jsonPrimitive.content
            var rejected = false
            try {
                Identity.publicKey(Encoding.b64urlDecode(encoded))
            } catch (e: Exception) {
                rejected = true
            }
            assertTrue("should reject: ${entry.jsonObject["why"]?.jsonPrimitive?.contentOrNull}", rejected)
        }
    }

    @Test
    fun `the signing input is byte for byte the shared one`() {
        val v = Vectors.load("signing-input.json").jsonObject
        val u = v["unsigned"]!!.jsonObject
        val input = Envelope.signingInput(
            v = u["v"]!!.jsonPrimitive.int(),
            type = u["type"]!!.jsonPrimitive.content,
            from = u["from"]!!.jsonPrimitive.content,
            to = u["to"]!!.jsonPrimitive.content,
            session = u["session"]!!.jsonPrimitive.content,
            seq = u["seq"]!!.jsonPrimitive.long(),
            ts = u["ts"]!!.jsonPrimitive.long(),
            payload = u["payload"]!!.jsonPrimitive.content,
        )
        assertEquals(v["signing_input"]!!.jsonPrimitive.content, Encoding.utf8Decode(input))
        assertEquals(
            v["signing_input_sha256_hex"]!!.jsonPrimitive.content,
            Encoding.hex(Identity.sha256(input)),
        )
        // The payload in the vector is the base64url of exactly this JSON.
        assertEquals(u["payload"]!!.jsonPrimitive.content, Envelope.encodePayload(v["payload_json"]!!.jsonPrimitive.content))
    }

    @Test
    fun `the pairing proof matches`() {
        val v = Vectors.load("pairing.json").jsonObject
        val proof = Pairing.proof(
            Encoding.b64urlDecode(v["pairing_code"]!!.jsonPrimitive.content),
            v["pairing_session_id"]!!.jsonPrimitive.content,
            v["controller_device_id"]!!.jsonPrimitive.content,
        )
        assertEquals(v["proof"]!!.jsonPrimitive.content, proof)
        assertEquals(
            v["proof_input"]!!.jsonPrimitive.content,
            Encoding.utf8Decode(Pairing.proofInput(v["pairing_session_id"]!!.jsonPrimitive.content, v["controller_device_id"]!!.jsonPrimitive.content)),
        )
    }

    @Test
    fun `the receiver accepts and rejects exactly what the vectors say`() {
        val v = Vectors.load("envelopes.json").jsonObject
        val cfg = v["receiver"]!!.jsonObject
        val trusted = HashMap<String, PublicKey>()
        for ((id, key) in cfg["trusted"]!!.jsonObject) {
            trusted[id] = Identity.publicKeyFromB64(key.jsonPrimitive.content)
        }
        val now = cfg["now_ms"]!!.jsonPrimitive.long()
        val receiver = EnvelopeReceiver(
            selfDeviceId = cfg["self_device_id"]!!.jsonPrimitive.content,
            resolveKey = { trusted[it] },
            now = { now },
            acceptPairRequests = cfg["accept_pair_requests"]?.jsonPrimitive?.booleanOrNull ?: false,
        )

        val cases = v["cases"]!!.jsonArray
        assertTrue(cases.size >= 16)
        for (case in cases) {
            val o = case.jsonObject
            val name = o["name"]!!.jsonPrimitive.content
            val raw = Envelope.json.encodeToString(kotlinx.serialization.json.JsonObject.serializer(), o["envelope"]!!.jsonObject)
            when (val result = receiver.receive(raw)) {
                // A case expects either "ok" or the exact rejection reason.
                is ReceiveResult.Accepted -> assertEquals("case: $name", "ok", o["expect"]!!.jsonPrimitive.content)
                is ReceiveResult.Rejected -> assertEquals("case: $name", o["expect"]!!.jsonPrimitive.content, result.reason)
            }
        }
    }

    @Test
    fun `a signature this phone makes verifies, and a tampered one does not`() {
        val keys = Vectors.load("test-keys.json").jsonObject["keys"]!!.jsonObject["controller"]!!.jsonObject
        val identity = TestIdentity(
            keys["x"]!!.jsonPrimitive.content, keys["y"]!!.jsonPrimitive.content, keys["d"]!!.jsonPrimitive.content,
        )
        val expected = Vectors.load("identity.json").jsonObject["keys"]!!.jsonObject["controller"]!!.jsonObject
        assertEquals(expected["device_id"]!!.jsonPrimitive.content, identity.deviceId)

        val sender = EnvelopeSender(identity) { 1_757_203_200_000L }
        val envelope = sender.build("SESSION_AUTH", "0".repeat(64), "abc", """{"client_nonce":"A","host_nonce":"B"}""")
        val key = Identity.publicKey(identity.publicKeyRaw)
        assertTrue(Identity.verify(key, envelope.signingInput(), Encoding.b64urlDecode(envelope.sig)))

        val tampered = envelope.copy(seq = envelope.seq + 1)
        assertFalse(Identity.verify(key, tampered.signingInput(), Encoding.b64urlDecode(envelope.sig)))
    }

    @Test
    fun `seq counts up per recipient and session`() {
        val keys = Vectors.load("test-keys.json").jsonObject["keys"]!!.jsonObject["controller"]!!.jsonObject
        val identity = TestIdentity(keys["x"]!!.jsonPrimitive.content, keys["y"]!!.jsonPrimitive.content, keys["d"]!!.jsonPrimitive.content)
        val sender = EnvelopeSender(identity)
        val to = "1".repeat(64)
        assertEquals(1L, sender.build("SESSION_REQUEST", to, "", "{}").seq)
        assertEquals(2L, sender.build("SESSION_REQUEST", to, "", "{}").seq)
        assertEquals(1L, sender.build("SESSION_AUTH", to, "s1", "{}").seq)
        sender.resetAttempt(to)
        assertEquals(1L, sender.build("SESSION_REQUEST", to, "", "{}").seq)
    }
}

private fun kotlinx.serialization.json.JsonPrimitive.int(): Int = content.toInt()
private fun kotlinx.serialization.json.JsonPrimitive.long(): Long = content.toLong()
