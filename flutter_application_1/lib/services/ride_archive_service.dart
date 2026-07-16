import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../models/route_point.dart';
import 'ride_frame_store.dart';
import 'ride_repository.dart';

/// Thrown when an imported file isn't a bike-assist ride archive (wrong
/// contents, or a newer format this build doesn't understand).
class RideArchiveException implements Exception {
  RideArchiveException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Exports a recorded ride to a single self-contained `.zip` the user can share
/// or back up, and imports one back. The archive bundles both the route/speed
/// track and the recorded camera frames, so a ride moves between devices whole:
///
/// ```
/// manifest.json           ride metadata + route points + frame timestamps
/// frames/<epochMs>.jpg     one file per recorded camera frame
/// ```
///
/// Frames are stored uncompressed (level 0) — they're already JPEG, so
/// deflating them again only burns CPU for no size win.
class RideArchiveService {
  RideArchiveService({
    required this.repository,
    required this.frameStore,
    this.workDir,
  });

  final RideRepository repository;
  final RideFrameStore frameStore;

  /// Where export writes the `.zip` before it's handed to the share sheet.
  /// Injectable for tests; defaults to the system temp directory.
  final Directory? workDir;

  static const _manifestName = 'manifest.json';
  static const _framesDir = 'frames';
  static const _format = 'bike-assist-ride';
  static const _version = 1;
  static const _storeLevel = 0; // deflate level 0 = no compression

  /// Builds a `.zip` for [rideId] and returns it. The file lives in a temp
  /// directory; the caller shares it and may delete it afterwards.
  Future<File> exportRide(int rideId) async {
    final ride = await repository.loadRide(rideId);
    if (ride == null) {
      throw RideArchiveException('找不到這筆記錄');
    }
    final points = await repository.loadPoints(rideId);
    final frameTimestamps = await repository.loadFrameTimestamps(rideId);

    final manifest = jsonEncode({
      'format': _format,
      'version': _version,
      'startTime': ride.startTime.toIso8601String(),
      'endTime': ride.endTime?.toIso8601String(),
      'points': [
        for (final point in points)
          {
            'lat': point.lat,
            'lng': point.lng,
            'speedKmh': point.speedKmh,
            't': point.timestamp.toIso8601String(),
          },
      ],
      'frames': [
        for (final t in frameTimestamps) t.millisecondsSinceEpoch,
      ],
    });

    final dir = workDir ?? Directory.systemTemp;
    await dir.create(recursive: true);
    final zipPath = p.join(dir.path, _exportFileName(ride.startTime));
    // Overwrite any leftover from a previous export of the same ride/second.
    final existing = File(zipPath);
    if (await existing.exists()) await existing.delete();

    final encoder = ZipFileEncoder();
    encoder.create(zipPath);
    try {
      encoder.addArchiveFile(ArchiveFile.string(_manifestName, manifest));
      for (final t in frameTimestamps) {
        final file = await frameStore.frameFile(rideId, t);
        if (!await file.exists()) continue; // index row without its image; skip
        await encoder.addFile(
          file,
          '$_framesDir/${t.millisecondsSinceEpoch}.jpg',
          _storeLevel,
        );
      }
    } finally {
      await encoder.close();
    }
    return File(zipPath);
  }

  /// Imports a ride archive at [zipPath] as a brand-new ride (a fresh id, so it
  /// never overwrites an existing one) and returns that id. Restores both the
  /// route points and the camera frames.
  Future<int> importRide(String zipPath) async {
    final input = InputFileStream(zipPath);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } on Exception {
      await input.close();
      throw RideArchiveException('這個檔案不是有效的記錄封存檔');
    }

    try {
      final manifestEntry = archive.findFile(_manifestName);
      if (manifestEntry == null) {
        throw RideArchiveException('封存檔缺少 manifest.json,可能不是記錄檔');
      }

      final Map<String, dynamic> manifest;
      try {
        manifest = jsonDecode(utf8.decode(manifestEntry.content))
            as Map<String, dynamic>;
      } on Exception {
        throw RideArchiveException('記錄檔內容毀損,無法讀取');
      }
      if (manifest['format'] != _format) {
        throw RideArchiveException('這不是 bike-assist 的記錄檔');
      }
      final version = manifest['version'] as num?;
      if (version != null && version > _version) {
        throw RideArchiveException('這個記錄檔來自較新版本的 App,請先更新');
      }

      final startTime = DateTime.parse(manifest['startTime'] as String);
      final endTime = manifest['endTime'] == null
          ? null
          : DateTime.parse(manifest['endTime'] as String);
      final points = [
        for (final raw in (manifest['points'] as List? ?? const []))
          RoutePoint(
            lat: (raw['lat'] as num).toDouble(),
            lng: (raw['lng'] as num).toDouble(),
            speedKmh: (raw['speedKmh'] as num).toDouble(),
            timestamp: DateTime.parse(raw['t'] as String),
          ),
      ];

      final rideId = await repository.insertImportedRide(
        startTime: startTime,
        endTime: endTime,
        points: points,
      );

      // Write frame images under the new id, then index only the ones that
      // actually landed — so the frame table never points at a missing file.
      final restored = <DateTime>[];
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        if (p.dirname(entry.name) != _framesDir) continue;
        final millis = int.tryParse(p.basenameWithoutExtension(entry.name));
        if (millis == null) continue;
        final timestamp = DateTime.fromMillisecondsSinceEpoch(millis);
        await frameStore.saveFrame(rideId, entry.content, timestamp);
        restored.add(timestamp);
      }
      if (restored.isNotEmpty) {
        await repository.addFrames(rideId, restored);
      }
      return rideId;
    } finally {
      await input.close();
    }
  }

  String _exportFileName(DateTime startTime) {
    final t = startTime;
    String two(int n) => n.toString().padLeft(2, '0');
    return 'bikeride_${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}.zip';
  }
}
