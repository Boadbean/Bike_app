import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/bike_data.dart';
import 'bike_data_service.dart';

/// Real telemetry source: polls the ESP32 firmware's `GET /api/status`
/// endpoint and emits parsed [BikeData]. Request/parse failures are forwarded
/// as stream errors so a [BikeDataSource] can surface the connection state;
/// polling continues regardless, so a dropped sample recovers on the next tick.
class HttpStatusBikeDataService implements BikeDataService {
  HttpStatusBikeDataService(
    Uri baseUri, {
    http.Client? client,
    this.pollInterval = const Duration(milliseconds: 700),
    this.requestTimeout = const Duration(seconds: 4),
  })  : _statusUri = baseUri.replace(path: '/api/status'),
        _client = client ?? http.Client(),
        _ownsClient = client == null {
    _controller = StreamController<BikeData>.broadcast();
    // Fire immediately so the first sample isn't delayed a whole interval.
    _poll();
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  /// Interval between status polls. The firmware serves `/api/status` on
  /// demand (IMU is live, GPS is cached ~5s), so ~1–2 Hz is plenty.
  final Duration pollInterval;
  final Duration requestTimeout;

  final Uri _statusUri;
  final http.Client _client;
  final bool _ownsClient;

  late final StreamController<BikeData> _controller;
  Timer? _timer;

  /// Guards against overlapping requests when a poll is slower than the
  /// interval — the in-flight one wins and the tick is skipped.
  bool _inFlight = false;
  bool _disposed = false;

  @override
  Stream<BikeData> get stream => _controller.stream;

  Future<void> _poll() async {
    if (_inFlight || _disposed) return;
    _inFlight = true;
    try {
      final response = await _client.get(_statusUri).timeout(requestTimeout);
      if (_disposed) return;
      if (response.statusCode != 200) {
        _controller.addError('HTTP ${response.statusCode}');
        return;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      _controller.add(BikeData.fromStatusJson(json));
    } catch (error) {
      if (!_disposed) _controller.addError(error);
    } finally {
      _inFlight = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    if (_ownsClient) _client.close();
    _controller.close();
  }
}
