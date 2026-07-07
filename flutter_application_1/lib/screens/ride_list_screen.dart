import 'package:flutter/material.dart';

import '../models/ride.dart';
import '../services/ride_recorder.dart';
import '../services/ride_repository.dart';
import 'ride_playback_screen.dart';

/// Lists every recorded ride and lets the user start/stop the current
/// recording. Leaving this screen while recording is stopped prompts the
/// user to confirm whether they meant to start a new one.
class RideListScreen extends StatefulWidget {
  const RideListScreen({
    super.key,
    required this.repository,
    required this.recorder,
  });

  final RideRepository repository;
  final RideRecorder recorder;

  @override
  State<RideListScreen> createState() => _RideListScreenState();
}

class _RideListScreenState extends State<RideListScreen> {
  late Future<List<Ride>> _ridesFuture;

  @override
  void initState() {
    super.initState();
    _ridesFuture = widget.repository.listRides();
  }

  void _refresh() {
    setState(() {
      _ridesFuture = widget.repository.listRides();
    });
  }

  Future<void> _toggleRecording() async {
    if (widget.recorder.isRecording.value) {
      await widget.recorder.stop();
    } else {
      await widget.recorder.start();
    }
    _refresh();
  }

  Future<bool> _confirmLeaveWithoutRestarting() async {
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('尚未開始新的記錄'),
        content: const Text('目前記錄已停止,要重新開始記錄嗎?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('先不要'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重新開始'),
          ),
        ],
      ),
    );
    return choice ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: widget.recorder.isRecording.value,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldRestart = await _confirmLeaveWithoutRestarting();
        if (shouldRestart) {
          await widget.recorder.start();
          _refresh();
        }
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('歷史記錄')),
        body: Column(
          children: [
            _RecordingStatusCard(
              recorder: widget.recorder,
              onToggle: _toggleRecording,
            ),
            Expanded(
              child: FutureBuilder<List<Ride>>(
                future: _ridesFuture,
                builder: (context, snapshot) {
                  final rides = snapshot.data;
                  if (rides == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (rides.isEmpty) {
                    return const Center(child: Text('還沒有任何記錄'));
                  }
                  return ListView.builder(
                    itemCount: rides.length,
                    itemBuilder: (context, index) {
                      final ride = rides[index];
                      return ListTile(
                        leading: Icon(
                          ride.isActive ? Icons.fiber_manual_record : Icons.route,
                          color: ride.isActive ? Colors.red : null,
                        ),
                        title: Text(_formatDateTime(ride.startTime)),
                        subtitle: Text(
                          ride.isActive ? '記錄中' : _formatDuration(ride.duration),
                        ),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => RidePlaybackScreen(
                                rideId: ride.id,
                                repository: widget.repository,
                              ),
                            ),
                          );
                          _refresh();
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime time) =>
      '${time.year}/${time.month.toString().padLeft(2, '0')}/${time.day.toString().padLeft(2, '0')} '
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60);
    final hours = duration.inHours;
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours 小時 $minutes 分';
    }
    if (minutes > 0) {
      return '$minutes 分 $seconds 秒';
    }
    return '$seconds 秒';
  }
}

class _RecordingStatusCard extends StatelessWidget {
  const _RecordingStatusCard({
    required this.recorder,
    required this.onToggle,
  });

  final RideRecorder recorder;
  final Future<void> Function() onToggle;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: recorder.isRecording,
      builder: (context, isRecording, _) {
        return Card(
          margin: const EdgeInsets.all(16),
          child: ListTile(
            leading: Icon(
              isRecording ? Icons.fiber_manual_record : Icons.stop_circle_outlined,
              color: isRecording ? Colors.red : null,
            ),
            title: Text(isRecording ? '記錄中' : '已停止'),
            trailing: FilledButton(
              onPressed: onToggle,
              child: Text(isRecording ? '結束記錄' : '開始記錄'),
            ),
          ),
        );
      },
    );
  }
}
