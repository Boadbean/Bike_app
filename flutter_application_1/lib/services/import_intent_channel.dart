import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges "open with / share to bike-assist" for a `.zip`. The Android side
/// (MainActivity) copies the incoming file into cache and hands us its path;
/// Dart then runs the import. Lets the user import from a file manager or chat
/// app — which have their own back button — instead of the system file picker.
///
/// A no-op on platforms without the native channel: [initialImport] swallows
/// the missing-plugin error and [onImport] simply never fires.
class ImportIntentChannel {
  ImportIntentChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('bike_assist/import');

  final MethodChannel _channel;
  void Function(String path)? _onImport;

  /// Fires when a `.zip` is opened/shared while the app is already running.
  set onImport(void Function(String path)? handler) {
    _onImport = handler;
    _channel.setMethodCallHandler(_handle);
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method == 'onImport' && call.arguments is String) {
      _onImport?.call(call.arguments as String);
    }
  }

  /// Path of a `.zip` the app was cold-started to open, or null if it was
  /// launched normally.
  Future<String?> initialImport() async {
    try {
      return await _channel.invokeMethod<String>('getInitialImport');
    } on MissingPluginException {
      return null; // not Android, or channel not registered
    } catch (error) {
      debugPrint('[ImportIntentChannel] getInitialImport failed: $error');
      return null;
    }
  }
}
