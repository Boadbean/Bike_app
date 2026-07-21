import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/bike_data.dart';
import '../services/bike_data_source.dart';
import '../services/camera_source.dart';
import '../services/device_provisioning.dart';
import '../services/emergency_relay_service.dart';
import '../services/emergency_settings.dart';
import '../services/ride_frame_store.dart';
import '../services/ride_recorder.dart';
import '../services/ride_repository.dart';
import '../widgets/mjpeg_view.dart';
import '../widgets/speed_gauge.dart';
import '../widgets/stat_card.dart';
import 'device_wifi_setup_screen.dart';
import 'emergency_settings_screen.dart';
import 'no_connection_view.dart';
import 'ride_list_screen.dart';

/// Port the firmware serves the MJPEG `/stream` from — a second HTTP server,
/// separate from the port-80 control/telemetry server, so the blocking stream
/// loop can't starve `/api/status`. Must match the firmware's stream server.
const int _kCameraPort = 81;

/// Single-page layout: camera stream on top, live dashboard below.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.dataSource,
    required this.cameraSource,
    required this.repository,
    required this.frameStore,
    required this.recorder,
    required this.emergencyRelay,
    required this.emergencySettings,
  });

  final BikeDataSource dataSource;
  final CameraSource cameraSource;
  final RideRepository repository;
  final RideFrameStore frameStore;
  final RideRecorder recorder;
  final EmergencyRelayService emergencyRelay;
  final EmergencySettings emergencySettings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _displayController = StreamController<Uint8List>.broadcast();
  final _ipController = TextEditingController();
  StreamSubscription<Uint8List>? _cameraSubscription;

  /// Whether the camera MJPEG stream is turned on. Off by default so connecting
  /// to a device shows the dashboard without pulling the (bandwidth-heavy) video
  /// until the user asks for it. Toggling it connects/disconnects the camera.
  bool _streamingEnabled = false;

  /// Base URI of the currently connected device, kept so the streaming switch
  /// can bring the camera up/down without re-entering the address. Null when no
  /// device is connected.
  Uri? _deviceBase;

  /// Display-only: pausing the live view does not pause ride recording.
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _cameraSubscription = widget.cameraSource.frames.listen((frame) {
      if (!_paused) _displayController.add(frame);
    });
  }

  @override
  void dispose() {
    _cameraSubscription?.cancel();
    _displayController.close();
    _ipController.dispose();
    super.dispose();
  }

  /// Connects to a device. Accepts a bare IP/host, `host:port`, or a full URL.
  ///
  /// Telemetry (`/api/status`, the dashboard) always connects. The camera MJPEG
  /// stream only connects when streaming is switched on — off by default — so a
  /// fresh connection doesn't pull video until asked. The two live on separate
  /// ports on purpose: the firmware serves the MJPEG `/stream` from a second
  /// HTTP server on port [_kCameraPort] so its blocking stream loop can't starve
  /// `/api/status`, which stays on the control port (80 by default, or whatever
  /// the user typed).
  void _connectToDevice(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;
    final normalized = trimmed.startsWith('http') ? trimmed : 'http://$trimmed';
    final base = Uri.parse(normalized).replace(path: '', query: '', fragment: '');
    _deviceBase = base;
    widget.dataSource.connect(base);
    if (_streamingEnabled) {
      widget.cameraSource.connect(_cameraUri(base));
    }
  }

  /// The MJPEG stream endpoint for a device [base].
  Uri _cameraUri(Uri base) =>
      base.replace(port: _kCameraPort, path: '/stream');

  /// Drops both the camera and telemetry connections, returning to the
  /// no-connection view. Recording stops via the connection listener in main.
  void _disconnect() {
    _deviceBase = null;
    widget.cameraSource.disconnect();
    widget.dataSource.disconnect();
  }

  /// Turns the camera stream on/off. When a device is connected, this connects
  /// or tears down the MJPEG stream live; the dashboard is unaffected either way.
  void _setStreamingEnabled(bool enabled) {
    if (enabled == _streamingEnabled) return;
    setState(() => _streamingEnabled = enabled);
    final base = _deviceBase;
    if (base == null) return; // not connected — takes effect on next connect
    if (enabled) {
      widget.cameraSource.connect(_cameraUri(base));
    } else {
      _paused = false; // reset display pause so re-enabling starts live
      widget.cameraSource.disconnect();
    }
  }

  Future<void> _showConnectDialog() async {
    final isConnected =
        widget.dataSource.mode.value != TelemetryMode.disconnected ||
            widget.cameraSource.mode.value != CameraMode.disconnected;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('連接裝置'),
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
            const SizedBox(height: 16),
            const _SetupHotspotInfo(),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.settings_ethernet, size: 18),
              label: const Text('裝置尚未連上 WiFi?設定裝置連線'),
              onPressed: () => Navigator.of(context).pop('setup'),
            ),
          ],
        ),
        actions: [
          if (isConnected)
            TextButton(
              onPressed: () => Navigator.of(context).pop('disconnect'),
              child: const Text('中斷連線'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_ipController.text),
            child: const Text('連線'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (result == 'disconnect') {
      _disconnect();
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
            tooltip: '緊急回報設定',
            icon: const Icon(Icons.emergency_share_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => EmergencySettingsScreen(
                    service: widget.emergencyRelay,
                    settings: widget.emergencySettings,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: '歷史記錄',
            icon: const Icon(Icons.map_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RideListScreen(
                    repository: widget.repository,
                    frameStore: widget.frameStore,
                    recorder: widget.recorder,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge(
          [widget.cameraSource.mode, widget.dataSource.mode],
        ),
        builder: (context, _) {
          final cameraMode = widget.cameraSource.mode.value;
          final telemetryMode = widget.dataSource.mode.value;
          // A device is connected as soon as telemetry (or the camera) is up.
          // The camera can be off (streaming switch) while telemetry is live.
          final live = telemetryMode == TelemetryMode.connecting ||
              telemetryMode == TelemetryMode.connected ||
              cameraMode == CameraMode.connecting ||
              cameraMode == CameraMode.connected;
          if (!live) {
            // Surface whichever side reported the failure that dropped us here.
            final error = telemetryMode == TelemetryMode.error
                ? widget.dataSource.errorMessage.value
                : cameraMode == CameraMode.error
                    ? widget.cameraSource.errorMessage.value
                    : null;
            return NoConnectionView(
              onConnect: _showConnectDialog,
              onSetup: _openDeviceSetup,
              errorMessage: error,
            );
          }
          return _buildLiveLayout(context);
        },
      ),
    );
  }

  Widget _buildLiveLayout(BuildContext context) {
    return Column(
        children: [
          Expanded(
            flex: 4,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_streamingEnabled)
                    MjpegView(frames: _displayController.stream)
                  else
                    const _StreamOffView(),
                  if (_streamingEnabled)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: ValueListenableBuilder<CameraMode>(
                        valueListenable: widget.cameraSource.mode,
                        builder: (context, mode, _) => Chip(
                          avatar: Icon(
                            Icons.circle,
                            size: 12,
                            color: _statusColor(mode),
                          ),
                          label: Text(_statusLabel(mode)),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  if (_streamingEnabled)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: FilledButton.icon(
                        onPressed: _togglePaused,
                        icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                        label: Text(_paused ? '繼續' : '暫停'),
                      ),
                    ),
                  // The streaming switch stays available whether it's on or off.
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _StreamToggle(
                      enabled: _streamingEnabled,
                      onChanged: _setStreamingEnabled,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 6,
            child: StreamBuilder<BikeData>(
              stream: widget.dataSource.stream,
              builder: (context, snapshot) {
                final data = snapshot.data;
                if (data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        _GpsChip(data: data),
                        _ConnectionChip(dataSource: widget.dataSource),
                      ],
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
      );
  }

  Color _statusColor(CameraMode mode) {
    if (_paused) return Colors.orange;
    switch (mode) {
      case CameraMode.connected:
        return Colors.green;
      case CameraMode.connecting:
        return Colors.blue;
      case CameraMode.error:
        return Colors.red;
      case CameraMode.disconnected:
        return Colors.grey;
    }
  }

  String _statusLabel(CameraMode mode) {
    if (_paused) return '已暫停';
    switch (mode) {
      case CameraMode.disconnected:
        return '未連線';
      case CameraMode.connecting:
        return '連線中...';
      case CameraMode.connected:
        return 'ESP32 連線中';
      case CameraMode.error:
        final error = widget.cameraSource.errorMessage.value;
        return error == null ? '連線失敗' : '連線失敗:$error';
    }
  }

  String _formatTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
}

/// The camera-stream on/off switch, overlaid on the video area. A compact pill
/// so it reads on the black camera background whether the stream is on or off.
class _StreamToggle extends StatelessWidget {
  const _StreamToggle({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          const Text('串流', style: TextStyle(color: Colors.white)),
          Switch(
            value: enabled,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}

/// Placeholder shown in the camera area while the stream is switched off, so the
/// black panel doesn't look like a failed connection.
class _StreamOffView extends StatelessWidget {
  const _StreamOffView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_off, size: 48, color: Colors.white54),
          SizedBox(height: 12),
          Text(
            '鏡頭串流已關閉',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          SizedBox(height: 4),
          Text(
            '開啟上方「串流」開關以檢視即時影像',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// Shows the firmware's setup hotspot name and password inside the connect
/// dialog, so the user knows which WiFi to join to provision the device.
/// Each value can be tapped to copy it to the clipboard.
class _SetupHotspotInfo extends StatelessWidget {
  const _SetupHotspotInfo();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_tethering, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text('裝置設定熱點', style: theme.textTheme.labelLarge),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _CopyableField(label: '熱點名稱', value: kSetupApSsid),
          const SizedBox(height: 4),
          _CopyableField(label: '密碼', value: kSetupApPassword),
        ],
      ),
    );
  }
}

/// A label + monospace value row that copies the value to the clipboard on tap.
class _CopyableField extends StatelessWidget {
  const _CopyableField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已複製$label:$value'), duration: const Duration(seconds: 1)),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 64, child: Text(label, style: theme.textTheme.bodySmall)),
            Expanded(
              child: SelectableText(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.copy, size: 14, color: theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }
}

/// Shows the device's GPS state from the latest telemetry, to make it obvious
/// whether a fix has been acquired (rides need a fix to plot a route):
/// green = locked, orange = receiving NMEA but searching, red = no data.
class _GpsChip extends StatelessWidget {
  const _GpsChip({required this.data});

  final BikeData data;

  @override
  Widget build(BuildContext context) {
    final fix = data.gpsFix;
    final chars = data.gpsChars;

    final Color color;
    final String label;
    final IconData icon;
    if (fix == true) {
      color = Colors.green;
      label = 'GPS 已定位';
      icon = Icons.gps_fixed;
    } else if (chars != null && chars > 0) {
      color = Colors.orange;
      label = 'GPS 搜尋中';
      icon = Icons.gps_not_fixed;
    } else {
      color = Colors.red;
      label = 'GPS 無訊號';
      icon = Icons.gps_off;
    }

    return Chip(
      avatar: Icon(icon, size: 14, color: color),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Reflects the telemetry (dashboard data) connection: mock vs. a real device
/// polling `/api/status`. Separate from the camera status chip on the video.
class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.dataSource});

  final BikeDataSource dataSource;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TelemetryMode>(
      valueListenable: dataSource.mode,
      builder: (context, mode, _) {
        final (color, label) = switch (mode) {
          TelemetryMode.disconnected => (Colors.grey, '未連線'),
          TelemetryMode.connecting => (Colors.blue, '數據連線中...'),
          TelemetryMode.connected => (Colors.green, '裝置數據連線中'),
          TelemetryMode.error => (Colors.red, '數據連線失敗'),
        };
        return Chip(
          avatar: Icon(Icons.circle, size: 12, color: color),
          label: Text(label),
          visualDensity: VisualDensity.compact,
        );
      },
    );
  }
}
