import 'dart:async';

import 'package:flutter/foundation.dart';

import 'camera_stream_service.dart';
import 'http_mjpeg_camera_stream_service.dart';

enum CameraMode { mock, connecting, connected, error }

/// Owns whichever [CameraStreamService] is currently active (mock or a real
/// ESP32 MJPEG stream) and re-publishes its frames on a single, stable
/// broadcast stream.
///
/// Swapping the underlying source via [useMock] / [connect] does not disturb
/// existing subscribers, which is what lets both the live view ([HomeScreen])
/// and the ride recorder consume the same camera without either of them
/// having to know the source changed.
class CameraSource {
  CameraSource() {
    useMock();
  }

  final _out = StreamController<Uint8List>.broadcast();
  final ValueNotifier<CameraMode> mode = ValueNotifier(CameraMode.mock);
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  CameraStreamService? _service;
  StreamSubscription<Uint8List>? _subscription;

  Stream<Uint8List> get frames => _out.stream;

  void useMock() => _swap(MockCameraStreamService(), CameraMode.mock);

  void connect(Uri uri) =>
      _swap(HttpMjpegCameraStreamService(uri), CameraMode.connecting);

  void _swap(CameraStreamService service, CameraMode initialMode) {
    _subscription?.cancel();
    _service?.dispose();

    _service = service;
    mode.value = initialMode;
    errorMessage.value = null;

    _subscription = service.frames.listen(
      (frame) {
        // First real frame confirms the connection is live.
        if (mode.value == CameraMode.connecting) {
          mode.value = CameraMode.connected;
        }
        if (!_out.isClosed) _out.add(frame);
      },
      onError: (Object error) {
        mode.value = CameraMode.error;
        errorMessage.value = error.toString();
      },
      onDone: () {
        // The mock stream only ends when we swap it out; a real stream ending
        // means the device dropped the connection.
        if (mode.value != CameraMode.mock) {
          mode.value = CameraMode.error;
          errorMessage.value = '連線已中斷';
        }
      },
    );
  }

  void dispose() {
    _subscription?.cancel();
    _service?.dispose();
    _out.close();
    mode.dispose();
    errorMessage.dispose();
  }
}
