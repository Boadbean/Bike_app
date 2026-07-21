import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:flutter_application_1/services/video_encoder.dart';

/// Exercises the real native `MethodChannelVideoEncoder` (MediaCodec +
/// MediaMuxer) on a device/emulator: generates a handful of solid-colour
/// frames, encodes them, and checks a well-formed MP4 comes out. This is the
/// one path unit tests can't cover, since it crosses into native Android.
///
/// Run with: `flutter test integration_test/video_encoder_test.dart -d <device>`
Future<Uint8List> _framePng(int w, int h, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('encodes frames into a playable MP4', (tester) async {
    final tmp = await getTemporaryDirectory();
    final work = Directory(
      p.join(tmp.path, 'enc_test_${DateTime.now().millisecondsSinceEpoch}'),
    );
    await work.create(recursive: true);

    const w = 160;
    const h = 120;
    const colors = [
      Color(0xFFFF0000),
      Color(0xFF00FF00),
      Color(0xFF0000FF),
      Color(0xFFFFFF00),
      Color(0xFF00FFFF),
      Color(0xFFFF00FF),
    ];

    final paths = <String>[];
    final ptsMs = <int>[];
    for (var i = 0; i < colors.length; i++) {
      final f = File(p.join(work.path, 'frame_$i.jpg'));
      await f.writeAsBytes(await _framePng(w, h, colors[i]));
      paths.add(f.path);
      ptsMs.add(i * 100); // ~10 fps
    }

    final out = File(p.join(work.path, 'out.mp4'));
    await MethodChannelVideoEncoder().encodeJpegsToMp4(
      framePaths: paths,
      ptsMs: ptsMs,
      outputPath: out.path,
      fps: 10,
    );

    expect(await out.exists(), isTrue);
    final bytes = await out.readAsBytes();
    expect(bytes.length, greaterThan(500));
    // Every MP4 carries an 'ftyp' box in its opening bytes.
    final head = String.fromCharCodes(bytes.take(32));
    expect(head.contains('ftyp'), isTrue,
        reason: 'output does not look like an MP4');

    await work.delete(recursive: true);
  });
}
