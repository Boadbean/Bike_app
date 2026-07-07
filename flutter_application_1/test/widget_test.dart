import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flutter_application_1/main.dart';
import 'package:flutter_application_1/models/bike_data.dart';
import 'package:flutter_application_1/models/route_point.dart';
import 'package:flutter_application_1/screens/device_wifi_setup_screen.dart';
import 'package:flutter_application_1/screens/ride_list_screen.dart';
import 'package:flutter_application_1/services/bike_data_service.dart';
import 'package:flutter_application_1/services/device_provisioning.dart';
import 'package:flutter_application_1/services/ride_recorder.dart';
import 'package:flutter_application_1/services/ride_repository.dart';

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

  testWidgets('shows camera stream and dashboard on one page', (WidgetTester tester) async {
    await tester.pumpWidget(const BikeAssistApp());
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
    await tester.pumpWidget(const BikeAssistApp());
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
    final recorder = RideRecorder(dataService: dataService, repository: repository);
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
                    builder: (_) => RideListScreen(repository: repository, recorder: recorder),
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
}
