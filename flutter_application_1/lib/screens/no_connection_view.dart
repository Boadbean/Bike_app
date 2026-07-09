import 'package:flutter/material.dart';

/// Shown in place of the camera + dashboard while no device is connected.
/// Offers to connect (enter the device IP) or to provision the device's WiFi.
/// When [errorMessage] is set the connection attempt failed and the primary
/// action reads as a retry.
class NoConnectionView extends StatelessWidget {
  const NoConnectionView({
    super.key,
    required this.onConnect,
    required this.onSetup,
    this.errorMessage,
  });

  final VoidCallback onConnect;
  final VoidCallback onSetup;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isError = errorMessage != null;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isError ? Icons.wifi_off : Icons.sensors_off,
              size: 72,
              color: isError
                  ? theme.colorScheme.error
                  : theme.colorScheme.outline,
            ),
            const SizedBox(height: 20),
            Text(
              isError ? '連線失敗' : '尚未連接裝置',
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              isError
                  ? errorMessage!
                  : '連上裝置後即可看到即時鏡頭與儀表板,並自動記錄這趟騎乘。',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: onConnect,
              icon: const Icon(Icons.wifi_tethering),
              label: Text(isError ? '重試連線' : '連接裝置'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onSetup,
              icon: const Icon(Icons.settings_ethernet, size: 18),
              label: const Text('設定裝置 WiFi'),
            ),
            const SizedBox(height: 24),
            Text(
              '請確認手機與裝置連在同一個 WiFi。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
