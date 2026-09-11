package com.prc.controller.protocol

import org.json.JSONArray
import org.json.JSONObject

/**
 * The data channel protocol (spec sections 12 and 13): three channels, and small JSON frames on
 * them. Which channel a message belongs on is not a detail. A key press on the lossy channel could
 * vanish and leave a key stuck down, and a pointer move on the reliable channel would queue behind
 * retransmits until the cursor lags the finger.
 */
object DataChannel {
    const val LOSSY = "input-lossy"
    const val RELIABLE = "input-reliable"
    const val CONTROL = "control"
    const val MAX_BYTES = 4096

    /** Pointer moves are coalesced to this, which is about one frame at 240 Hz. */
    const val MOVE_COALESCE_MS = 4L

    fun channelFor(type: String): String = when (type) {
        "mouse_move", "mouse_move_rel" -> LOSSY
        "hello", "display_info", "capture_state", "stream_settings", "ping", "pong", "bye" -> CONTROL
        else -> RELIABLE
    }

    private fun frame(type: String, ts: Long): JSONObject =
        JSONObject().put("v", Envelope.PROTOCOL_VERSION).put("type", type).put("ts", ts)

    fun hello(appVersion: String, ts: Long): JSONObject =
        frame("hello", ts)
            .put("versions", JSONArray(listOf(Envelope.PROTOCOL_VERSION)))
            .put("app", "android-controller")
            .put("app_version", appVersion)

    /** Pointer position as a fraction of the display, so the phone never needs its pixel size. */
    fun mouseMove(displayId: String, x: Double, y: Double, ts: Long): JSONObject =
        frame("mouse_move", ts)
            .put("display_id", displayId)
            .put("x", x.coerceIn(0.0, 1.0))
            .put("y", y.coerceIn(0.0, 1.0))

    /** A nudge rather than a position, for trackpad style control where the pointer stays put. */
    fun mouseMoveRel(dx: Double, dy: Double, ts: Long): JSONObject =
        frame("mouse_move_rel", ts)
            .put("dx", dx.coerceIn(-4096.0, 4096.0))
            .put("dy", dy.coerceIn(-4096.0, 4096.0))

    fun mouseDown(button: String, ts: Long): JSONObject = frame("mouse_down", ts).put("button", button)

    fun mouseUp(button: String, ts: Long): JSONObject = frame("mouse_up", ts).put("button", button)

    fun scroll(dx: Double, dy: Double, ts: Long): JSONObject =
        frame("scroll", ts).put("dx", dx).put("dy", dy).put("precise", true)

    fun text(value: String, ts: Long): JSONObject = frame("text", ts).put("text", value)

    fun keyDown(code: String, modifiers: List<String>, ts: Long): JSONObject =
        frame("key_down", ts).put("code", code).put("modifiers", JSONArray(modifiers)).put("repeat", false)

    fun keyUp(code: String, modifiers: List<String>, ts: Long): JSONObject =
        frame("key_up", ts).put("code", code).put("modifiers", JSONArray(modifiers))

    fun streamSettings(maxHeight: Int?, maxFps: Int?, prefer: String?, ts: Long): JSONObject =
        frame("stream_settings", ts).apply {
            maxHeight?.let { put("max_height", it) }
            maxFps?.let { put("max_fps", it) }
            prefer?.let { put("prefer", it) }
        }

    fun ping(nonce: Long, ts: Long): JSONObject = frame("ping", ts).put("nonce", nonce)

    fun pong(nonce: Long, ts: Long): JSONObject = frame("pong", ts).put("nonce", nonce)

    fun bye(reason: String, ts: Long): JSONObject = frame("bye", ts).put("reason", reason)

    /**
     * What the Mac sends back on the control channel. Only the messages the phone acts on are
     * modelled; anything else decodes to null rather than an error, because a newer Mac is allowed
     * to send things this build has never heard of and dropping the session over that would be
     * worse than ignoring it.
     */
    sealed interface Incoming {
        /** The streamed display changed, mid-session. Pointer mapping depends on it. */
        data class Display(val info: DisplayInfo) : Incoming
        /** Whether the Mac is really capturing, and why not if it isn't. */
        data class Capture(val state: String, val detail: String?) : Incoming
        /** The Mac ended the session over the data channel rather than signaling. */
        data class Bye(val reason: String) : Incoming
    }

    val CAPTURE_STATES = setOf("active", "paused_locked", "paused_display_asleep", "paused_error")

    /**
     * Decodes one frame the Mac sent. Returns null for anything malformed, oversized, unknown, or
     * arriving on the wrong channel: the phone treats all of those the same way, by ignoring them.
     * Mirrors packages/protocol/src/datachannel.ts and the Swift DataChannelCodec.
     */
    fun parse(text: String, receivedOn: String): Incoming? {
        if (text.toByteArray(Charsets.UTF_8).size > MAX_BYTES) return null
        val obj = runCatching { JSONObject(text) }.getOrNull() ?: return null
        val type = obj.optString("type").ifEmpty { return null }
        // A control message arriving on an input channel is a protocol error, not a surprise.
        if (channelFor(type) != receivedOn) return null
        return when (type) {
            "display_info" -> {
                val width = obj.optInt("width_px", 0)
                val height = obj.optInt("height_px", 0)
                val scale = obj.optDouble("scale", 0.0)
                val id = obj.optString("display_id").ifEmpty { return null }
                if (width !in 1..16384 || height !in 1..16384 || scale !in 0.5..4.0) return null
                Incoming.Display(DisplayInfo(id, width, height, scale))
            }
            "capture_state" -> {
                val state = obj.optString("state")
                if (state !in CAPTURE_STATES) return null
                Incoming.Capture(state, obj.optString("detail").ifEmpty { null })
            }
            "bye" -> Incoming.Bye(obj.optString("reason").ifEmpty { "error" })
            else -> null
        }
    }
}
