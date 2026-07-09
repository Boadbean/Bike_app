import 'dart:math' show atan2, pi;

/// Telemetry snapshot matching the ESP32-S3 JSON payload.
///
/// The core motion/position fields come from either the mock generator or the
/// firmware's `GET /api/status` endpoint. The firmware also reports a handful
/// of extra fields (filtered roll/pitch, crash/brake event, indicator state).
/// Those are carried through here so the app *receives* them, but the dashboard
/// does not display them yet — they're null when the source doesn't provide them
/// (e.g. the mock).
class BikeData {
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
  final double lat;
  final double lng;
  final double speedKmh;
  final DateTime timestamp;

  // ── Extra firmware telemetry (received, not yet displayed) ──────────────
  /// Complementary-filtered roll from the firmware, in degrees.
  final double? roll;

  /// Complementary-filtered pitch from the firmware, in degrees.
  final double? pitch;

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

  const BikeData({
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.timestamp,
    this.roll,
    this.pitch,
    this.accelEvent,
    this.accelMagnitude,
    this.ledDirection,
    this.ledManual,
    this.gpsFix,
  });

  /// Lean angle derived from the accelerometer, in degrees.
  /// 0° = upright, positive = leaning right, negative = leaning left.
  double get leanAngleDeg => atan2(ax, az) * 180 / pi;

  /// Parses the firmware's `/api/status` JSON (nested `imu` / `gps` / `accel`
  /// / `led` objects) into a [BikeData]. Missing numeric fields default to 0;
  /// the extra fields default to null when absent.
  ///
  /// Note: `/api/status` reports acceleration in G and has no gyroscope, so
  /// [gx]/[gy]/[gz] are set to 0. GPS longitude arrives as `lon`.
  factory BikeData.fromStatusJson(Map<String, dynamic> json, {DateTime? timestamp}) {
    Map<String, dynamic> obj(String key) {
      final value = json[key];
      return value is Map ? value.cast<String, dynamic>() : const {};
    }

    final imu = obj('imu');
    final gps = obj('gps');
    final accel = obj('accel');
    final led = obj('led');

    double num0(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
    double? numOrNull(dynamic v) => (v as num?)?.toDouble();

    return BikeData(
      ax: num0(imu['ax']),
      ay: num0(imu['ay']),
      az: num0(imu['az']),
      gx: 0,
      gy: 0,
      gz: 0,
      lat: num0(gps['lat']),
      lng: num0(gps['lon']),
      speedKmh: num0(gps['speed']),
      timestamp: timestamp ?? DateTime.now(),
      roll: numOrNull(imu['roll']),
      pitch: numOrNull(imu['pitch']),
      accelEvent: accel['event'] as String?,
      accelMagnitude: numOrNull(accel['magnitude']),
      ledDirection: led['direction'] as String?,
      ledManual: led['manual'] as bool?,
      gpsFix: gps['fix'] as bool?,
    );
  }
}
