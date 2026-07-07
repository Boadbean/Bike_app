import 'dart:math' show atan2, pi;

/// Telemetry snapshot matching the ESP32-S3 JSON payload
/// (`{"ax":..,"ay":..,"az":..,"gx":..,"gy":..,"gz":..,"lat":..,"lng":..}` plus GPS speed).
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
  });

  /// Lean angle derived from the accelerometer, in degrees.
  /// 0° = upright, positive = leaning right, negative = leaning left.
  double get leanAngleDeg => atan2(ax, az) * 180 / pi;
}
