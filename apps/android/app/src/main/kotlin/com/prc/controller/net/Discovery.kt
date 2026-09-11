package com.prc.controller.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import java.net.Inet6Address
import java.net.InetAddress
import java.util.ArrayDeque

/**
 * Finds Macs advertising themselves on this network (spec section 17).
 *
 * The addresses a Mac hands over at pairing time do not stay true. A home router moves a lease, the
 * Mac that was .55 answers at .52, and every stored candidate is then wrong. With Tailscale off
 * there is nothing left to try, so a Mac sitting on the same Wi-Fi as the phone reads as offline
 * and cannot be reached without someone typing an address. Bonjour is the Mac saying where it is
 * now, and the `id` in its TXT record is how we know which Mac is speaking.
 */
class Discovery(
    context: Context,
    private val onFound: (deviceId: String, address: String) -> Unit,
) {
    private val nsd = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var browsing: NsdManager.DiscoveryListener? = null

    // NsdManager resolves one service at a time; asking again while one is in flight fails with
    // FAILURE_ALREADY_ACTIVE and the answer is simply lost. So they wait their turn.
    private val lock = Object()
    private val waiting = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    fun start() {
        if (browsing != null) return
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) = enqueue(info)
            override fun onServiceLost(info: NsdServiceInfo) {}
        }
        browsing = listener
        // Discovery is a convenience, never a requirement: a network that forbids multicast simply
        // leaves the stored addresses in charge.
        runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { browsing = null }
    }

    fun stop() {
        val listener = browsing ?: return
        browsing = null
        runCatching { nsd.stopServiceDiscovery(listener) }
        synchronized(lock) {
            waiting.clear()
            resolving = false
        }
    }

    private fun enqueue(info: NsdServiceInfo) {
        synchronized(lock) {
            waiting.addLast(info)
            if (resolving) return
            resolving = true
        }
        resolveNext()
    }

    private fun resolveNext() {
        val next = synchronized(lock) {
            val head = waiting.pollFirst()
            if (head == null) resolving = false
            head
        } ?: return

        @Suppress("DEPRECATION")
        runCatching {
            nsd.resolveService(next, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = resolveNext()
                override fun onServiceResolved(info: NsdServiceInfo) {
                    report(info)
                    resolveNext()
                }
            })
        }.onFailure { resolveNext() }
    }

    private fun report(info: NsdServiceInfo) {
        @Suppress("DEPRECATION")
        val host = info.host ?: return
        val id = info.attributes["id"]?.toString(Charsets.UTF_8)?.trim() ?: return
        if (id.length != DEVICE_ID_LENGTH) return
        val address = format(host, info.port)
        if (address.isNotEmpty()) onFound(id, address)
    }

    private fun format(host: InetAddress, port: Int): String {
        val raw = host.hostAddress ?: return ""
        // A link-local address carries a %scope that means nothing to anyone else.
        val clean = raw.substringBefore('%')
        if (clean.isEmpty()) return ""
        return if (host is Inet6Address) "[$clean]:$port" else "$clean:$port"
    }

    companion object {
        /** Matches AgentConfig.serviceType on the Mac. */
        const val SERVICE_TYPE = "_prc._tcp"
        private const val DEVICE_ID_LENGTH = 64
    }
}
