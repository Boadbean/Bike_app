import 'recording_keep_alive.dart';

/// Reference-counts the single Android foreground service so more than one
/// feature can keep the process alive independently.
///
/// Both ride recording and the emergency BLE relay need the process to stay
/// scheduled with the screen off, but there is only one foreground service.
/// Each feature [acquire]s a hold when it needs the process kept alive and
/// [release]s it when done; the underlying service starts on the first hold and
/// stops only once the last hold is released — so one feature stopping never
/// tears the service out from under the other.
class KeepAliveController {
  KeepAliveController(this._impl);

  final RecordingKeepAlive _impl;
  int _holds = 0;

  Future<void> acquire() async {
    _holds++;
    if (_holds == 1) await _impl.start();
  }

  Future<void> release() async {
    if (_holds == 0) return;
    _holds--;
    if (_holds == 0) await _impl.stop();
  }
}
