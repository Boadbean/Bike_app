import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/route_point.dart';
import 'ride_frame_store.dart';
import 'ride_repository.dart';
import 'video_encoder.dart';

/// Thrown when a ride can't be exported (e.g. it no longer exists).
class RideExportException implements Exception {
  RideExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The files a ride export produces: a coordinate [csv] (always) and an H.264
/// [video] assembled from the recorded camera frames ([video] is null when the
/// ride has no frames to build one from).
class RideExport {
  RideExport({required this.csv, this.video});

  final File csv;
  final File? video;

  /// The files to hand to the share sheet — video first (when present), then
  /// the CSV.
  List<File> get files => [?video, csv];
}

/// Exports a recorded ride into two shareable files on the phone: an MP4 video
/// built from the ride's camera frames, and a CSV of its GPS coordinates. This
/// replaces the old self-contained `.zip` archive: the outputs are ordinary
/// media/data files the user can open, keep, or send anywhere — not a bundle
/// that only this app understands.
class RideExportService {
  RideExportService({
    required this.repository,
    required this.frameStore,
    required this.videoEncoder,
    this.workDir,
  });

  final RideRepository repository;
  final RideFrameStore frameStore;
  final VideoEncoder videoEncoder;

  /// Where the video/CSV are written before they're handed to the share sheet.
  /// Injectable for tests; defaults to the system temp directory.
  final Directory? workDir;

  /// Builds the coordinate CSV and (when the ride has frames) the MP4, and
  /// returns both. The files live in a temp directory; the caller shares them
  /// and may delete them afterwards.
  Future<RideExport> exportRide(int rideId) async {
    final ride = await repository.loadRide(rideId);
    if (ride == null) {
      throw RideExportException('找不到這筆記錄');
    }
    final points = await repository.loadPoints(rideId);
    final frameTimestamps = await repository.loadFrameTimestamps(rideId);

    final dir = workDir ?? Directory.systemTemp;
    await dir.create(recursive: true);
    final base = _baseName(ride.startTime);

    // Coordinate CSV — always written, even with no GPS points (header only).
    final csvFile = File(p.join(dir.path, '$base.csv'));
    await csvFile.writeAsString(_buildCsv(points));

    // Video — only when there are frames on disk to assemble into one.
    final framePaths = <String>[];
    final ptsMs = <int>[];
    if (frameTimestamps.isNotEmpty) {
      final firstMs = frameTimestamps.first.millisecondsSinceEpoch;
      for (final t in frameTimestamps) {
        final file = await frameStore.frameFile(rideId, t);
        if (!await file.exists()) continue; // indexed frame missing its image
        framePaths.add(file.path);
        ptsMs.add(t.millisecondsSinceEpoch - firstMs);
      }
    }

    File? videoFile;
    if (framePaths.isNotEmpty) {
      final out = File(p.join(dir.path, '$base.mp4'));
      if (await out.exists()) await out.delete();
      await videoEncoder.encodeJpegsToMp4(
        framePaths: framePaths,
        ptsMs: ptsMs,
        outputPath: out.path,
        fps: _estimateFps(ptsMs),
      );
      videoFile = out;
    }

    return RideExport(csv: csvFile, video: videoFile);
  }

  /// One row per GPS sample: ISO-8601 timestamp, latitude, longitude, speed.
  String _buildCsv(List<RoutePoint> points) {
    final buffer = StringBuffer('timestamp,latitude,longitude,speed_kmh\n');
    for (final point in points) {
      buffer
        ..write(point.timestamp.toIso8601String())
        ..write(',')
        ..write(point.lat.toStringAsFixed(7))
        ..write(',')
        ..write(point.lng.toStringAsFixed(7))
        ..write(',')
        ..write(point.speedKmh.toStringAsFixed(2))
        ..write('\n');
    }
    return buffer.toString();
  }

  /// A nominal frame rate derived from the real capture timing, so the video's
  /// duration matches the ride. Clamped to a sane 1–30 fps.
  int _estimateFps(List<int> ptsMs) {
    if (ptsMs.length < 2) return 1;
    final spanMs = ptsMs.last - ptsMs.first;
    if (spanMs <= 0) return 1;
    final fps = ((ptsMs.length - 1) * 1000 / spanMs).round();
    return fps.clamp(1, 30);
  }

  String _baseName(DateTime startTime) {
    final t = startTime;
    String two(int n) => n.toString().padLeft(2, '0');
    return 'bikeride_${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
