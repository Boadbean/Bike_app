import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/ride_list_screen.dart';
import 'services/bike_data_source.dart';
import 'services/camera_source.dart';
import 'services/import_intent_channel.dart';
import 'services/recording_keep_alive.dart';
import 'services/ride_archive_service.dart';
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
    this.keepAlive,
    this.recordingEnabled = true,
  });

  /// Injectable so tests can supply an in-memory database / temp directory.
  final RideRepository? repository;
  final RideFrameStore? frameStore;

  /// Holds the process open while recording so the screen can be off. Defaults
  /// to the Android foreground service, and to a no-op on every other platform.
  final RecordingKeepAlive? keepAlive;

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
  late final RecordingKeepAlive _keepAlive =
      widget.keepAlive ?? RecordingKeepAlive.forPlatform();
  late final RideArchiveService _archive =
      RideArchiveService(repository: _repository, frameStore: _frameStore);
  final ImportIntentChannel _importChannel = ImportIntentChannel();

  /// Lets an import triggered from outside the UI (a shared/opened .zip) show a
  /// snackbar and navigate to the history list, from above any current screen.
  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey();

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
      _recorder.isRecording.addListener(_syncKeepAliveWithRecording);

      // Import a .zip the app was opened with, and any shared while it runs.
      _importChannel.onImport = _handleSharedImport;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final path = await _importChannel.initialImport();
        if (path != null) _handleSharedImport(path);
      });
    }
  }

  /// Imports a ride archive that arrived via "open with / share to bike-assist",
  /// then drops the user on the history list so they can see it.
  Future<void> _handleSharedImport(String path) async {
    final messenger = _messengerKey.currentState;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('正在匯入記錄…')));
    try {
      await _archive.importRide(path);
    } catch (error) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('匯入失敗:$error')));
      return;
    }
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已匯入記錄')));
    _navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => RideListScreen(
          repository: _repository,
          frameStore: _frameStore,
          recorder: _recorder,
        ),
      ),
    );
  }

  /// Runs the foreground service for exactly as long as a ride is recording:
  /// without it Android freezes this process when the screen goes off and the
  /// ride stops capturing. Driven off [RideRecorder.isRecording] rather than the
  /// connection so it also covers a recording started by hand from the history
  /// screen.
  void _syncKeepAliveWithRecording() {
    if (_recorder.isRecording.value) {
      _keepAlive.start();
    } else {
      _keepAlive.stop();
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
    _recorder.isRecording.removeListener(_syncKeepAliveWithRecording);
    _keepAlive.stop();
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
      scaffoldMessengerKey: _messengerKey,
      navigatorKey: _navigatorKey,
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
