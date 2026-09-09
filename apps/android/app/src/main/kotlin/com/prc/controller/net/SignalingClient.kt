package com.prc.controller.net

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit

/** One WebSocket to a Mac's signaling endpoint. Text frames carrying signed envelopes. */
class SignalingClient(private val url: String) {
    sealed class Event {
        object Opened : Event()
        data class Message(val text: String) : Event()
        data class Closed(val reason: String) : Event()
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build()

    private var socket: WebSocket? = null

    fun connect(onEvent: (Event) -> Unit) {
        val request = Request.Builder().url(url).build()
        socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = onEvent(Event.Opened)
            override fun onMessage(webSocket: WebSocket, text: String) = onEvent(Event.Message(text))
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) =
                onEvent(Event.Closed(reason.ifEmpty { "closed" }))
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                onEvent(Event.Closed(t.message ?: "connection failed"))
        })
    }

    fun send(text: String) {
        socket?.send(text)
    }

    fun close() {
        socket?.close(1000, null)
        socket = null
        client.dispatcher.executorService.shutdown()
    }
}

/** Turns the addresses a Mac advertises into URLs, and says which network path they imply. */
object Endpoints {
    const val DEFAULT_PORT = 47500

    fun url(address: String): String? {
        val trimmed = address.trim()
        if (trimmed.isEmpty()) return null
        // "[fd7a::1]:47500", "192.168.1.20:47500", "mac.local:47500", or a bare host.
        val hostPort = when {
            trimmed.startsWith("[") -> {
                val end = trimmed.indexOf(']')
                if (end < 0) return null
                val host = trimmed.substring(0, end + 1)
                val port = trimmed.substringAfter("]:", "").ifEmpty { DEFAULT_PORT.toString() }
                "$host:$port"
            }
            trimmed.count { it == ':' } > 1 -> "[$trimmed]:$DEFAULT_PORT"
            trimmed.contains(':') -> trimmed
            else -> "$trimmed:$DEFAULT_PORT"
        }
        return "ws://$hostPort/"
    }

    /**
     * The first address that accepts a connection, probed all at once.
     *
     * A Mac usually advertises a home address and a tailnet address. Trying them in turn means
     * waiting out a timeout on the wrong one before the right one is even attempted, which is the
     * difference between connecting in a second from a cafe and appearing not to work at all.
     */
    fun firstReachable(addresses: List<String>, timeoutMs: Int = 2500): String? {
        if (addresses.isEmpty()) return null
        if (addresses.size == 1) return if (reachable(addresses[0], timeoutMs)) addresses[0] else null

        val winner = java.util.concurrent.atomic.AtomicReference<String?>(null)
        val done = java.util.concurrent.CountDownLatch(1)
        val pool = java.util.concurrent.Executors.newFixedThreadPool(minOf(addresses.size, 8))
        try {
            for (address in addresses) {
                pool.execute {
                    if (reachable(address, timeoutMs)) {
                        // The first to answer wins; the rest are abandoned.
                        if (winner.compareAndSet(null, address)) done.countDown()
                    }
                }
            }
            done.await(timeoutMs.toLong() + 500, java.util.concurrent.TimeUnit.MILLISECONDS)
        } finally {
            pool.shutdownNow()
        }
        return winner.get()
    }

    private fun reachable(address: String, timeoutMs: Int): Boolean {
        val host = host(address)
        val port = port(address) ?: return false
        return try {
            java.net.Socket().use { socket ->
                socket.connect(java.net.InetSocketAddress(host, port), timeoutMs)
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    fun port(address: String): Int? {
        val trimmed = address.trim()
        return when {
            trimmed.startsWith("[") -> trimmed.substringAfter("]:", "").toIntOrNull() ?: DEFAULT_PORT
            trimmed.count { it == ':' } > 1 -> DEFAULT_PORT
            trimmed.contains(':') -> trimmed.substringAfter(':').toIntOrNull()
            else -> DEFAULT_PORT
        }
    }

    fun host(address: String): String {
        val trimmed = address.trim()
        return when {
            trimmed.startsWith("[") -> trimmed.substringAfter('[').substringBefore(']')
            trimmed.count { it == ':' } > 1 -> trimmed
            trimmed.contains(':') -> trimmed.substringBefore(':')
            else -> trimmed
        }
    }

    /**
     * What to declare in SESSION_REQUEST, which decides how much bandwidth the Mac seeds. Only a
     * genuinely local address counts as "lan": a Tailscale address is private but may be relayed
     * through the far side of the world, and claiming otherwise gives a soft, stuttering picture.
     */
    fun path(address: String): String {
        val h = host(address)
        val parts = h.split('.')
        if (parts.size == 4 && parts.all { it.toIntOrNull() in 0..255 }) {
            val a = parts[0].toInt()
            val b = parts[1].toInt()
            // Tailscale hands out 100.64.0.0/10, which is carrier-grade NAT space, not a LAN.
            if (a == 100 && b in 64..127) return "cloud"
            if (a == 10) return "lan"
            if (a == 172 && b in 16..31) return "lan"
            if (a == 192 && b == 168) return "lan"
            if (a == 169 && b == 254) return "lan"
            return "cloud"
        }
        val lower = h.lowercase()
        if (lower.startsWith("fd7a:115c:a1e0")) return "cloud"
        if (lower.startsWith("fe80") || lower.startsWith("fc") || lower.startsWith("fd")) return "lan"
        if (lower.endsWith(".local")) return "lan"
        return "cloud"
    }
}
