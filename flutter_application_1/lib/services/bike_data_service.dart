import 'dart:async';
import 'dart:math';

import '../models/bike_data.dart';

/// Source of live telemetry for the dashboard. A real implementation would
/// connect to the ESP32 backend over WebSocket; for now only [MockBikeDataService]
/// exists, so the UI can be built and tested without hardware or a backend.
abstract class BikeDataService {
  Stream<BikeData> get stream;

  void dispose();
}

/// Generates plausible, continuously-varying fake telemetry so the dashboard
/// has something to render before the real backend exists.
class MockBikeDataService implements BikeDataService {
  MockBikeDataService({
    this.baseLat = 25.0330,
    this.baseLng = 121.5654,
    Duration tickInterval = const Duration(milliseconds: 500),
  }) {
    _controller = StreamController<BikeData>.broadcast();
    _timer = Timer.periodic(tickInterval, (_) => _tick());
  }

  final double baseLat;
  final double baseLng;

  final _random = Random();
  late final StreamController<BikeData> _controller;
  late final Timer _timer;

  double _t = 0;
  double _lat = 0;
  double _lng = 0;

  @override
  Stream<BikeData> get stream => _controller.stream;

  void _tick() {
    _t += 0.15;

    final speedKmh = 15 + 15 * sin(_t) + _random.nextDouble() * 2;
    final lean = 10 * sin(_t * 0.7);

    _lat = baseLat + 0.0006 * sin(_t * 0.3) + (_random.nextDouble() - 0.5) * 0.00003;
    _lng = baseLng + 0.0006 * cos(_t * 0.3) + (_random.nextDouble() - 0.5) * 0.00003;

    final leanRad = lean * pi / 180;
    final data = BikeData(
      ax: sin(leanRad) * 9.8,
      ay: (_random.nextDouble() - 0.5) * 0.3,
      az: cos(leanRad) * 9.8,
      gx: (_random.nextDouble() - 0.5) * 20,
      gy: (_random.nextDouble() - 0.5) * 20,
      gz: (_random.nextDouble() - 0.5) * 20,
      lat: _lat,
      lng: _lng,
      speedKmh: speedKmh.clamp(0, 40),
      timestamp: DateTime.now(),
    );

    _controller.add(data);
  }

  @override
  void dispose() {
    _timer.cancel();
    _controller.close();
  }
}
