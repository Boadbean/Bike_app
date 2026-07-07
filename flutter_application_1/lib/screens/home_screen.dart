import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/bike_data.dart';
import '../services/bike_data_service.dart';
import '../services/camera_stream_service.dart';
import '../services/http_mjpeg_camera_stream_service.dart';
import '../services/ride_recorder.dart';
import '../services/ride_repository.dart';
import '../widgets/mjpeg_view.dart';
import '../widgets/speed_gauge.dart';
import '../widgets/stat_card.dart';
import 'device_wifi_setup_screen.dart';
import 'ride_list_screen.dart';

enum _CameraMode { mock, connecting, connected, error }

/// Single-page layout: camera stream on top, live dashboard below.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.dataService,
    required this.repository,
    required this.recorder,
  });

  final BikeDataService dataService;
  final RideRepository repository;
  final RideRecorder recorder;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late CameraStreamService _cameraService;
  StreamSubscription<Uint8List>? _cameraSubscription;
  final _displayController = StreamController<Uint8List>.broadcast();
  final _ipController = TextEditingController();

  _CameraMode _mode = _CameraMode.mock;
  String? _errorMessage;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _cameraService = MockCameraStreamService();
    _bindCamera(isMock: true);
  }

  @override
  void dispose() {
    _cameraSubscription?.cancel();
    _displayController.close();
    _cameraService.dispose();
    _ipController.dispose();
    super.dispose();
  }

  void _bindCamera({required bool isMock}) {
    _cameraSubscription?.cancel();
    _cameraSubscription = _cameraService.frames.listen(
      (frame) {
        if (!_paused) {
          _displayController.add(frame);
        }
        if (!isMock && _mode != _CameraMode.connected) {
          setState(() => _mode = _CameraMode.connected);
        }
      },
      onError: (Object error) {
        setState(() {
          _mode = _CameraMode.error;
          _errorMessage = error.toString();
        });
      },
      onDone: () {
        if (!isMock) {
          setState(() {
            _mode = _CameraMode.error;
            _errorMessage = '連線已中斷';
          });
        }
      },
    );
  }

  void _useMockCamera() {
    _cameraSubscription?.cancel();
    _cameraService.dispose();
    setState(() {
      _cameraService = MockCameraStreamService();
      _mode = _CameraMode.mock;
      _errorMessage = null;
    });
    _bindCamera(isMock: true);
  }

  void _connectToDevice(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;
    final uri = trimmed.startsWith('http')
        ? Uri.parse(trimmed)
        : Uri.parse('http://$trimmed/stream');

    _cameraSubscription?.cancel();
    _cameraService.dispose();
    setState(() {
      _cameraService = HttpMjpegCameraStreamService(uri);
      _mode = _CameraMode.connecting;
      _errorMessage = null;
    });
    _bindCamera(isMock: false);
  }

  Future<void> _showConnectDialog() async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('連接鏡頭裝置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: 'ESP32 IP 位址',
                hintText: '例如 192.168.1.42',
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.settings_ethernet, size: 18),
              label: const Text('裝置尚未連上 WiFi?設定裝置連線'),
              onPressed: () => Navigator.of(context).pop('setup'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('mock'),
            child: const Text('使用模擬串流'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_ipController.text),
            child: const Text('連線'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (result == 'mock') {
      _useMockCamera();
    } else if (result == 'setup') {
      await _openDeviceSetup();
    } else {
      _connectToDevice(result);
    }
  }

  Future<void> _openDeviceSetup() async {
    final ip = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const DeviceWifiSetupScreen()),
    );
    if (ip != null && ip.isNotEmpty) {
      _ipController.text = ip;
      _connectToDevice(ip);
    }
  }

  void _togglePaused() {
    setState(() => _paused = !_paused);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('bike-assist'),
        actions: [
          IconButton(
            tooltip: '連接鏡頭裝置',
            icon: const Icon(Icons.wifi_tethering),
            onPressed: _showConnectDialog,
          ),
          IconButton(
            tooltip: '歷史記錄',
            icon: const Icon(Icons.map_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RideListScreen(
                    repository: widget.repository,
                    recorder: widget.recorder,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 4,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MjpegView(frames: _displayController.stream),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Chip(
                      avatar: Icon(
                        Icons.circle,
                        size: 12,
                        color: _statusColor,
                      ),
                      label: Text(_statusLabel),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  Positioned(
                    bottom: 8,
                    right: 8,
                    child: FilledButton.icon(
                      onPressed: _togglePaused,
                      icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                      label: Text(_paused ? '繼續' : '暫停'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: StreamBuilder<BikeData>(
              stream: widget.dataService.stream,
              builder: (context, snapshot) {
                final data = snapshot.data;
                if (data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: const [_ConnectionChip()],
                    ),
                    const SizedBox(height: 8),
                    Center(child: SpeedGauge(speedKmh: data.speedKmh)),
                    const SizedBox(height: 24),
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 2.2,
                      children: [
                        StatCard(
                          label: '傾角',
                          value: '${data.leanAngleDeg.toStringAsFixed(1)}°',
                          icon: Icons.rotate_right,
                        ),
                        StatCard(
                          label: '最後更新',
                          value: _formatTime(data.timestamp),
                          icon: Icons.schedule,
                        ),
                        StatCard(
                          label: '緯度',
                          value: data.lat.toStringAsFixed(5),
                          icon: Icons.explore,
                        ),
                        StatCard(
                          label: '經度',
                          value: data.lng.toStringAsFixed(5),
                          icon: Icons.explore_outlined,
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Color get _statusColor {
    if (_paused) return Colors.orange;
    switch (_mode) {
      case _CameraMode.mock:
      case _CameraMode.connected:
        return Colors.green;
      case _CameraMode.connecting:
        return Colors.blue;
      case _CameraMode.error:
        return Colors.red;
    }
  }

  String get _statusLabel {
    if (_paused) return '已暫停';
    switch (_mode) {
      case _CameraMode.mock:
        return '串流狀態:模擬中';
      case _CameraMode.connecting:
        return '連線中...';
      case _CameraMode.connected:
        return 'ESP32 連線中';
      case _CameraMode.error:
        return _errorMessage == null ? '連線失敗' : '連線失敗:$_errorMessage';
    }
  }

  String _formatTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip();

  @override
  Widget build(BuildContext context) {
    return const Chip(
      avatar: Icon(Icons.circle, size: 12, color: Colors.green),
      label: Text('模擬資料連線中'),
      visualDensity: VisualDensity.compact,
    );
  }
}
