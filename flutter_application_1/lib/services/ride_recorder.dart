import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/route_point.dart';
import 'bike_data_service.dart';
import 'camera_source.dart';
import 'ride_frame_store.dart';
import 'ride_repository.dart';

/// Records a ride: GPS/speed samples from [BikeDataService] into the database,
/// and camera frames from [CameraSource] onto disk (with their timestamps
/// indexed in the database), until [stop] is called.
class RideRecorder {
  RideRecorder({
    required this.dataService,
    required this.repository,
    required this.cameraSource,
    required this.frameStore,
    this.maxFramesPerSecond = 15,
    this.indexFlushInterval = const Duration(seconds: 1),
  });

  final BikeDataService dataService;
  final RideRepository repository;
  final CameraSource cameraSource;
  final RideFrameStore frameStore;

  /// Upper bound on recorded frames. The camera may push faster (a real ESP32
  /// can exceed this); surplus frames are dropped rather than stored.
  final int maxFramesPerSecond;

  /// How often buffered frame timestamps are flushed to the database, so we
  /// issue one batched transaction instead of an insert per frame.
  final Duration indexFlushInterval;

  final ValueNotifier<bool> isRecording = ValueNotifier(false);

  int? _currentRideId;
  StreamSubscription? _dataSubscription;
  StreamSubscription<Uint8List>? _frameSubscription;

  /// True while a frame write is in flight — incoming frames are dropped
  /// rather than queued, so a slow disk can't grow an unbounded backlog.
  bool _writingFrame = false;
  DateTime? _lastFrameAt;
  final List<DateTime> _pendingFrameTimestamps = [];
  Timer? _indexFlushTimer;

  Duration get _minFrameGap =>
      Duration(microseconds: Duration.microsecondsPerSecond ~/ maxFramesPerSecond);

  /// Cleans up any ride orphaned by an unclean shutdown, then starts a new
  /// recording. Call once when the app launches.
  Future<void> init() async {
    await repository.closeOrphanRides();
    await start();
  }

  Future<void> start() async {
    if (isRecording.value) return;
    final rideId = await repository.startRide();
    _currentRideId = rideId;
    _lastFrameAt = null;

    _dataSubscription = dataService.stream.listen((data) {
      final id = _currentRideId;
      if (id == null) return;
      repository.addPoint(
        id,
        RoutePoint(
          lat: data.lat,
          lng: data.lng,
          speedKmh: data.speedKmh,
          timestamp: data.timestamp,
        ),
      );
    });

    _frameSubscription = cameraSource.frames.listen(_onCameraFrame);
    _indexFlushTimer = Timer.periodic(indexFlushInterval, (_) => _flushFrameIndex());

    isRecording.value = true;
  }

  void _onCameraFrame(Uint8List bytes) {
    final rideId = _currentRideId;
    if (rideId == null || _writingFrame) return;

    final now = DateTime.now();
    final last = _lastFrameAt;
    if (last != null && now.difference(last) < _minFrameGap) return; // throttled

    _lastFrameAt = now;
    _writingFrame = true;
    frameStore.saveFrame(rideId, bytes, now).then((_) {
      _pendingFrameTimestamps.add(now);
    }).catchError((Object error) {
      debugPrint('[RideRecorder] 影格寫入失敗: $error');
    }).whenComplete(() {
      _writingFrame = false;
    });
  }

  Future<void> _flushFrameIndex() async {
    final rideId = _currentRideId;
    if (rideId == null || _pendingFrameTimestamps.isEmpty) return;
    final batch = List<DateTime>.from(_pendingFrameTimestamps);
    _pendingFrameTimestamps.clear();
    await repository.addFrames(rideId, batch);
  }

  Future<void> stop() async {
    if (!isRecording.value) return;
    await _dataSubscription?.cancel();
    await _frameSubscription?.cancel();
    _dataSubscription = null;
    _frameSubscription = null;
    _indexFlushTimer?.cancel();
    _indexFlushTimer = null;

    await _flushFrameIndex(); // persist whatever the last interval captured

    final rideId = _currentRideId;
    _currentRideId = null;
    isRecording.value = false;
    if (rideId != null) {
      await repository.endRide(rideId);
    }
  }

  void dispose() {
    _dataSubscription?.cancel();
    _frameSubscription?.cancel();
    _indexFlushTimer?.cancel();
    isRecording.dispose();
  }
}
