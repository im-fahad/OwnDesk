package com.prc.controller.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Writes one of every frame the phone can send to a file, which `npm run android-frames` then
 * validates against the real JSON Schemas. A frame the Mac would refuse is refused in silence, so
 * being sure of their shape here is worth more than it looks.
 */
class DataChannelFrameTest {

    @Test
    fun `every frame the phone sends is written for schema validation`() {
        val ts = 1_757_203_200_000L
        val frames = listOf(
            DataChannel.hello("0.2.0-dev", ts),
            DataChannel.mouseMove("1", 0.25, 0.75, ts),
            DataChannel.mouseMoveRel(-12.5, 40.0, ts),
            DataChannel.mouseDown("left", ts),
            DataChannel.mouseUp("left", ts),
            DataChannel.mouseDown("right", ts),
            DataChannel.scroll(-12.0, 34.0, ts),
            DataChannel.text("hello", ts),
            DataChannel.keyDown("Enter", listOf("shift"), ts),
            DataChannel.keyUp("Enter", listOf("shift"), ts),
            DataChannel.streamSettings(720, 30, "quality", ts),
            DataChannel.ping(42, ts),
            DataChannel.bye("user", ts),
        )

        for (frame in frames) {
            assertTrue("frame is too large: $frame", frame.toString().toByteArray().size <= DataChannel.MAX_BYTES)
        }
        // Each type travels on one channel, and putting it on another is a protocol error.
        assertEquals(DataChannel.LOSSY, DataChannel.channelFor("mouse_move"))
        assertEquals(DataChannel.RELIABLE, DataChannel.channelFor("key_down"))
        assertEquals(DataChannel.CONTROL, DataChannel.channelFor("hello"))

        val out = File(System.getProperty("prc.frames.out") ?: "build/frames.json")
        out.parentFile?.mkdirs()
        out.writeText(frames.joinToString(",\n", "[\n", "\n]") { it.toString() })
    }
}
