package io.github.im_fahad.owndesk.terminal

import android.content.Context
import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.UserInfo
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.io.File
import java.util.Base64

/** How to log in to a Mac's terminal: its user name there, and the port its SSH server listens on. */
@Serializable
data class TerminalSettings(val username: String, val port: Int = 22)

/** What to do with a host key the server presented. */
sealed class HostKeyVerdict {
    /** The pinned key: go ahead. */
    object Known : HostKeyVerdict()

    /** Nothing is pinned for this Mac yet: ask the person, showing the fingerprint. */
    data class New(val type: String, val fingerprint: String) : HostKeyVerdict()

    /** A different key from the pinned one: refuse. */
    data class Changed(val type: String, val fingerprint: String) : HostKeyVerdict()
}

/** A Mac's SSH host key as the app remembers it: its type and its wire encoding. */
data class PinnedHostKey(val type: String, val blob: ByteArray) {
    val fingerprint: String get() = DeviceSshKey.fingerprint(blob)
}

/**
 * What the terminal remembers about each Mac, by its OwnDesk device id: how to log in, and the SSH
 * host key it presented the first time. Small enough to read and write whole on every call, so two
 * screens never disagree.
 *
 * SSH's defence against someone in the middle is that the client knows the server's key. The first
 * time it cannot, so the person is shown the fingerprint and decides; after that the key is pinned,
 * and a different one is refused outright rather than asked about, because a changed host key is
 * exactly what an interception looks like.
 */
class TerminalStore(private val settingsFile: File, private val hostsFile: File) {
    constructor(context: Context) : this(
        File(context.filesDir, "terminal-settings.json"),
        File(context.filesDir, "known-hosts.json"),
    )

    fun settings(deviceId: String): TerminalSettings? = synchronized(lock) { loadSettings()[deviceId] }

    fun saveSettings(deviceId: String, settings: TerminalSettings) = synchronized(lock) {
        val all = loadSettings().toMutableMap()
        all[deviceId] = settings
        settingsFile.writeText(json.encodeToString(settingsSerializer, all))
    }

    fun verdict(deviceId: String, blob: ByteArray): HostKeyVerdict {
        val type = DeviceSshKey.typeOf(blob)
        val fingerprint = DeviceSshKey.fingerprint(blob)
        val pinned = pinnedAll(deviceId)
        if (pinned.isEmpty()) return HostKeyVerdict.New(type, fingerprint)
        return if (pinned.any { it.blob.contentEquals(blob) }) HostKeyVerdict.Known else HostKeyVerdict.Changed(type, fingerprint)
    }

    /**
     * Pins every key a Mac vouched for in a signed answer, "type base64" each, replacing what was
     * pinned before. Which one a connection ends up using depends on what the two sides negotiate.
     * Kept as lines of one string, so a file with a single pinned key reads the same.
     */
    fun pinAll(deviceId: String, openSsh: List<String>) = synchronized(lock) {
        val lines = openSsh.map { it.trim().split(' ') }.filter { it.size >= 2 }.map { "${it[0]} ${it[1]}" }.distinct()
        if (lines.isEmpty()) return@synchronized
        val all = loadHosts().toMutableMap()
        all[deviceId] = lines.joinToString("\n")
        hostsFile.writeText(json.encodeToString(hostsSerializer, all))
    }

    fun pin(deviceId: String, blob: ByteArray) = synchronized(lock) {
        val all = loadHosts().toMutableMap()
        all[deviceId] = "${DeviceSshKey.typeOf(blob)} ${Base64.getEncoder().encodeToString(blob)}"
        hostsFile.writeText(json.encodeToString(hostsSerializer, all))
    }

    fun pinned(deviceId: String): PinnedHostKey? = pinnedAll(deviceId).firstOrNull()

    fun pinnedAll(deviceId: String): List<PinnedHostKey> = synchronized(lock) {
        val text = loadHosts()[deviceId] ?: return emptyList()
        text.split('\n').mapNotNull { line ->
            val fields = line.trim().split(' ')
            if (fields.size < 2) return@mapNotNull null
            val blob = runCatching { Base64.getDecoder().decode(fields[1]) }.getOrNull() ?: return@mapNotNull null
            PinnedHostKey(fields[0], blob)
        }
    }

    /** Forgets the pinned key, so the next terminal asks again. */
    fun forgetHostKey(deviceId: String) = synchronized(lock) {
        val all = loadHosts().toMutableMap()
        if (all.remove(deviceId) != null) hostsFile.writeText(json.encodeToString(hostsSerializer, all))
    }

    /** Unpairing a Mac forgets how to log in to it and the key it presented. */
    fun forget(deviceId: String) = synchronized(lock) {
        forgetHostKey(deviceId)
        val all = loadSettings().toMutableMap()
        if (all.remove(deviceId) != null) settingsFile.writeText(json.encodeToString(settingsSerializer, all))
    }

    /**
     * The SSH library's view of this store, for one Mac: it asks whether the key the server showed
     * is the one pinned, and the verdict decides whether the person is asked, let through, or
     * refused. The key it showed is kept, so the question can show its fingerprint.
     */
    fun repositoryFor(deviceId: String): PinnedHostKeys = PinnedHostKeys(this, deviceId)

    class PinnedHostKeys(private val store: TerminalStore, private val deviceId: String) : HostKeyRepository {
        @Volatile var presented: ByteArray? = null
            private set
        @Volatile var lastVerdict: HostKeyVerdict? = null
            private set

        override fun check(host: String, key: ByteArray): Int {
            presented = key
            val verdict = store.verdict(deviceId, key)
            lastVerdict = verdict
            return when (verdict) {
                HostKeyVerdict.Known -> HostKeyRepository.OK
                is HostKeyVerdict.New -> HostKeyRepository.NOT_INCLUDED
                is HostKeyVerdict.Changed -> HostKeyRepository.CHANGED
            }
        }

        /** Called once the person has said yes to a new key. */
        override fun add(hostkey: HostKey, ui: UserInfo?) {
            val blob = Base64.getDecoder().decode(hostkey.key)
            store.pin(deviceId, blob)
        }

        override fun remove(host: String?, type: String?) {}

        override fun remove(host: String?, type: String?, key: ByteArray?) {}

        override fun getKnownHostsRepositoryID(): String = "owndesk"

        override fun getHostKey(): Array<HostKey> = emptyArray()

        override fun getHostKey(host: String?, type: String?): Array<HostKey> = emptyArray()
    }

    private fun loadSettings(): Map<String, TerminalSettings> = try {
        if (!settingsFile.exists()) emptyMap()
        else json.decodeFromString(settingsSerializer, settingsFile.readText())
    } catch (e: Exception) {
        emptyMap()
    }

    private fun loadHosts(): Map<String, String> = try {
        if (!hostsFile.exists()) emptyMap()
        else json.decodeFromString(hostsSerializer, hostsFile.readText())
    } catch (e: Exception) {
        emptyMap()
    }

    private companion object {
        val lock = Any()
        val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
        val settingsSerializer = MapSerializer(String.serializer(), TerminalSettings.serializer())
        val hostsSerializer = MapSerializer(String.serializer(), String.serializer())
    }
}
