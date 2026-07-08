import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' show join;
import 'package:path_provider/path_provider.dart';

/// Stores recorded camera frames as individual image files on disk, one
/// directory per ride: `<base>/rides/<rideId>/<epochMillis>.jpg`.
///
/// Only the bytes live here — the timestamp index lives in the `ride_frames`
/// table (see [RideRepository]), so playback can query frames in order without
/// scanning a directory that may hold tens of thousands of files.
///
/// Paths are derived from `rideId + timestamp` rather than stored, because an
/// app's documents directory can change between installs/updates (notably on
/// iOS), which would invalidate any absolute path persisted in the database.
class RideFrameStore {
  /// [baseDir] is injectable so tests can use a temp directory instead of
  /// depending on the platform's documents directory.
  RideFrameStore({Directory? baseDir}) : _explicitBaseDir = baseDir;

  final Directory? _explicitBaseDir;
  Directory? _cachedBaseDir;

  Future<Directory> _baseDir() async {
    return _cachedBaseDir ??=
        _explicitBaseDir ?? await getApplicationDocumentsDirectory();
  }

  /// Directory holding every frame for [rideId].
  Future<Directory> rideDir(int rideId) async {
    final base = await _baseDir();
    return Directory(join(base.path, 'rides', '$rideId'));
  }

  /// File a frame recorded at [timestamp] is (or would be) stored at.
  Future<File> frameFile(int rideId, DateTime timestamp) async {
    final dir = await rideDir(rideId);
    return File(join(dir.path, '${timestamp.millisecondsSinceEpoch}.jpg'));
  }

  Future<void> saveFrame(int rideId, Uint8List bytes, DateTime timestamp) async {
    final file = await frameFile(rideId, timestamp);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: false);
  }

  /// Removes every frame recorded for [rideId]. Safe to call when the ride has
  /// no frames on disk.
  Future<void> deleteRideFrames(int rideId) async {
    final dir = await rideDir(rideId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
