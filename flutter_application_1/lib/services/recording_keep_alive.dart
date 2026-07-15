import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the app's process alive while a ride is being recorded.
///
/// Everything that feeds a recording — the `/api/status` poll, the MJPEG frame
/// stream, the database and frame-file writes — runs on the main isolate. Once
/// the screen goes off Android freezes the process and all of it stops, so a
/// ride recorded with the phone in a pocket would capture nothing.
///
/// An Android foreground service (with a wake lock and a Wi-Fi lock) keeps the
/// process scheduled and the radio awake for as long as it runs. No background
/// isolate is involved: the service exists purely to hold the process open, so
/// the recorder keeps running exactly as it does in the foreground.
abstract class RecordingKeepAlive {
  /// The Android foreground service on Android, a no-op everywhere else
  /// (tests, desktop, iOS), so callers never have to check the platform.
  factory RecordingKeepAlive.forPlatform() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return ForegroundServiceKeepAlive();
    }
    return NoopKeepAlive();
  }

  Future<void> start();

  Future<void> stop();
}

/// Does nothing. Used off Android, and in tests, where the plugin's platform
/// channel isn't there to answer.
class NoopKeepAlive implements RecordingKeepAlive {
  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

class ForegroundServiceKeepAlive implements RecordingKeepAlive {
  bool _configured = false;

  @override
  Future<void> start() async {
    if (await FlutterForegroundTask.isRunningService) return;
    _configure();

    // Android 13+ silently kills a foreground service whose notification it
    // can't display, so the permission has to land before the service starts.
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    // No `callback` — that would spawn a background isolate. The service is
    // only here to keep *this* isolate's timers and sockets running.
    final result = await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.connectedDevice],
      notificationTitle: 'bike-assist 記錄中',
      notificationText: '螢幕關閉時持續接收裝置資料',
    );
    if (result is ServiceRequestFailure) {
      debugPrint('[KeepAlive] 前景服務啟動失敗: ${result.error}');
      return;
    }

    // Aggressive OEM battery managers (Xiaomi, Oppo, Samsung…) will kill even a
    // foreground service unless the app is exempt. One-time system prompt.
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  @override
  Future<void> stop() async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.stopService();
  }

  void _configure() {
    if (_configured) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'bike_assist_recording',
        channelName: '騎乘記錄',
        channelDescription: '記錄期間持續接收裝置資料',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Nothing to repeat — there's no TaskHandler in the service.
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _configured = true;
  }
}
