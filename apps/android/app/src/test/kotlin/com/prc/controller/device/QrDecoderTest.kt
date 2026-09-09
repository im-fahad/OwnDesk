package com.prc.controller.device

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.ByteBuffer

/**
 * A pairing code is long, so the question is not whether a QR can be read but whether one this size
 * can. These encode a real payload and read it back through the same code the camera feeds.
 */
class QrDecoderTest {

    private val payload = """
        {"v":1,"kind":"prc-pair","host_device_id":"25aaf3b74f823afeaa6d2ae0169c3323d29ec3414c300210c982336399679e03","host_key_hash":"25aaf3b74f823afeaa6d2ae0169c3323d29ec3414c300210c982336399679e03","host_name":"Test Mac mini","addresses":["192.168.1.55:47500","100.64.0.10:47500","[fd7a:115c:a1e0::a]:47500"],"rendezvous_url":null,"pairing_session_id":"AAECAwQFBgcICQoLDA0ODw","pairing_code":"EBESExQVFhcYGRobHB0eHw","expires_at":1788979590645}
    """.trimIndent()

    /** Black pixels are dark, white pixels are bright: the same shape a camera's brightness plane has. */
    private fun luminanceOf(text: String, size: Int): Triple<ByteArray, Int, Int> {
        val matrix = QRCodeWriter().encode(
            text, BarcodeFormat.QR_CODE, size, size,
            mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 2),
        )
        val bytes = ByteArray(matrix.width * matrix.height)
        for (y in 0 until matrix.height) {
            for (x in 0 until matrix.width) {
                bytes[y * matrix.width + x] = if (matrix.get(x, y)) 0 else 255.toByte()
            }
        }
        return Triple(bytes, matrix.width, matrix.height)
    }

    @Test
    fun `a whole pairing payload survives the round trip`() {
        val (bytes, width, height) = luminanceOf(payload, 600)
        assertEquals(payload, QrDecoder.decode(bytes, width, height))
    }

    @Test
    fun `a frame with no code in it reads as nothing rather than failing`() {
        val blank = ByteArray(320 * 240) { 200.toByte() }
        assertNull(QrDecoder.decode(blank, 320, 240))
    }

    @Test
    fun `decoding twice in a row still works, since frames keep arriving`() {
        val (bytes, width, height) = luminanceOf(payload, 600)
        assertEquals(payload, QrDecoder.decode(bytes, width, height))
        assertNull(QrDecoder.decode(ByteArray(320 * 240) { 200.toByte() }, 320, 240))
        assertEquals(payload, QrDecoder.decode(bytes, width, height))
    }

    @Test
    fun `padded camera rows are unpacked to the picture's real width`() {
        val width = 4
        val height = 3
        val stride = 7
        val padded = ByteBuffer.allocate(stride * height)
        for (y in 0 until height) {
            for (x in 0 until stride) {
                padded.put(if (x < width) (y * width + x).toByte() else 99)
            }
        }
        val packed = QrDecoder.packRows(padded, stride, width, height)
        assertEquals(width * height, packed.size)
        assertEquals(0, packed[0].toInt())
        assertEquals(11, packed[11].toInt())
    }

    @Test
    fun `an unpadded frame is taken as it is`() {
        val width = 4
        val height = 2
        val buffer = ByteBuffer.wrap(ByteArray(width * height) { it.toByte() })
        val packed = QrDecoder.packRows(buffer, width, width, height)
        assertEquals(width * height, packed.size)
        assertEquals(7, packed[7].toInt())
    }
}
