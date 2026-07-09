import 'package:flutter/material.dart';

import '../services/device_provisioning.dart';

/// Lets the user hand the ESP32 the WiFi credentials it should join, by POSTing
/// them to the device's setup AP. Reached after the phone has joined the
/// `bike-assist-setup` hotspot. On success with an IP, pops that IP back so the
/// caller can stream from it directly.
class DeviceWifiSetupScreen extends StatefulWidget {
  const DeviceWifiSetupScreen({
    super.key,
    this.provision = provisionDevice,
  });

  /// Injectable for testing; defaults to the real HTTP implementation.
  final ProvisionFn provision;

  @override
  State<DeviceWifiSetupScreen> createState() => _DeviceWifiSetupScreenState();
}

class _DeviceWifiSetupScreenState extends State<DeviceWifiSetupScreen> {
  final _ssidController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _submitting = false;
  String? _message;
  bool _isError = false;

  @override
  void dispose() {
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ssid = _ssidController.text.trim();
    if (ssid.isEmpty) {
      setState(() {
        _isError = true;
        _message = '請輸入網路名稱 (SSID)';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _message = null;
    });

    final result = await widget.provision(ssid, _passwordController.text);

    if (!mounted) return;

    if (!result.ok) {
      setState(() {
        _submitting = false;
        _isError = true;
        _message = '傳送失敗:${result.error ?? '未知錯誤'}\n'
            '請確認手機已連上 bike-assist-setup 熱點,並關閉行動數據後再試。';
      });
      return;
    }

    if (result.ip != null) {
      Navigator.of(context).pop(result.ip);
      return;
    }

    // Saved but not yet connected (e.g. target is the phone's own hotspot).
    setState(() {
      _submitting = false;
      _isError = false;
      _message = '帳密已儲存。請把手機 WiFi 切回你的網路,裝置會自動重開連線。\n'
          '之後在主畫面輸入裝置 IP,或試 bike-assist.local 連線。';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定裝置連線')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 18, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text('設定步驟', style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('1. 先到手機 WiFi 設定,連上熱點 $kSetupApSsid(密碼 $kSetupApPassword)'),
                  const SizedBox(height: 4),
                  const Text('2. 回到這裡,輸入你要讓裝置連上的網路帳密並送出'),
                  const SizedBox(height: 4),
                  const Text('3. 建議先關閉手機行動數據,避免連不到裝置'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ssidController,
            enabled: !_submitting,
            decoration: const InputDecoration(
              labelText: '網路名稱 (SSID)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            enabled: !_submitting,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: '網路密碼',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            label: Text(_submitting ? '傳送中...' : '送出設定'),
          ),
          if (_message != null) ...[
            const SizedBox(height: 16),
            Card(
              color: _isError
                  ? Theme.of(context).colorScheme.errorContainer
                  : Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_message!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
