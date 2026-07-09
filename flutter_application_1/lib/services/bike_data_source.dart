import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/bike_data.dart';
import 'bike_data_service.dart';
import 'http_status_bike_data_service.dart';

enum TelemetryMode { disconnected, connecting, connected, error }

/// Owns the active [BikeDataService] (a real ESP32 polling the firmware
/// `/api/status`, or none) and re-publishes its samples on a single, stable
/// broadcast stream.
///
/// Mirrors `CameraSource`: the app starts [disconnected] with no source;
/// [connect] attaches a device and [disconnect] tears it down. Swapping does
/// not disturb existing subscribers, so the dashboard and the ride recorder
/// keep the same subscription without knowing the source changed.
class BikeDataSource implements BikeDataService {
  BikeDataSource();

  final _out = StreamController<BikeData>.broadcast();
  final ValueNotifier<TelemetryMode> mode = ValueNotifier(TelemetryMode.disconnected);
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  BikeDataService? _service;
  StreamSubscription<BikeData>? _subscription;

  @override
  Stream<BikeData> get stream => _out.stream;

  /// Connects telemetry to the device at [baseUri] (scheme + host [+ port]);
  /// the service appends `/api/status` itself.
  void connect(Uri baseUri) =>
      _swap(HttpStatusBikeDataService(baseUri), TelemetryMode.connecting);

  /// Tears down the current source and returns to the disconnected state.
  void disconnect() {
    _subscription?.cancel();
    _subscription = null;
    _service?.dispose();
    _service = null;
    mode.value = TelemetryMode.disconnected;
    errorMessage.value = null;
  }

  void _swap(BikeDataService service, TelemetryMode initialMode) {
    _subscription?.cancel();
    _service?.dispose();

    _service = service;
    mode.value = initialMode;
    errorMessage.value = null;

    _subscription = service.stream.listen(
      (data) {
        // First successful sample confirms the connection is live. A later
        // error flips to [error]; the next good sample flips back, so a
        // transient network blip self-heals.
        if (mode.value != TelemetryMode.disconnected) {
          mode.value = TelemetryMode.connected;
          errorMessage.value = null;
        }
        if (!_out.isClosed) _out.add(data);
      },
      onError: (Object error) {
        if (mode.value != TelemetryMode.disconnected) {
          mode.value = TelemetryMode.error;
          errorMessage.value = error.toString();
        }
      },
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _service?.dispose();
    _out.close();
    mode.dispose();
    errorMessage.dispose();
  }
}
