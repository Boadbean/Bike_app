import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/bike_data.dart';
import 'bike_data_service.dart';
import 'http_status_bike_data_service.dart';

enum TelemetryMode { mock, connecting, connected, error }

/// Owns whichever [BikeDataService] is currently active (mock or a real ESP32
/// polling the firmware `/api/status`) and re-publishes its samples on a
/// single, stable broadcast stream.
///
/// Mirrors `CameraSource`: swapping the underlying source via [useMock] /
/// [connect] doesn't disturb existing subscribers, so the dashboard and the
/// ride recorder keep the same subscription without knowing the source changed.
class BikeDataSource implements BikeDataService {
  BikeDataSource() {
    useMock();
  }

  final _out = StreamController<BikeData>.broadcast();
  final ValueNotifier<TelemetryMode> mode = ValueNotifier(TelemetryMode.mock);
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  BikeDataService? _service;
  StreamSubscription<BikeData>? _subscription;

  @override
  Stream<BikeData> get stream => _out.stream;

  void useMock() => _swap(MockBikeDataService(), TelemetryMode.mock);

  /// Connects telemetry to the device at [baseUri] (scheme + host [+ port]);
  /// the service appends `/api/status` itself.
  void connect(Uri baseUri) =>
      _swap(HttpStatusBikeDataService(baseUri), TelemetryMode.connecting);

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
        if (mode.value != TelemetryMode.mock) {
          mode.value = TelemetryMode.connected;
          errorMessage.value = null;
        }
        if (!_out.isClosed) _out.add(data);
      },
      onError: (Object error) {
        if (mode.value != TelemetryMode.mock) {
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
