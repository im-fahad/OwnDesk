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
        "hello", "display_info", "stream_settings", "ping", "pong", "bye" -> CONTROL
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
}
