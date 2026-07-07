/// A single recorded ride session. `endTime == null` means it is still
/// actively being recorded.
class Ride {
  const Ride({
    required this.id,
    required this.startTime,
    this.endTime,
  });

  final int id;
  final DateTime startTime;
  final DateTime? endTime;

  bool get isActive => endTime == null;

  Duration get duration => (endTime ?? DateTime.now()).difference(startTime);
}
