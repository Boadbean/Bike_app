/// One sample of a recorded ride, used for historical route playback.
class RoutePoint {
  const RoutePoint({
    required this.lat,
    required this.lng,
    required this.speedKmh,
    required this.timestamp,
  });

  final double lat;
  final double lng;
  final double speedKmh;
  final DateTime timestamp;
}
