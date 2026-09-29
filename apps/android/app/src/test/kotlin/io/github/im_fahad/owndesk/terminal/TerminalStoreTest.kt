package io.github.im_fahad.owndesk.terminal

import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Base64

class TerminalStoreTest {
    private val dir: File = Files.createTempDirectory("owndesk-terminal").toFile()
    private val store = TerminalStore(File(dir, "settings.json"), File(dir, "hosts.json"))

    private fun blob(type: String, key: ByteArray): ByteArray {
        val t = type.toByteArray()
        return byteArrayOf(0, 0, 0, t.size.toByte()) + t + byteArrayOf(0, 0, 0, key.size.toByte()) + key
    }

    @Test
    fun `settings are kept per Mac`() {
        assertNull(store.settings("mac-a"))
        store.saveSettings("mac-a", TerminalSettings("alice", 2222))
        store.saveSettings("mac-b", TerminalSettings("bob"))
        assertEquals(TerminalSettings("alice", 2222), store.settings("mac-a"))
        assertEquals(22, store.settings("mac-b")?.port)
        store.forget("mac-a")
        assertNull(store.settings("mac-a"))
        assertEquals("bob", store.settings("mac-b")?.username)
    }

    @Test
    fun `a host key is new, then known, then changed when it differs`() {
        val first = blob("ssh-ed25519", ByteArray(32) { 1 })
        val other = blob("ssh-ed25519", ByteArray(32) { 2 })
        val verdict = store.verdict("mac-a", first)
        assertTrue(verdict is HostKeyVerdict.New)
        assertEquals("ssh-ed25519", (verdict as HostKeyVerdict.New).type)
        assertTrue(verdict.fingerprint.startsWith("SHA256:"))
        store.pin("mac-a", first)
        assertEquals(HostKeyVerdict.Known, store.verdict("mac-a", first))
        assertTrue(store.verdict("mac-a", other) is HostKeyVerdict.Changed)
        assertEquals("ssh-ed25519", store.pinned("mac-a")?.type)
        assertTrue(store.verdict("mac-b", first) is HostKeyVerdict.New)
        store.forgetHostKey("mac-a")
        assertNull(store.pinned("mac-a"))
        assertTrue(store.verdict("mac-a", other) is HostKeyVerdict.New)
    }

    @Test
    fun `every host key a Mac vouched for is known, anything else is a change`() {
        val ed = blob("ssh-ed25519", ByteArray(32) { 5 })
        val ec = blob("ecdsa-sha2-nistp256", ByteArray(65) { 6 })
        val other = blob("ssh-ed25519", ByteArray(32) { 7 })
        fun line(b: ByteArray) = "${DeviceSshKey.typeOf(b)} ${Base64.getEncoder().encodeToString(b)}"
        store.pinAll("mac-a", listOf(line(ed), line(ec) + " comment dropped", line(ed)))
        assertEquals(HostKeyVerdict.Known, store.verdict("mac-a", ed))
        assertEquals(HostKeyVerdict.Known, store.verdict("mac-a", ec))
        assertTrue(store.verdict("mac-a", other) is HostKeyVerdict.Changed)
        assertEquals(2, store.pinnedAll("mac-a").size)
        assertEquals("ssh-ed25519", store.pinned("mac-a")?.type)
        store.forgetHostKey("mac-a")
        assertTrue(store.pinnedAll("mac-a").isEmpty())
    }

    @Test
    fun `the repository the SSH library sees answers with the verdict and pins on add`() {
        val key = blob("ecdsa-sha2-nistp256", ByteArray(65) { 3 })
        val repository = store.repositoryFor("mac-a")
        assertEquals(HostKeyRepository.NOT_INCLUDED, repository.check("192.168.1.20", key))
        assertTrue(repository.lastVerdict is HostKeyVerdict.New)
        repository.add(HostKey("192.168.1.20", key), null)
        assertEquals(HostKeyRepository.OK, repository.check("192.168.1.20", key))
        assertEquals(HostKeyVerdict.Known, repository.lastVerdict)
        val changed = blob("ecdsa-sha2-nistp256", ByteArray(65) { 4 })
        assertEquals(HostKeyRepository.CHANGED, repository.check("192.168.1.20", changed))
        assertTrue(repository.lastVerdict is HostKeyVerdict.Changed)
        assertEquals(Base64.getEncoder().encodeToString(key), Base64.getEncoder().encodeToString(store.pinned("mac-a")!!.blob))
    }
}
