import 'package:flutter/services.dart';

/// Assembles recorded JPEG frames into an H.264 `.mp4`. Abstracted so the
/// export service can be unit-tested with a fake, since the real implementation
/// crosses a platform channel to native Android (unavailable in a Dart test).
abstract class VideoEncoder {
  /// Encodes the ordered [framePaths] into an MP4 at [outputPath]. [ptsMs] is
  /// each frame's presentation time in milliseconds (same length as
  /// [framePaths], starting at 0), so frames play back at their capture pace.
  /// [fps] is the nominal frame rate.
  Future<void> encodeJpegsToMp4({
    required List<String> framePaths,
    required List<int> ptsMs,
    required String outputPath,
    int fps,
  });
}

/// Real encoder: calls the native `bike_assist/video_encoder` channel handled
/// by `MainActivity` (MediaCodec + MediaMuxer). Android only — throws a
/// [MissingPluginException] on platforms without the native side.
class MethodChannelVideoEncoder implements VideoEncoder {
  MethodChannelVideoEncoder({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('bike_assist/video_encoder');

  final MethodChannel _channel;

  @override
  Future<void> encodeJpegsToMp4({
    required List<String> framePaths,
    required List<int> ptsMs,
    required String outputPath,
    int fps = 15,
  }) async {
    await _channel.invokeMethod<String>('encodeJpegsToMp4', {
      'framePaths': framePaths,
      'ptsMs': ptsMs,
      'outputPath': outputPath,
      'fps': fps,
    });
  }
}
