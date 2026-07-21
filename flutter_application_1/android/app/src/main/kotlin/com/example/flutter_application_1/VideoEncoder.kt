package com.example.flutter_application_1

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer

/**
 * Assembles a list of recorded JPEG frames into an H.264 `.mp4` on-device,
 * using [MediaCodec] (AVC encoder) fed raw YUV420 buffers plus [MediaMuxer] to
 * write the track. No native/ffmpeg dependency — everything here is Android
 * framework API, so it works on any device/emulator from API 21 up.
 *
 * Frames are drawn at their real capture timing: [ptsUs] carries the
 * presentation timestamp (microseconds, starting at 0) of each frame, so a ride
 * whose camera stuttered plays back at the pace it was actually recorded.
 */
object VideoEncoder {

    private const val TIMEOUT_US = 10_000L

    /**
     * Encodes [framePaths] (ordered JPEG files) into an MP4 at [outputPath].
     * [ptsUs] must be the same length as [framePaths] and monotonically
     * increasing. [fps] is the nominal frame rate written into the format.
     */
    fun encode(framePaths: List<String>, ptsUs: List<Long>, outputPath: String, fps: Int) {
        require(framePaths.isNotEmpty()) { "no frames to encode" }
        require(framePaths.size == ptsUs.size) { "framePaths/ptsUs length mismatch" }

        // First frame sets the output dimensions; H.264 needs even width/height.
        val firstBitmap = BitmapFactory.decodeFile(framePaths[0])
            ?: throw IllegalStateException("cannot decode first frame: ${framePaths[0]}")
        val width = (firstBitmap.width and 1.inv()).coerceAtLeast(2)
        val height = (firstBitmap.height and 1.inv()).coerceAtLeast(2)
        firstBitmap.recycle()

        val mime = MediaFormat.MIMETYPE_VIDEO_AVC
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, estimateBitrate(width, height, fps))
            setInteger(MediaFormat.KEY_FRAME_RATE, fps.coerceAtLeast(1))
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }

        val codec = MediaCodec.createEncoderByType(mime)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()

        val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var trackIndex = -1
        var muxerStarted = false
        val bufferInfo = MediaCodec.BufferInfo()

        var frameIndex = 0
        var inputDone = false
        val ySize = width * height
        val frameSize = ySize + ySize / 2 // YUV420: Y + quarter U + quarter V

        try {
            while (true) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        if (frameIndex >= framePaths.size) {
                            codec.queueInputBuffer(
                                inIndex, 0, 0,
                                ptsUs.last() + 1,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            val bmp = decodeScaled(framePaths[frameIndex], width, height)
                            val image = codec.getInputImage(inIndex)
                                ?: throw IllegalStateException("encoder input image unavailable")
                            fillYuv420(image, bmp, width, height)
                            bmp.recycle()
                            codec.queueInputBuffer(inIndex, 0, frameSize, ptsUs[frameIndex], 0)
                            frameIndex++
                        }
                    }
                }

                val outIndex = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    trackIndex = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxerStarted = true
                } else if (outIndex >= 0) {
                    val encoded = codec.getOutputBuffer(outIndex)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        // Codec config is folded into the track format, not written.
                        bufferInfo.size = 0
                    }
                    if (encoded != null && bufferInfo.size > 0 && muxerStarted) {
                        encoded.position(bufferInfo.offset)
                        encoded.limit(bufferInfo.offset + bufferInfo.size)
                        muxer.writeSampleData(trackIndex, encoded, bufferInfo)
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        } finally {
            try {
                codec.stop()
            } catch (_: Exception) {
            }
            codec.release()
            try {
                if (muxerStarted) muxer.stop()
            } catch (_: Exception) {
            }
            muxer.release()
        }
    }

    /** Decodes [path] and scales it to exactly [w]x[h] (the video dimensions). */
    private fun decodeScaled(path: String, w: Int, h: Int): Bitmap {
        val src = BitmapFactory.decodeFile(path)
            ?: throw IllegalStateException("cannot decode frame: $path")
        if (src.width == w && src.height == h) return src
        val scaled = Bitmap.createScaledBitmap(src, w, h, true)
        if (scaled != src) src.recycle()
        return scaled
    }

    /**
     * Converts an ARGB [bmp] into the encoder's YUV420 input [image], honouring
     * each plane's row/pixel stride (which vary by device). Uses the standard
     * BT.601 full-range-ish integer coefficients.
     */
    private fun fillYuv420(image: Image, bmp: Bitmap, width: Int, height: Int) {
        val argb = IntArray(width * height)
        bmp.getPixels(argb, 0, width, 0, 0, width, height)

        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val yBuf = yPlane.buffer
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        val yRowStride = yPlane.rowStride
        val yPixStride = yPlane.pixelStride
        val uRowStride = uPlane.rowStride
        val uPixStride = uPlane.pixelStride
        val vRowStride = vPlane.rowStride
        val vPixStride = vPlane.pixelStride

        for (j in 0 until height) {
            val row = j * width
            val yRow = j * yRowStride
            val uvRow = (j / 2)
            for (i in 0 until width) {
                val c = argb[row + i]
                val r = (c shr 16) and 0xFF
                val g = (c shr 8) and 0xFF
                val b = c and 0xFF

                val y = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
                yBuf.put(yRow + i * yPixStride, y.coerceIn(0, 255).toByte())

                if (j and 1 == 0 && i and 1 == 0) {
                    val u = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                    val v = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                    val uvCol = i / 2
                    uBuf.put(uvRow * uRowStride + uvCol * uPixStride, u.coerceIn(0, 255).toByte())
                    vBuf.put(uvRow * vRowStride + uvCol * vPixStride, v.coerceIn(0, 255).toByte())
                }
            }
        }
    }

    /** A sane H.264 bitrate for the frame size: ~0.12 bits per pixel per frame. */
    private fun estimateBitrate(width: Int, height: Int, fps: Int): Int {
        val bits = (width.toLong() * height * fps.coerceAtLeast(1) * 0.12).toLong()
        return bits.coerceIn(800_000L, 12_000_000L).toInt()
    }
}
