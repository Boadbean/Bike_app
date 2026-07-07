import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/route_point.dart';
import '../services/ride_repository.dart';

/// Replays one recorded ride on a map: full route drawn faintly,
/// progress-so-far highlighted, and a marker that advances along the path.
class RidePlaybackScreen extends StatefulWidget {
  const RidePlaybackScreen({
    super.key,
    required this.rideId,
    required this.repository,
  });

  final int rideId;
  final RideRepository repository;

  @override
  State<RidePlaybackScreen> createState() => _RidePlaybackScreenState();
}

class _RidePlaybackScreenState extends State<RidePlaybackScreen> {
  final MapController _mapController = MapController();

  List<RoutePoint>? _points;
  int _currentIndex = 0;
  bool _playing = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.repository.loadPoints(widget.rideId).then((points) {
      if (!mounted) return;
      setState(() => _points = points);
      if (points.isEmpty) return;
      final bounds = LatLngBounds.fromPoints(
        points.map((p) => LatLng(p.lat, p.lng)).toList(),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapController.fitCamera(
          CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(32)),
        );
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _togglePlayback() {
    if (_playing) {
      _timer?.cancel();
      setState(() => _playing = false);
      return;
    }

    final points = _points;
    if (points == null || points.isEmpty) return;
    if (_currentIndex >= points.length - 1) {
      _currentIndex = 0;
    }

    setState(() => _playing = true);
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final points = _points!;
      if (_currentIndex >= points.length - 1) {
        _timer?.cancel();
        setState(() => _playing = false);
        return;
      }
      setState(() => _currentIndex++);
      _mapController.move(
        LatLng(points[_currentIndex].lat, points[_currentIndex].lng),
        _mapController.camera.zoom,
      );
    });
  }

  void _seekTo(int index) {
    _timer?.cancel();
    final points = _points!;
    setState(() {
      _playing = false;
      _currentIndex = index.clamp(0, points.length - 1);
    });
    _mapController.move(
      LatLng(points[_currentIndex].lat, points[_currentIndex].lng),
      _mapController.camera.zoom,
    );
  }

  @override
  Widget build(BuildContext context) {
    final points = _points;
    return Scaffold(
      appBar: AppBar(title: const Text('路線回放')),
      body: points == null
          ? const Center(child: CircularProgressIndicator())
          : points.isEmpty
              ? const Center(child: Text('這筆紀錄尚無資料點'))
              : Column(
                  children: [
                    Expanded(
                      child: FlutterMap(
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
                                    .take(_currentIndex + 1)
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
                                point: LatLng(
                                  points[_currentIndex].lat,
                                  points[_currentIndex].lng,
                                ),
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
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Text(_formatTime(points[_currentIndex].timestamp)),
                          const SizedBox(width: 12),
                          Text('${points[_currentIndex].speedKmh.toStringAsFixed(1)} km/h'),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: _togglePlayback,
                            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                          ),
                          Expanded(
                            child: Slider(
                              value: _currentIndex.toDouble(),
                              min: 0,
                              max: (points.length - 1).toDouble(),
                              onChanged: (value) => _seekTo(value.round()),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
    );
  }

  String _formatTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
}
