import 'package:path/path.dart' show join;
import 'package:sqflite/sqflite.dart';

import '../models/ride.dart';
import '../models/route_point.dart';

/// Persists recorded rides (and their GPS/speed points) to a local SQLite
/// database via sqflite, so multiple ride recordings can accumulate across
/// app sessions.
class RideRepository {
  RideRepository({String? path}) : _explicitPath = path;

  final String? _explicitPath;
  Database? _db;

  Future<Database> get _database async {
    return _db ??= await _open();
  }

  Future<Database> _open() async {
    final path = _explicitPath ?? join(await getDatabasesPath(), 'bike_assist_rides.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE rides (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_time TEXT NOT NULL,
            end_time TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE ride_points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ride_id INTEGER NOT NULL,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            speed_kmh REAL NOT NULL,
            timestamp TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Future<int> startRide({DateTime? at}) async {
    final db = await _database;
    return db.insert('rides', {
      'start_time': (at ?? DateTime.now()).toIso8601String(),
      'end_time': null,
    });
  }

  Future<void> endRide(int rideId, {DateTime? at}) async {
    final db = await _database;
    await db.update(
      'rides',
      {'end_time': (at ?? DateTime.now()).toIso8601String()},
      where: 'id = ?',
      whereArgs: [rideId],
    );
  }

  Future<void> addPoint(int rideId, RoutePoint point) async {
    final db = await _database;
    await db.insert('ride_points', {
      'ride_id': rideId,
      'lat': point.lat,
      'lng': point.lng,
      'speed_kmh': point.speedKmh,
      'timestamp': point.timestamp.toIso8601String(),
    });
  }

  Future<List<Ride>> listRides() async {
    final db = await _database;
    final rows = await db.query('rides', orderBy: 'start_time DESC');
    return rows
        .map((row) => Ride(
              id: row['id'] as int,
              startTime: DateTime.parse(row['start_time'] as String),
              endTime: row['end_time'] == null
                  ? null
                  : DateTime.parse(row['end_time'] as String),
            ))
        .toList();
  }

  Future<List<RoutePoint>> loadPoints(int rideId) async {
    final db = await _database;
    final rows = await db.query(
      'ride_points',
      where: 'ride_id = ?',
      whereArgs: [rideId],
      orderBy: 'timestamp ASC',
    );
    return rows
        .map((row) => RoutePoint(
              lat: row['lat'] as double,
              lng: row['lng'] as double,
              speedKmh: row['speed_kmh'] as double,
              timestamp: DateTime.parse(row['timestamp'] as String),
            ))
        .toList();
  }

  /// Closes out any ride left with a null `end_time` from a previous session
  /// that never got a clean shutdown (e.g. the process was killed outright).
  /// Each orphan is stamped with the timestamp of its last recorded point
  /// (or its own start time if it has no points at all).
  Future<void> closeOrphanRides() async {
    final db = await _database;
    final orphans = await db.query('rides', where: 'end_time IS NULL');
    for (final row in orphans) {
      final rideId = row['id'] as int;
      final lastPoint = await db.query(
        'ride_points',
        where: 'ride_id = ?',
        whereArgs: [rideId],
        orderBy: 'timestamp DESC',
        limit: 1,
      );
      final endTime = lastPoint.isEmpty
          ? DateTime.parse(row['start_time'] as String)
          : DateTime.parse(lastPoint.first['timestamp'] as String);
      await db.update(
        'rides',
        {'end_time': endTime.toIso8601String()},
        where: 'id = ?',
        whereArgs: [rideId],
      );
    }
  }

  Future<void> close() async {
    final db = _db;
    if (db != null) {
      await db.close();
      _db = null;
    }
  }
}
