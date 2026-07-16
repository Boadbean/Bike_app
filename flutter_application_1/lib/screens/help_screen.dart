import 'package:flutter/material.dart';

/// A static, scrollable how-to page. It explains the flows that aren't obvious
/// from the UI alone — connecting, recording with the screen off, and
/// especially exporting/importing rides (which involves a system share sheet
/// and file picker outside the app).
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
            title: '匯出記錄(分享 / 備份)',
            steps: [
              '在「歷史記錄」頁,每筆記錄右側都有分享圖示,點它。',
              '系統分享面板會打開,選 LINE、Gmail、雲端硬碟,'
                  '或「儲存到裝置 / Files」。',
              '匯出的是一個 .zip 檔,裡面包含完整路線和當時錄下的鏡頭畫面。',
            ],
          ),
          _HelpSection(
            icon: Icons.open_in_new,
            title: '匯入記錄(最簡單)',
            steps: [
              '在檔案管理員、LINE 或 Gmail 裡找到那個 .zip 檔。',
              '點它 →「開啟方式 / 分享」→ 選「bike-assist」。',
              'App 會自動匯入並顯示「已匯入記錄」,然後跳到歷史記錄頁。',
            ],
            note: '這個方式是在檔案管理員/聊天 App 裡操作,有正常的返回鍵,'
                '不用進系統選檔器。',
          ),
          _HelpSection(
            icon: Icons.file_download_outlined,
            title: '匯入記錄(從 App 內)',
            steps: [
              '要匯入的 .zip 檔要先存在手機上(別人傳的附件通常在「下載 / '
                  'Download」資料夾)。',
              '在「歷史記錄」頁點右上角的匯入圖示(向下箭頭)。',
              '在系統選檔器裡找到 .zip 並點選 — 找不到就點左上角選單切到'
                  '「Downloads」。要離開選檔器用手機本身的返回(手勢或 ◁ 鍵)。',
              '匯入會建立一筆全新記錄,不會覆蓋你現有的;完成後會顯示「已匯入記錄」。',
            ],
            note: '只能匯入本 App 匯出的 .zip;其他檔案會提示不是記錄檔。',
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
