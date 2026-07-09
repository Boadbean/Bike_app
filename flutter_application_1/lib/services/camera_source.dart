import 'dart:async';

import 'package:flutter/foundation.dart';

import 'camera_stream_service.dart';
import 'http_mjpeg_camera_stream_service.dart';

enum CameraMode { disconnected, connecting, connected, error }

/// Owns the active [CameraStreamService] (a real ESP32 MJPEG stream, or none)
/// and re-publishes its frames on a single, stable broadcast stream.
///
/// The app starts [disconnected] with no source; [connect] attaches a device
/// stream and [disconnect] tears it down. Swapping does not disturb existing
/// subscribers, which is what lets both the live view ([HomeScreen]) and the
/// ride recorder consume the same camera without knowing the source changed.
class CameraSource {
  CameraSource();

  final _out = StreamController<Uint8List>.broadcast();
  final ValueNotifier<CameraMode> mode = ValueNotifier(CameraMode.disconnected);
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  CameraStreamService? _service;
  StreamSubscription<Uint8List>? _subscription;

  Stream<Uint8List> get frames => _out.stream;

  void connect(Uri uri) =>
      _swap(HttpMjpegCameraStreamService(uri), CameraMode.connecting);

  /// Tears down the current stream and returns to the disconnected state.
  void disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _service?.dispose();
    _service = null;
    mode.value = CameraMode.disconnected;
    errorMessage.value = null;
  }

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
        // A live stream ending means the device dropped the connection.
        if (mode.value != CameraMode.disconnected) {
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
