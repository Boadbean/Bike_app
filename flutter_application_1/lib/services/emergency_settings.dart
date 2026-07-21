import 'package:shared_preferences/shared_preferences.dart';

/// Persists the emergency-relay configuration: whether it's armed, and the
/// server URL that a scanned fall alert is POSTed to. Backed by
/// shared_preferences so it survives restarts.
class EmergencySettings {
  static const _kEnabled = 'emergency_relay_enabled';
  static const _kUrl = 'emergency_relay_url';

  const EmergencySettings();

  Future<EmergencyConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return EmergencyConfig(
      enabled: prefs.getBool(_kEnabled) ?? false,
      serverUrl: prefs.getString(_kUrl) ?? '',
    );
  }

  Future<void> save(EmergencyConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, config.enabled);
    await prefs.setString(_kUrl, config.serverUrl.trim());
  }
}

/// Immutable snapshot of the emergency-relay settings.
class EmergencyConfig {
  const EmergencyConfig({required this.enabled, required this.serverUrl});

  final bool enabled;
  final String serverUrl;

  EmergencyConfig copyWith({bool? enabled, String? serverUrl}) => EmergencyConfig(
        enabled: enabled ?? this.enabled,
        serverUrl: serverUrl ?? this.serverUrl,
      );
}
