import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/route_point.dart';
import '../services/ride_frame_store.dart';
import '../services/ride_repository.dart';
import '../utils/timeline.dart';

/// Replays one recorded ride against a real timeline: the camera footage
/// captured during the ride plays on top, while the map below advances its
/// marker and highlights the route travelled so far.
///
/// Playback is driven by a clock (not by stepping route points), because
/// frames are recorded far more often than GPS points — stepping points would
/// cap the camera at the point rate and most frames would never be shown.
class RidePlaybackScreen extends StatefulWidget {
  const RidePlaybackScreen({
    super.key,
    required this.rideId,
    required this.repository,
    required this.frameStore,
  });

  final int rideId;
  final RideRepository repository;
  final RideFrameStore frameStore;

  @override
  State<RidePlaybackScreen> createState() => _RidePlaybackScreenState();
}

class _RidePlaybackScreenState extends State<RidePlaybackScreen> {
  static const _tickInterval = Duration(milliseconds: 33); // ~30Hz, enough for 15fps
  static const _speeds = [1, 2, 4];

  final MapController _mapController = MapController();

  /// Separate notifiers so the ~15Hz camera updates don't rebuild the map,
  /// which only needs to change when the route point (~2Hz) changes. Nothing
  /// on this screen calls setState per tick — that would rebuild FlutterMap
  /// 30 times a second.
  final ValueNotifier<int> _frameIndex = ValueNotifier(-1);
  final ValueNotifier<int> _pointIndex = ValueNotifier(0);
  final ValueNotifier<Duration> _elapsedNotifier = ValueNotifier(Duration.zero);

  List<RoutePoint>? _points;
  List<DateTime> _pointTimes = const []; // precomputed; searched every tick
  List<DateTime> _frameTimes = const [];
  List<File> _frameFiles = const [];

  DateTime? _startTime;
  Duration _total = Duration.zero;

  Duration get _elapsed => _elapsedNotifier.value;

  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  Duration _clockBase = Duration.zero; // elapsed at the moment the clock started
  int _speed = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final points = await widget.repository.loadPoints(widget.rideId);
    final frameTimes = await widget.repository.loadFrameTimestamps(widget.rideId);
    final files = <File>[];
    for (final time in frameTimes) {
      files.add(await widget.frameStore.frameFile(widget.rideId, time));
    }
    if (!mounted) return;

    // The timeline spans whichever of the two streams started/ended first/last.
    final times = <DateTime>[
      if (points.isNotEmpty) points.first.timestamp,
      if (points.isNotEmpty) points.last.timestamp,
      if (frameTimes.isNotEmpty) frameTimes.first,
      if (frameTimes.isNotEmpty) frameTimes.last,
    ]..sort();

    setState(() {
      _points = points;
      _pointTimes = points.map((p) => p.timestamp).toList(growable: false);
      _frameTimes = frameTimes;
      _frameFiles = files;
      _startTime = times.isEmpty ? null : times.first;
      _total = times.isEmpty ? Duration.zero : times.last.difference(times.first);
    });

    if (points.isNotEmpty) {
      final bounds = LatLngBounds.fromPoints(
        points.map((p) => LatLng(p.lat, p.lng)).toList(),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _mapController.fitCamera(
          CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(32)),
        );
      });
    }
    _syncTo(Duration.zero);
  }

  bool get _playing => _timer != null;

  void _togglePlayback() {
    if (_playing) {
      _pause();
    } else {
      _play();
    }
  }

  void _play() {
    if (_startTime == null || _total == Duration.zero) return;
    if (_elapsed >= _total) _syncTo(Duration.zero); // restart from the top

    _clockBase = _elapsed;
    _clock
      ..reset()
      ..start();
    _timer = Timer.periodic(_tickInterval, (_) => _onTick());
    setState(() {});
  }

  void _pause() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    setState(() {});
  }

  void _onTick() {
    // Derive from the stopwatch rather than accumulating tick durations, so a
    // late tick doesn't make playback drift behind the recorded timeline.
    final elapsed = _clockBase + _clock.elapsed * _speed;
    if (elapsed >= _total) {
      _syncTo(_total);
      _pause();
      return;
    }
    _syncTo(elapsed);
  }

  /// Positions the camera frame and map marker at [elapsed] into the ride.
  /// Only the notifiers are touched, so the map rebuilds only when the route
  /// point actually advances.
  void _syncTo(Duration elapsed) {
    final start = _startTime;
    if (start == null) return;
    _elapsedNotifier.value = elapsed;
    final now = start.add(elapsed);

    _frameIndex.value = latestIndexAtOrBefore(_frameTimes, now);

    final points = _points;
    if (points != null && points.isNotEmpty) {
      final index = latestIndexAtOrBefore(_pointTimes, now);
      final clamped = index < 0 ? 0 : index;
      if (clamped != _pointIndex.value) {
        _pointIndex.value = clamped;
        _mapController.move(
          LatLng(points[clamped].lat, points[clamped].lng),
          _mapController.camera.zoom,
        );
      }
    }
  }

  void _seekTo(Duration elapsed) {
    final wasPlaying = _playing;
    if (wasPlaying) _pause();
    _syncTo(elapsed);
    if (wasPlaying) _play();
  }

  void _cycleSpeed() {
    final next = _speeds[(_speeds.indexOf(_speed) + 1) % _speeds.length];
    setState(() => _speed = next);
    if (_playing) {
      // Re-base the clock so the new multiplier applies from here on.
      _clockBase = _elapsed;
      _clock
        ..reset()
        ..start();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _frameIndex.dispose();
    _pointIndex.dispose();
    _elapsedNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final points = _points;
    return Scaffold(
      appBar: AppBar(
        title: const Text('路線回放'),
        actions: [
          if (_total > Duration.zero)
            TextButton(
              onPressed: _cycleSpeed,
              child: Text('${_speed}x', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: points == null
          ? const Center(child: CircularProgressIndicator())
          : points.isEmpty
              ? const Center(child: Text('這筆紀錄尚無資料點'))
              : Column(
                  children: [
                    Expanded(flex: 4, child: _buildCameraPanel()),
                    Expanded(flex: 6, child: _buildMap(points)),
                    _buildReadout(points),
                    _buildControls(),
                    const SizedBox(height: 8),
                  ],
                ),
    );
  }

  Widget _buildCameraPanel() {
    if (_frameFiles.isEmpty) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text('此段記錄沒有影像', style: TextStyle(color: Colors.white70)),
        ),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: ValueListenableBuilder<int>(
        valueListenable: _frameIndex,
        builder: (context, index, _) {
          if (index < 0) {
            return const Center(
              child: Text('尚未開始', style: TextStyle(color: Colors.white70)),
            );
          }
          return Image.file(
            _frameFiles[index],
            gaplessPlayback: true, // avoid flicker between frames
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => const Center(
              child: Text('影像讀取失敗', style: TextStyle(color: Colors.white70)),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMap(List<RoutePoint> points) {
    return ValueListenableBuilder<int>(
      valueListenable: _pointIndex,
      builder: (context, index, _) => FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: LatLng(points.first.lat, points.first.lng),
          initialZoom: 15,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.bike_assist',
          ),
          PolylineLayer(
            polylines: [
              Polyline(
                points: points.map((p) => LatLng(p.lat, p.lng)).toList(),
                color: Colors.grey,
                strokeWidth: 3,
              ),
              Polyline(
                points: points
                    .take(index + 1)
                    .map((p) => LatLng(p.lat, p.lng))
                    .toList(),
                color: Theme.of(context).colorScheme.primary,
                strokeWidth: 4,
              ),
            ],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(points[index].lat, points[index].lng),
                width: 32,
                height: 32,
                child: Icon(
                  Icons.pedal_bike,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReadout(List<RoutePoint> points) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ValueListenableBuilder<Duration>(
        valueListenable: _elapsedNotifier,
        builder: (context, elapsed, _) => ValueListenableBuilder<int>(
          valueListenable: _pointIndex,
          builder: (context, index, _) => Row(
            children: [
              Text(_formatClock(elapsed)),
              const Text(' / '),
              Text(_formatClock(_total)),
              const SizedBox(width: 16),
              Text('${points[index].speedKmh.toStringAsFixed(1)} km/h'),
              const Spacer(),
              if (_frameFiles.isNotEmpty)
                Text('${_frameFiles.length} 影格',
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    final maxMs = _total.inMilliseconds.toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: _total > Duration.zero ? _togglePlayback : null,
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          Expanded(
            child: ValueListenableBuilder<Duration>(
              valueListenable: _elapsedNotifier,
              builder: (context, elapsed, _) => Slider(
                value: elapsed.inMilliseconds.clamp(0, maxMs.toInt()).toDouble(),
                min: 0,
                max: maxMs <= 0 ? 1 : maxMs,
                onChanged: maxMs <= 0
                    ? null
                    : (value) => _seekTo(Duration(milliseconds: value.round())),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatClock(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = d.inHours;
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}
