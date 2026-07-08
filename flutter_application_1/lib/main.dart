import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/bike_data_service.dart';
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
    this.autoStartRecording = true,
  });

  /// Injectable so tests can supply an in-memory database / temp directory.
  final RideRepository? repository;
  final RideFrameStore? frameStore;

  /// Widget tests turn this off: recording writes frames and database rows on
  /// real async I/O, which never completes under the widget-test fake-async
  /// clock and would leave operations queued on the sqflite isolate.
  final bool autoStartRecording;

  @override
  State<BikeAssistApp> createState() => _BikeAssistAppState();
}

class _BikeAssistAppState extends State<BikeAssistApp> with WidgetsBindingObserver {
  late final BikeDataService _dataService = MockBikeDataService();
  late final CameraSource _cameraSource = CameraSource();
  late final RideRepository _repository = widget.repository ?? RideRepository();
  late final RideFrameStore _frameStore = widget.frameStore ?? RideFrameStore();
  late final RideRecorder _recorder = RideRecorder(
    dataService: _dataService,
    repository: _repository,
    cameraSource: _cameraSource,
    frameStore: _frameStore,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoStartRecording) _recorder.init();
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
    _recorder.dispose();
    _cameraSource.dispose();
    _dataService.dispose();
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
        dataService: _dataService,
        cameraSource: _cameraSource,
        repository: _repository,
        frameStore: _frameStore,
        recorder: _recorder,
      ),
    );
  }
}
