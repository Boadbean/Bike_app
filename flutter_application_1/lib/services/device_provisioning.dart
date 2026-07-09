import 'dart:convert';

import 'package:http/http.dart' as http;

/// Result of sending WiFi credentials to the ESP32 setup AP.
class ProvisionResult {
  const ProvisionResult({
    required this.ok,
    this.ip,
    this.saved = false,
    this.error,
  });

  /// Whether the device accepted the credentials.
  final bool ok;

  /// The device's STA IP, present when it connected during provisioning.
  final String? ip;

  /// True when credentials were saved but the device hadn't connected yet
  /// (it will retry after rebooting).
  final bool saved;

  /// Human-readable error when [ok] is false.
  final String? error;
}

typedef ProvisionFn = Future<ProvisionResult> Function(String ssid, String password);

/// Default setup-AP endpoint served by the firmware (`WiFi.softAPIP()`).
const String kProvisionUrl = 'http://192.168.4.1/provision';

/// The setup hotspot the firmware opens when it has no saved WiFi (see
/// `camtest.cpp` AP_SSID / AP_PASS). Shown in the connect UI so the user knows
/// which network to join and its password.
const String kSetupApSsid = 'bike-assist-setup';
const String kSetupApPassword = 'bikeassist';

/// Sends the target WiFi credentials to the ESP32 setup AP over HTTP.
/// The firmware tries to connect (up to ~12s) before responding, so the
/// timeout here is deliberately generous.
Future<ProvisionResult> provisionDevice(String ssid, String password) async {
  try {
    final response = await http
        .post(
          Uri.parse(kProvisionUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'ssid': ssid, 'password': password}),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      return ProvisionResult(ok: false, error: 'HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['status'] == 'connected') {
      return ProvisionResult(ok: true, ip: data['ip'] as String?);
    }
    return const ProvisionResult(ok: true, saved: true);
  } catch (error) {
    return ProvisionResult(ok: false, error: error.toString());
  }
}
