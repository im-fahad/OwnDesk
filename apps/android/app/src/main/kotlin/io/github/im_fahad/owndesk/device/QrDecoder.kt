package io.github.im_fahad.owndesk.device

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.nio.ByteBuffer

/**
 * Reads a QR code out of a camera frame.
 *
 * It works on the brightness plane alone, which is the first plane of every frame the camera
 * produces, so nothing has to be converted to a bitmap. Decoding happens on the phone with no
 * network and no Play Services: a pairing code is a secret, and it should not travel anywhere to
 * be read.
 */
object QrDecoder {
    private val reader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                // A pairing code is a dense QR read from a screen by a hand-held camera, so the
                // slower, more forgiving search is the right trade: a few milliseconds against
                // a scanner that appears to do nothing.
                DecodeHintType.TRY_HARDER to true,
            )
        )
    }

    /** Returns the text of a QR in this frame, or null when there is none to read. */
    @Synchronized
    fun decode(luminance: ByteArray, width: Int, height: Int): String? {
        val source = PlanarYUVLuminanceSource(luminance, width, height, 0, 0, width, height, false)
        return try {
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
        } catch (e: NotFoundException) {
            null
        } catch (e: Exception) {
            null
        } finally {
            reader.reset()
        }
    }

    /**
     * Grows every dark area by [radius] pixels: each pixel takes the darkest value around it.
     *
     * A code on a bright screen photographs with its black modules eaten away, because the white
     * around them bleeds into the camera's pixels. The finder patterns lose the 1:1:3:1:1 shape the
     * detector looks for and the code is not even found. Growing the dark back restores it.
     */
    fun darken(luminance: ByteArray, width: Int, height: Int, radius: Int): ByteArray {
        if (radius <= 0) return luminance
        val across = ByteArray(width * height)
        for (y in 0 until height) {
            val row = y * width
            for (x in 0 until width) {
                var darkest = 255
                for (k in maxOf(0, x - radius)..minOf(width - 1, x + radius)) {
                    darkest = minOf(darkest, luminance[row + k].toInt() and 0xFF)
                }
                across[row + x] = darkest.toByte()
            }
        }
        val out = ByteArray(width * height)
        for (y in 0 until height) {
            for (x in 0 until width) {
                var darkest = 255
                for (k in maxOf(0, y - radius)..minOf(height - 1, y + radius)) {
                    darkest = minOf(darkest, across[k * width + x].toInt() and 0xFF)
                }
                out[y * width + x] = darkest.toByte()
            }
        }
        return out
    }

    /**
     * Camera rows can be padded, so a frame's bytes are not always width by height. This copies the
     * useful part of each row out, which is what the decoder expects.
     */
    fun packRows(buffer: ByteBuffer, rowStride: Int, width: Int, height: Int): ByteArray {
        buffer.rewind()
        if (rowStride == width) {
            val out = ByteArray(minOf(buffer.remaining(), width * height))
            buffer.get(out)
            return out
        }
        val out = ByteArray(width * height)
        val row = ByteArray(rowStride)
        for (y in 0 until height) {
            if (buffer.remaining() < rowStride) break
            buffer.get(row, 0, rowStride)
            row.copyInto(out, y * width, 0, width)
        }
        return out
    }
}
