import 'package:flutter/material.dart';

/// A static, scrollable how-to page. It explains the flows that aren't obvious
/// from the UI alone — connecting, recording with the screen off, and
/// exporting a ride as a video + coordinate CSV via the system share sheet.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('使用說明')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _HelpSection(
            icon: Icons.sensors,
            title: '連接裝置',
            steps: [
              '確認手機和裝置(ESP32)連在同一個 WiFi。',
              '回到主畫面點「連接裝置」,輸入裝置的 IP 位址後按「連線」。',
              '若裝置還沒連上 WiFi,先用對話框裡的「設定裝置連線」把它加入你的 WiFi。',
            ],
            note: '連上後儀表板(速度/GPS)就會顯示。鏡頭串流「預設關閉」,'
                '要看即時影像時,打開鏡頭區左上角的「串流」開關即可。',
          ),
          _HelpSection(
            icon: Icons.fiber_manual_record,
            title: '記錄騎乘',
            steps: [
              '連上裝置就會自動開始記錄這趟騎乘,中斷連線即結束。',
              '記錄期間可以關螢幕、把手機放口袋 — 通知列會顯示「記錄中」,'
                  '資料會持續接收。',
              '也可以到「歷史記錄」頁,用上方的「開始記錄 / 結束記錄」手動控制。',
            ],
          ),
          _HelpSection(
            icon: Icons.route,
            title: '查看與回放',
            steps: [
              '點右上角的地圖圖示進入「歷史記錄」。',
              '點任一筆記錄即可回放:上方是當時的鏡頭畫面,下方是路線地圖,'
                  '會隨播放同步前進。',
              '向左滑一筆記錄可以刪除它(連同影像)。',
            ],
          ),
          _HelpSection(
            icon: Icons.ios_share,
            title: '匯出記錄(影片 + 座標)',
            steps: [
              '在「歷史記錄」頁,每筆記錄右側都有分享圖示,點它。',
              'App 會把當時錄下的鏡頭畫面整理成一個 MP4 影片檔,'
                  '並把整趟的 GPS 座標整理成一個 CSV 檔。',
              '系統分享面板會打開,選 LINE、Gmail、雲端硬碟,'
                  '或「儲存到裝置 / Files」,兩個檔案會一起分享出去。',
            ],
            note: '這趟若沒有錄到鏡頭畫面,就只會匯出座標 CSV。'
                'CSV 每一列是:時間、緯度、經度、時速(km/h)。',
          ),
        ],
      ),
    );
  }
}

class _HelpSection extends StatelessWidget {
  const _HelpSection({
    required this.icon,
    required this.title,
    required this.steps,
    this.note,
  });

  final IconData icon;
  final String title;
  final List<String> steps;

  /// Optional caveat shown below the steps in a subdued style.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StepNumber(i + 1),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        steps[i],
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            if (note != null) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        note!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StepNumber extends StatelessWidget {
  const _StepNumber(this.number);

  final int number;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: Text(
        '$number',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
