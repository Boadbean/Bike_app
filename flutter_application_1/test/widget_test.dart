import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/models/bike_data.dart';
import 'package:flutter_application_1/models/route_point.dart';
import 'package:flutter_application_1/screens/device_wifi_setup_screen.dart';
import 'package:flutter_application_1/screens/ride_list_screen.dart';
import 'package:flutter_application_1/services/bike_data_service.dart';
import 'package:flutter_application_1/services/camera_source.dart';
import 'package:flutter_application_1/services/http_status_bike_data_service.dart';
import 'package:flutter_application_1/services/device_provisioning.dart';
import 'package:flutter_application_1/services/ride_frame_store.dart';
import 'package:flutter_application_1/services/ride_recorder.dart';
import 'package:flutter_application_1/services/ride_repository.dart';
import 'package:flutter_application_1/utils/timeline.dart';

class _FakeBikeDataService implements BikeDataService {
  final _controller = StreamController<BikeData>.broadcast();

  @override
  Stream<BikeData> get stream => _controller.stream;

  @override
  void dispose() => _controller.close();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// An app wired to an in-memory database and a temp frame directory, with
  /// background recording off. Recording performs real file + database writes,
  /// which never complete under the widget-test fake-async clock and would
  /// leave operations stuck on the sqflite isolate, hanging every later test.
  BikeAssistApp testApp() => BikeAssistApp(
        repository: RideRepository(path: inMemoryDatabasePath),
        frameStore: RideFrameStore(baseDir: Directory.systemTemp),
        autoStartRecording: false,
      );

  testWidgets('shows camera stream and dashboard on one page', (WidgetTester tester) async {
    await tester.pumpWidget(testApp());
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('bike-assist'), findsOneWidget);
    expect(find.text('串流狀態:模擬中'), findsOneWidget);
    expect(find.text('傾角'), findsOneWidget);
    expect(find.text('緯度'), findsOneWidget);

    // Force the BikeAssistApp (and its sqflite-backed RideRepository) to
    // dispose now, instead of leaking its DB isolate past this test.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('navigates to the ride history list screen', (WidgetTester tester) async {
    await tester.pumpWidget(testApp());
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byIcon(Icons.map_outlined));
    await tester.pump(); // start the page route transition
    await tester.pump(const Duration(milliseconds: 300)); // let it finish + load the ride list

    expect(find.text('歷史記錄'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  group('RideRepository', () {
    late RideRepository repository;

    setUp(() {
      repository = RideRepository(path: inMemoryDatabasePath);
    });

    tearDown(() => repository.close());

    test('records points and lists/loads a completed ride', () async {
      final rideId = await repository.startRide();
      await repository.addPoint(
        rideId,
        RoutePoint(lat: 25.0, lng: 121.0, speedKmh: 10, timestamp: DateTime(2026, 1, 1, 8)),
      );
      await repository.addPoint(
        rideId,
        RoutePoint(lat: 25.001, lng: 121.001, speedKmh: 12, timestamp: DateTime(2026, 1, 1, 8, 1)),
      );
      await repository.endRide(rideId, at: DateTime(2026, 1, 1, 8, 5));

      final rides = await repository.listRides();
      expect(rides, hasLength(1));
      expect(rides.first.isActive, isFalse);

      final points = await repository.loadPoints(rideId);
      expect(points, hasLength(2));
      expect(points.first.lat, 25.0);
    });

    test('closeOrphanRides stamps end_time using the last recorded point', () async {
      final rideId = await repository.startRide(at: DateTime(2026, 1, 1, 8));
      await repository.addPoint(
        rideId,
        RoutePoint(lat: 25.0, lng: 121.0, speedKmh: 10, timestamp: DateTime(2026, 1, 1, 8, 3)),
      );

      var rides = await repository.listRides();
      expect(rides.single.isActive, isTrue);

      await repository.closeOrphanRides();

      rides = await repository.listRides();
      expect(rides.single.isActive, isFalse);
      expect(rides.single.endTime, DateTime(2026, 1, 1, 8, 3));
    });
  });

  testWidgets('leaving the list screen while stopped prompts to restart', (tester) async {
    final repository = RideRepository(path: inMemoryDatabasePath);
    final dataService = _FakeBikeDataService();
    final cameraSource = CameraSource();
    final frameStore = RideFrameStore(baseDir: Directory.systemTemp);
    final recorder = RideRecorder(
      dataService: dataService,
      repository: repository,
      cameraSource: cameraSource,
      frameStore: frameStore,
    );
    // recorder.isRecording defaults to false — the "manually stopped" state.
    // We deliberately avoid awaiting any sqflite call inside this testWidgets
    // body: under the fake-async clock the DB isolate's reply is never
    // delivered, so such an await would hang the whole test (10-min timeout).

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RideListScreen(
                      repository: repository,
                      frameStore: frameStore,
                      recorder: recorder,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    // Bounded pumps (not pumpAndSettle): the ride-list FutureBuilder shows a
    // perpetual CircularProgressIndicator while sqflite resolves, which would
    // make pumpAndSettle never settle.
    await tester.tap(find.text('open'));
    await tester.pump(); // start the route transition
    await tester.pump(const Duration(milliseconds: 500)); // finish it

    // The status card sits above the FutureBuilder, so it renders regardless.
    expect(find.text('已停止'), findsOneWidget);

    // Leaving while stopped triggers the PopScope confirmation dialog.
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('尚未開始新的記錄'), findsOneWidget);
    expect(find.text('重新開始'), findsOneWidget);
    expect(find.text('先不要'), findsOneWidget);

    // Dismiss with 先不要 so no route/dialog is left pending.
    await tester.tap(find.text('先不要'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    dataService.dispose();
    cameraSource.dispose(); // its mock camera runs a Timer.periodic
    // Close the DB via runAsync so the ffi isolate's reply is delivered and
    // the process can exit cleanly.
    await tester.runAsync(() => repository.close());
  });

  testWidgets('device setup submits SSID/password and returns the device IP', (tester) async {
    String? sentSsid;
    String? sentPassword;
    String? returnedIp;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  returnedIp = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => DeviceWifiSetupScreen(
                        provision: (ssid, password) async {
                          sentSsid = ssid;
                          sentPassword = password;
                          return const ProvisionResult(ok: true, ip: '192.168.50.12');
                        },
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('設定裝置連線'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '網路名稱 (SSID)'), 'MyHotspot');
    await tester.enterText(find.widgetWithText(TextField, '網路密碼'), 'secret123');
    await tester.tap(find.text('送出設定'));
    await tester.pumpAndSettle();

    expect(sentSsid, 'MyHotspot');
    expect(sentPassword, 'secret123');
    expect(returnedIp, '192.168.50.12'); // popped back with the device IP
    expect(find.text('設定裝置連線'), findsNothing); // setup screen closed
  });

  testWidgets('device setup shows saved message when device not yet connected', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceWifiSetupScreen(
          provision: (ssid, password) async =>
              const ProvisionResult(ok: true, saved: true),
        ),
      ),
    );

    await tester.enterText(find.widgetWithText(TextField, '網路名稱 (SSID)'), 'MyHotspot');
    await tester.tap(find.text('送出設定'));
    await tester.pumpAndSettle();

    expect(find.textContaining('帳密已儲存'), findsOneWidget);
  });

  group('latestIndexAtOrBefore', () {
    final times = [
      DateTime(2026, 1, 1, 8, 0, 0),
      DateTime(2026, 1, 1, 8, 0, 1),
      DateTime(2026, 1, 1, 8, 0, 2),
    ];

    test('returns -1 for an empty list', () {
      expect(latestIndexAtOrBefore([], DateTime(2026)), -1);
    });

    test('returns -1 when the target precedes every entry', () {
      expect(latestIndexAtOrBefore(times, DateTime(2026, 1, 1, 7, 59, 59)), -1);
    });

    test('returns the last index when the target is past the end', () {
      expect(latestIndexAtOrBefore(times, DateTime(2026, 1, 1, 9)), 2);
    });

    test('returns the exact index on a direct hit', () {
      expect(latestIndexAtOrBefore(times, DateTime(2026, 1, 1, 8, 0, 1)), 1);
    });

    test('returns the preceding index when the target falls between entries', () {
      expect(
        latestIndexAtOrBefore(times, DateTime(2026, 1, 1, 8, 0, 1, 500)),
        1,
      );
    });
  });

  group('RideFrameStore', () {
    late Directory tempDir;
    late RideFrameStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('bike_frames_test');
      store = RideFrameStore(baseDir: tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('saves a frame and derives its path from rideId + timestamp', () async {
      final timestamp = DateTime(2026, 1, 1, 8, 0, 0);
      await store.saveFrame(7, Uint8List.fromList([1, 2, 3]), timestamp);

      final file = await store.frameFile(7, timestamp);
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(file.path, endsWith('${timestamp.millisecondsSinceEpoch}.jpg'));
    });

    test('deleteRideFrames removes the whole ride directory', () async {
      await store.saveFrame(7, Uint8List.fromList([1]), DateTime(2026, 1, 1, 8));
      await store.saveFrame(7, Uint8List.fromList([2]), DateTime(2026, 1, 1, 8, 0, 1));

      await store.deleteRideFrames(7);

      expect(await (await store.rideDir(7)).exists(), isFalse);
    });

    test('deleteRideFrames is a no-op when the ride has no frames', () async {
      await store.deleteRideFrames(999); // must not throw
    });
  });

  group('RideRepository frames & delete', () {
    late RideRepository repository;

    setUp(() {
      repository = RideRepository(path: inMemoryDatabasePath);
    });

    tearDown(() => repository.close());

    test('addFrames indexes timestamps and loads them in order', () async {
      final rideId = await repository.startRide();
      await repository.addFrames(rideId, [
        DateTime(2026, 1, 1, 8, 0, 2),
        DateTime(2026, 1, 1, 8, 0, 0),
        DateTime(2026, 1, 1, 8, 0, 1),
      ]);

      final frames = await repository.loadFrameTimestamps(rideId);
      expect(frames, [
        DateTime(2026, 1, 1, 8, 0, 0),
        DateTime(2026, 1, 1, 8, 0, 1),
        DateTime(2026, 1, 1, 8, 0, 2),
      ]);
    });

    test('addFrames with an empty list is a no-op', () async {
      final rideId = await repository.startRide();
      await repository.addFrames(rideId, []);
      expect(await repository.loadFrameTimestamps(rideId), isEmpty);
    });

    test('deleteRide clears the ride, its points and its frame index', () async {
      final rideId = await repository.startRide();
      await repository.addPoint(
        rideId,
        RoutePoint(lat: 25, lng: 121, speedKmh: 10, timestamp: DateTime(2026, 1, 1, 8)),
      );
      await repository.addFrames(rideId, [DateTime(2026, 1, 1, 8)]);

      await repository.deleteRide(rideId);

      expect(await repository.listRides(), isEmpty);
      expect(await repository.loadPoints(rideId), isEmpty);
      expect(await repository.loadFrameTimestamps(rideId), isEmpty);
    });

    test('deleting one ride leaves other rides intact', () async {
      final keep = await repository.startRide();
      final drop = await repository.startRide();
      await repository.addFrames(keep, [DateTime(2026, 1, 1, 8)]);
      await repository.addFrames(drop, [DateTime(2026, 1, 1, 9)]);

      await repository.deleteRide(drop);

      expect((await repository.listRides()).single.id, keep);
      expect(await repository.loadFrameTimestamps(keep), hasLength(1));
    });
  });

  group('BikeData.fromStatusJson', () {
    // A representative /api/status payload from the main.cpp firmware.
    final status = <String, dynamic>{
      'wifi': 'sta',
      'ip': '192.168.137.34',
      'imu': {'ok': true, 'roll': 1.2, 'pitch': -0.5, 'ax': 0.01, 'ay': 0.02, 'az': 0.99},
      'accel': {'event': 'BRAKE', 'magnitude': 2.3},
      'gps': {'chars': 1234, 'fix': true, 'lat': 23.99, 'lon': 121.60, 'speed': 12.5},
      'led': {'direction': 'LEFT', 'manual': false},
      'sd': {'ok': true, 'sizeMB': 60350},
      'camera': true,
    };

    test('maps core motion and GPS fields (lon -> lng, no gyro)', () {
      final data = BikeData.fromStatusJson(status);
      expect(data.ax, 0.01);
      expect(data.az, 0.99);
      expect(data.lat, 23.99);
      expect(data.lng, 121.60); // firmware sends longitude as "lon"
      expect(data.speedKmh, 12.5);
      expect(data.gx, 0); // /api/status carries no gyroscope
    });

    test('carries the extra firmware fields through', () {
      final data = BikeData.fromStatusJson(status);
      expect(data.roll, 1.2);
      expect(data.pitch, -0.5);
      expect(data.accelEvent, 'BRAKE');
      expect(data.accelMagnitude, 2.3);
      expect(data.ledDirection, 'LEFT');
      expect(data.ledManual, isFalse);
      expect(data.gpsFix, isTrue);
    });

    test('missing objects default numbers to 0 and extras to null', () {
      final data = BikeData.fromStatusJson(const {});
      expect(data.lat, 0);
      expect(data.speedKmh, 0);
      expect(data.roll, isNull);
      expect(data.accelEvent, isNull);
      expect(data.ledManual, isNull);
      expect(data.gpsFix, isNull);
    });
  });

  group('HttpStatusBikeDataService', () {
    test('polls /api/status and emits parsed BikeData', () async {
      Uri? requested;
      final client = MockClient((request) async {
        requested = request.url;
        return http.Response(
          '{"imu":{"ax":0.1,"ay":0.0,"az":1.0,"roll":5.0},'
          '"accel":{"event":"NORMAL","magnitude":1.0},'
          '"gps":{"fix":true,"lat":25.0,"lon":121.5,"speed":8.0},'
          '"led":{"direction":"NONE","manual":false}}',
          200,
        );
      });
      final service = HttpStatusBikeDataService(
        Uri.parse('http://192.168.1.42'),
        client: client,
        pollInterval: const Duration(milliseconds: 50),
      );
      addTearDown(service.dispose);

      final data = await service.stream.first;
      expect(requested.toString(), 'http://192.168.1.42/api/status');
      expect(data.lat, 25.0);
      expect(data.lng, 121.5);
      expect(data.speedKmh, 8.0);
      expect(data.roll, 5.0);
    });

    test('forwards a non-200 response as a stream error', () async {
      final client = MockClient((request) async => http.Response('nope', 503));
      final service = HttpStatusBikeDataService(
        Uri.parse('http://192.168.1.42'),
        client: client,
        pollInterval: const Duration(milliseconds: 50),
      );
      addTearDown(service.dispose);

      await expectLater(service.stream.first, throwsA(isA<String>()));
    });
  });
}
