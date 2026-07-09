import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/bike_data_source.dart';
import 'services/camera_source.dart';
import 'services/ride_frame_store.dart';
import 'services/ride_recorder.dart';
import 'services/ride_repository.dart';

void main() {
  runApp(const BikeAssistApp());
}

class BikeAssistApp extends StatefulWidget {
  const BikeAssistApp({
    super.key,
    this.repository,
    this.frameStore,
    this.recordingEnabled = true,
  });

  /// Injectable so tests can supply an in-memory database / temp directory.
  final RideRepository? repository;
  final RideFrameStore? frameStore;

  /// Enables ride recording: cleans up orphaned rides on launch and records
  /// while a device is connected. Widget tests turn this off — recording
  /// writes frames and database rows on real async I/O, which never completes
  /// under the widget-test fake-async clock and would leave operations queued
  /// on the sqflite isolate.
  final bool recordingEnabled;

  @override
  State<BikeAssistApp> createState() => _BikeAssistAppState();
}

class _BikeAssistAppState extends State<BikeAssistApp> with WidgetsBindingObserver {
  late final BikeDataSource _dataSource = BikeDataSource();
  late final CameraSource _cameraSource = CameraSource();
  late final RideRepository _repository = widget.repository ?? RideRepository();
  late final RideFrameStore _frameStore = widget.frameStore ?? RideFrameStore();
  late final RideRecorder _recorder = RideRecorder(
    dataService: _dataSource,
    repository: _repository,
    cameraSource: _cameraSource,
    frameStore: _frameStore,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.recordingEnabled) {
      // Close any ride left open by an unclean shutdown, then record only
      // while a device is connected.
      _repository.closeOrphanRides();
      _cameraSource.mode.addListener(_syncRecordingWithConnection);
      _dataSource.mode.addListener(_syncRecordingWithConnection);
    }
  }

  /// Records only while a device is connected: starts when the camera or
  /// telemetry goes live, stops once both are down (disconnected/error).
  /// Neither starts nor stops during the transient connecting phase.
  void _syncRecordingWithConnection() {
    final connected = _cameraSource.mode.value == CameraMode.connected ||
        _dataSource.mode.value == TelemetryMode.connected;
    final connecting = _cameraSource.mode.value == CameraMode.connecting ||
        _dataSource.mode.value == TelemetryMode.connecting;

    if (connected && !_recorder.isRecording.value) {
      _recorder.start();
    } else if (!connected && !connecting && _recorder.isRecording.value) {
      _recorder.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _recorder.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraSource.mode.removeListener(_syncRecordingWithConnection);
    _dataSource.mode.removeListener(_syncRecordingWithConnection);
    _recorder.dispose();
    _cameraSource.dispose();
    _dataSource.dispose();
    _repository.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'bike-assist',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: HomeScreen(
        dataSource: _dataSource,
        cameraSource: _cameraSource,
        repository: _repository,
        frameStore: _frameStore,
        recorder: _recorder,
      ),
    );
  }
}
