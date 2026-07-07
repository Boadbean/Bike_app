import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Source of camera frames for the live view. A real implementation would
/// parse an MJPEG multipart HTTP stream from the ESP32 camera; for now only
/// [MockCameraStreamService] exists, emitting synthetic PNG frames through the
/// same `Stream<Uint8List>` contract so the UI never has to change.
abstract class CameraStreamService {
  Stream<Uint8List> get frames;

  void dispose();
}

/// Renders a small animated placeholder frame (gradient + frame counter +
/// timestamp) with `dart:ui` and pushes it as PNG bytes, simulating a camera
/// feed until the ESP32 MJPEG stream is available.
class MockCameraStreamService implements CameraStreamService {
  MockCameraStreamService({
    this.width = 320,
    this.height = 240,
    Duration frameInterval = const Duration(milliseconds: 200),
  }) {
    _controller = StreamController<Uint8List>.broadcast();
    _timer = Timer.periodic(frameInterval, (_) => _emitFrame());
  }

  final int width;
  final int height;

  late final StreamController<Uint8List> _controller;
  late final Timer _timer;
  int _frameIndex = 0;

  @override
  Stream<Uint8List> get frames => _controller.stream;

  Future<void> _emitFrame() async {
    _frameIndex++;
    final bytes = await _renderFrame(_frameIndex);
    if (!_controller.isClosed) {
      _controller.add(bytes);
    }
  }

  Future<Uint8List> _renderFrame(int index) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final size = ui.Size(width.toDouble(), height.toDouble());

    final hue = (index * 4) % 360;
    final color = _colorFromHsv(hue.toDouble(), 0.55, 0.35);
    final paint = ui.Paint()
      ..shader = ui.Gradient.linear(
        ui.Offset.zero,
        ui.Offset(size.width, size.height),
        [color, const ui.Color(0xFF000000)],
      );
    canvas.drawRect(ui.Offset.zero & size, paint);

    void drawText(String text, double dy, double fontSize) {
      final builder = ui.ParagraphBuilder(
        ui.ParagraphStyle(fontSize: fontSize, textAlign: ui.TextAlign.center),
      )
        ..pushStyle(ui.TextStyle(color: const ui.Color(0xFFFFFFFF)))
        ..addText(text);
      final paragraph = builder.build()
        ..layout(ui.ParagraphConstraints(width: size.width));
      canvas.drawParagraph(paragraph, ui.Offset(0, dy));
    }

    drawText('MOCK CAM', size.height / 2 - 30, 20);
    drawText('frame #$index', size.height / 2, 14);
    drawText(DateTime.now().toIso8601String().substring(11, 19), size.height / 2 + 22, 14);

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  @override
  void dispose() {
    _timer.cancel();
    _controller.close();
  }

  ui.Color _colorFromHsv(double hue, double saturation, double value) {
    final c = value * saturation;
    final x = c * (1 - ((hue / 60) % 2 - 1).abs());
    final m = value - c;
    double r, g, b;
    if (hue < 60) {
      r = c;
      g = x;
      b = 0;
    } else if (hue < 120) {
      r = x;
      g = c;
      b = 0;
    } else if (hue < 180) {
      r = 0;
      g = c;
      b = x;
    } else if (hue < 240) {
      r = 0;
      g = x;
      b = c;
    } else if (hue < 300) {
      r = x;
      g = 0;
      b = c;
    } else {
      r = c;
      g = 0;
      b = x;
    }
    return ui.Color.fromARGB(
      255,
      (((r + m) * 255).round()),
      (((g + m) * 255).round()),
      (((b + m) * 255).round()),
    );
  }
}
