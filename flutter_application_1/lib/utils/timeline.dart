/// Binary-searches [sorted] (ascending) for the index of the last entry whose
/// timestamp is at or before [target].
///
/// Returns -1 when [sorted] is empty or every entry is later than [target].
/// Used by ride playback to pick the current camera frame / route point for a
/// given point on the timeline.
int latestIndexAtOrBefore(List<DateTime> sorted, DateTime target) {
  var low = 0;
  var high = sorted.length - 1;
  var result = -1;

  while (low <= high) {
    final mid = (low + high) ~/ 2;
    if (sorted[mid].isAfter(target)) {
      high = mid - 1;
    } else {
      result = mid; // candidate; keep looking further right
      low = mid + 1;
    }
  }
  return result;
}
