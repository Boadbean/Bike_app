import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/route_point.dart';
import 'bike_data_service.dart';
import 'ride_repository.dart';

/// Ties the live [BikeDataService] stream to the [RideRepository], recording
/// every sample into the currently active ride until [stop] is called.
class RideRecorder {
  RideRecorder({
    required this.dataService,
    required this.repository,
  });

  final BikeDataService dataService;
  final RideRepository repository;

  final ValueNotifier<bool> isRecording = ValueNotifier(false);

  int? _currentRideId;
  StreamSubscription? _subscription;

  /// Cleans up any ride orphaned by an unclean shutdown, then starts a new
  /// recording. Call once when the app launches.
  Future<void> init() async {
    await repository.closeOrphanRides();
    await start();
  }

  Future<void> start() async {
    if (isRecording.value) return;
    _currentRideId = await repository.startRide();
    _subscription = dataService.stream.listen((data) {
      final rideId = _currentRideId;
      if (rideId == null) return;
      repository.addPoint(
        rideId,
        RoutePoint(
          lat: data.lat,
          lng: data.lng,
          speedKmh: data.speedKmh,
          timestamp: data.timestamp,
        ),
      );
    });
    isRecording.value = true;
  }

  Future<void> stop() async {
    if (!isRecording.value) return;
    await _subscription?.cancel();
    _subscription = null;
    final rideId = _currentRideId;
    _currentRideId = null;
    isRecording.value = false;
    if (rideId != null) {
      await repository.endRide(rideId);
    }
  }

  void dispose() {
    _subscription?.cancel();
    isRecording.dispose();
  }
}
