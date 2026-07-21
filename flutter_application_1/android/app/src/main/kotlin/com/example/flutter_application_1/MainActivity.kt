package com.example.flutter_application_1

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the native video-encoder method channel. Export bundles a ride's
 * recorded camera frames into an H.264 MP4 via [VideoEncoder] (MediaCodec +
 * MediaMuxer); Dart hands over the frame paths and their timestamps and gets
 * back the finished file's path.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "bike_assist/video_encoder"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "encodeJpegsToMp4" -> handleEncode(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleEncode(call: MethodCall, result: MethodChannel.Result) {
        val framePaths = call.argument<List<String>>("framePaths")
        val ptsMs = call.argument<List<Number>>("ptsMs")
        val outputPath = call.argument<String>("outputPath")
        val fps = call.argument<Int>("fps") ?: 15

        if (framePaths.isNullOrEmpty() || ptsMs == null || outputPath == null ||
            framePaths.size != ptsMs.size
        ) {
            result.error(
                "bad_args",
                "framePaths/ptsMs/outputPath are required and the two lists must match in length",
                null,
            )
            return
        }

        val ptsUs = ptsMs.map { it.toLong() * 1000L }
        val mainHandler = Handler(Looper.getMainLooper())
        // Encoding is CPU-heavy — run it off the platform thread and post the
        // result (MethodChannel.Result must be answered on the main thread).
        Thread {
            try {
                VideoEncoder.encode(framePaths, ptsUs, outputPath, fps)
                mainHandler.post { result.success(outputPath) }
            } catch (e: Exception) {
                mainHandler.post { result.error("encode_failed", e.message, null) }
            }
        }.start()
    }
}
