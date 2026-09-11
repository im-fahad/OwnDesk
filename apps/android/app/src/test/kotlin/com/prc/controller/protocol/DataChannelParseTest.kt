package com.prc.controller.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The receiving half of the control channel. The phone used to discard every message the Mac sent,
 * so a paused capture looked exactly like a still desktop and a display that changed size left
 * every touch landing in the wrong place.
 *
 * The samples are the bytes the Mac actually puts on the wire, copied from the Swift and TypeScript
 * codec tests, so the three implementations are pinned to the same strings.
 */
class DataChannelParseTest {
    private val control = DataChannel.CONTROL

    @Test
    fun `capture state decodes, with and without a detail`() {
        val locked = DataChannel.parse("""{"v":1,"type":"capture_state","ts":0,"state":"paused_locked"}""", control)
        assertEquals(DataChannel.Incoming.Capture("paused_locked", null), locked)

        val errored = DataChannel.parse(
            """{"v":1,"type":"capture_state","ts":0,"detail":"no new frame","state":"paused_error"}""", control)
        assertEquals(DataChannel.Incoming.Capture("paused_error", "no new frame"), errored)

        assertEquals(
            DataChannel.Incoming.Capture("active", null),
            DataChannel.parse("""{"v":1,"type":"capture_state","ts":0,"state":"active"}""", control))
    }

    @Test
    fun `a capture state the phone does not know is ignored rather than guessed at`() {
        assertNull(DataChannel.parse("""{"v":1,"type":"capture_state","ts":0,"state":"asleep"}""", control))
        assertNull(DataChannel.parse("""{"v":1,"type":"capture_state","ts":0}""", control))
    }

    @Test
    fun `display info decodes, and its bounds are the schema's`() {
        val ok = DataChannel.parse(
            """{"v":1,"type":"display_info","ts":0,"display_id":"main","width_px":1920,"height_px":1080,"scale":2}""",
            control)
        assertEquals(DataChannel.Incoming.Display(DisplayInfo("main", 1920, 1080, 2.0)), ok)

        // Out of range in each field, and a missing id.
        assertNull(DataChannel.parse(
            """{"v":1,"type":"display_info","ts":0,"display_id":"main","width_px":0,"height_px":1080,"scale":2}""", control))
        assertNull(DataChannel.parse(
            """{"v":1,"type":"display_info","ts":0,"display_id":"main","width_px":1920,"height_px":99999,"scale":2}""", control))
        assertNull(DataChannel.parse(
            """{"v":1,"type":"display_info","ts":0,"display_id":"main","width_px":1920,"height_px":1080,"scale":9}""", control))
        assertNull(DataChannel.parse(
            """{"v":1,"type":"display_info","ts":0,"width_px":1920,"height_px":1080,"scale":2}""", control))
    }

    @Test
    fun `bye decodes and carries its reason`() {
        assertEquals(
            DataChannel.Incoming.Bye("idle_timeout"),
            DataChannel.parse("""{"v":1,"type":"bye","ts":0,"reason":"idle_timeout"}""", control))
    }

    /** A newer Mac may send types this build has never heard of. Ignoring them beats dropping the session. */
    @Test
    fun `types the phone does not act on decode to nothing, without throwing`() {
        assertNull(DataChannel.parse("""{"v":1,"type":"pong","ts":0,"nonce":7}""", control))
        assertNull(DataChannel.parse("""{"v":1,"type":"hello","ts":0,"versions":[1],"app":"mac-agent","app_version":"0.2.0"}""", control))
        assertNull(DataChannel.parse("""{"v":1,"type":"something_new","ts":0}""", control))
        assertNull(DataChannel.parse("""{"v":1,"type":"execute_shell","ts":0,"cmd":"rm -rf /"}""", control))
    }

    /** A control message on an input channel is a protocol error, not a surprise. */
    @Test
    fun `a control message arriving on the wrong channel is refused`() {
        val frame = """{"v":1,"type":"capture_state","ts":0,"state":"paused_locked"}"""
        assertNull(DataChannel.parse(frame, DataChannel.LOSSY))
        assertNull(DataChannel.parse(frame, DataChannel.RELIABLE))
    }

    @Test
    fun `malformed and oversized frames decode to nothing`() {
        assertNull(DataChannel.parse("{", control))
        assertNull(DataChannel.parse("\"a string\"", control))
        assertNull(DataChannel.parse("[]", control))
        assertNull(DataChannel.parse("", control))
        val huge = """{"v":1,"type":"capture_state","ts":0,"state":"active","detail":"${"x".repeat(DataChannel.MAX_BYTES)}"}"""
        assertNull(DataChannel.parse(huge, control))
    }
}
