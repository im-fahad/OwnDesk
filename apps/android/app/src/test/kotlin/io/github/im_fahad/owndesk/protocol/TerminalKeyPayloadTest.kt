package io.github.im_fahad.owndesk.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The phone's copy of TERMINAL_KEY_REQUEST and TERMINAL_KEY_RESULT refuses what the schemas refuse. */
class TerminalKeyPayloadTest {
    private val key = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY="

    private fun request(text: String) = runCatching { TerminalKeyRequestPayload(text) }.isSuccess

    @Test
    fun `a request carries a key and nothing else`() {
        assertTrue(request(key))
        assertTrue(request("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA=="))
        for (bad in listOf("command=\"id\" $key", "$key comment", "$key\n$key", "ssh-rsa AAAA", "ssh-ed25519 ", "x".repeat(900)))
            assertFalse(bad, request(bad))
    }

    @Test
    fun `a result is read with the envelope's own JSON rules`() {
        val json = """{"status":"installed","username":"alice","host_keys":["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA=="]}"""
        val result = Envelope.json.decodeFromString(TerminalKeyResultPayload.serializer(), json)
        assertTrue(result.granted)
        assertEquals("alice", result.username)
        val denied = Envelope.json.decodeFromString(TerminalKeyResultPayload.serializer(), """{"status":"denied","username":"","host_keys":[]}""")
        assertFalse(denied.granted)
        for (bad in listOf(
            """{"status":"maybe","username":"","host_keys":[]}""",
            """{"status":"installed","username":"a b","host_keys":[]}""",
            """{"status":"installed","username":"a","host_keys":["ssh-ed25519 AAAA comment"]}""",
            """{"status":"installed","username":"a"}""",
        )) assertFalse(bad, runCatching { Envelope.json.decodeFromString(TerminalKeyResultPayload.serializer(), bad) }.isSuccess)
    }
}
