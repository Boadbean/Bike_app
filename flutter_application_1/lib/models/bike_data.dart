/// Telemetry snapshot matching the ESP32-S3 JSON payload.
///
/// The core position/speed fields come from the firmware's `GET /api/status`
/// endpoint. A handful of extra fields (crash/brake event, indicator state,
/// GPS diagnostics) are carried through so the app *receives* them; they're
/// null when the source doesn't provide them.
///
/// The IMU/gyroscope motion data (raw accel/gyro, filtered roll/pitch, and the
/// derived lean angle) is no longer received or displayed — the dashboard only
/// shows speed and GPS position now.
class BikeData {
  final double lat;
  final double lng;
  final double speedKmh;
  final DateTime timestamp;

  // ── Extra firmware telemetry (received, not displayed) ──────────────────
  /// Accelerometer event classification: `NORMAL` | `BRAKE` | `COLLISION`.
  final String? accelEvent;

  /// Combined acceleration magnitude, in G.
  final double? accelMagnitude;

  /// Turn-indicator state: `NONE` | `LEFT` | `RIGHT` | `HAZARD`.
  final String? ledDirection;

  /// Whether the indicator is under manual (app) control vs. auto lean-based.
  final bool? ledManual;

  /// Whether the GPS currently has a valid fix.
  final bool? gpsFix;

  /// Count of NMEA characters the firmware has parsed from the GPS module.
  /// 0 while connected means no data is reaching the ESP32 (wiring), whereas a
  /// rising count with [gpsFix] false means it's receiving but not yet locked.
  final int? gpsChars;

  const BikeData({
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.timestamp,
    this.accelEvent,
    this.accelMagnitude,
    this.ledDirection,
    this.ledManual,
    this.gpsFix,
    this.gpsChars,
  });

  /// Parses the firmware's `/api/status` JSON (nested `gps` / `accel` / `led`
  /// objects) into a [BikeData]. Missing numeric fields default to 0; the extra
  /// fields default to null when absent.
  ///
  /// Note: GPS longitude arrives as `lon`. The `imu` object (accel/gyro/roll/
  /// pitch) is intentionally ignored — the app no longer uses motion data.
  factory BikeData.fromStatusJson(Map<String, dynamic> json, {DateTime? timestamp}) {
    Map<String, dynamic> obj(String key) {
      final value = json[key];
      return value is Map ? value.cast<String, dynamic>() : const {};
    }

    final gps = obj('gps');
    final accel = obj('accel');
    final led = obj('led');

    double num0(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
    double? numOrNull(dynamic v) => (v as num?)?.toDouble();

    return BikeData(
      lat: num0(gps['lat']),
      lng: num0(gps['lon']),
      speedKmh: num0(gps['speed']),
      timestamp: timestamp ?? DateTime.now(),
      accelEvent: accel['event'] as String?,
      accelMagnitude: numOrNull(accel['magnitude']),
      ledDirection: led['direction'] as String?,
      ledManual: led['manual'] as bool?,
      gpsFix: gps['fix'] as bool?,
      gpsChars: (gps['chars'] as num?)?.toInt(),
    );
  }
}
