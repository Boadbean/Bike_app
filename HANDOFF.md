# bike-assist 交接文件（Handoff）

給下一位開發者：這份文件說明本輪新增/修改的功能、環境設定、建置方式，以及**尚未在實體硬體驗證**的部分。

> 專案結構見 [README.md](README.md)。App 在 [`flutter_application_1/`](flutter_application_1/)，韌體在 [`firmware/`](firmware/)。

---

## 一、本輪做了什麼（4 項變更）

### 1. 移除陀螺儀 / IMU 顯示
- 儀表板拿掉「傾角」卡片；`BikeData` 移除 `gx/gy/gz`、`ax/ay/az`、`roll/pitch`、`leanAngleDeg`。
- 保留 GPS、速度、`accelEvent/accelMagnitude`、`led*`、`gpsFix/gpsChars`。
- 影響檔：`lib/models/bike_data.dart`、`lib/screens/home_screen.dart`。

### 2. 匯出改成「影片(MP4) + 座標(CSV)」，移除舊的 .zip 匯入/匯出
- 錄下的鏡頭影格 → 用 **Android 原生 H.264 編碼**（`MediaCodec` + `MediaMuxer`）組成 `.mp4`，並輸出一個座標 `.csv`，兩個檔一起用系統分享面板送出。
- CSV 欄位：`timestamp,latitude,longitude,speed_kmh`。
- 影片 PTS 用實際錄影時間戳，播放速度貼近真實騎乘。
- 舊的 `.zip` 匯入/匯出與「開啟/分享 .zip」的 intent 流程**已整個移除**。
- 新增：`lib/services/video_encoder.dart`（Dart 端 MethodChannel 介面）、`lib/services/ride_export_service.dart`、`android/.../VideoEncoder.kt`（原生編碼器）。
- 移除：`lib/services/ride_archive_service.dart`、`lib/services/import_intent_channel.dart`。
- `MainActivity.kt` 改為註冊 `bike_assist/video_encoder` channel；`AndroidManifest.xml` 移除 zip 的 intent-filter。
- pubspec 移除 `archive`、`file_selector`。

### 3. 鏡頭串流開關（預設關閉）
- 連上裝置時**儀表板照常**（由遙測 `/api/status` 驅動畫面），但**鏡頭 MJPEG 串流預設不抓取**，鏡頭區顯示「鏡頭串流已關閉」佔位。
- 鏡頭區左上「串流」開關可即時連上/中斷 MJPEG，串流關閉時可省頻寬/電量。
- 影響檔：`lib/screens/home_screen.dart`。

### 4. 藍牙緊急座標回報（BLE）
- 韌體端**已有**：摔車滿 5 分鐘未扶正 → `broadcastFallenBLE()` 發出 BLE **廣播**（manufacturer data，company id `0xFFFF`），payload 13 bytes：`[evt(1)=0x01 | lat(float32 LE) | lon(float32 LE) | epoch(uint32 LE)]`，裝置名 `bike-assist-fall`。（見 `firmware/main.cpp`）
- 本輪新增 **App 這一側**：背景常駐掃描該廣播 → 解析座標 → `POST` JSON 到使用者設定的伺服器 URL。connectionless（只掃描、不配對連線）。
- 送出的 JSON：`{"event":"fallen","lat":..,"lon":..,"epoch":..,"time":<ISO8601 UTC>}`。
- 去重：同一 `epoch` 只回報一次（韌體會連續廣播約 2 分鐘）。
- 設定畫面（主畫面右上「緊急」圖示進入）：開關 + 伺服器 URL + 即時狀態；用 `shared_preferences` 儲存，重啟自動恢復。
- 背景常駐：沿用錄影的前景服務，透過 `KeepAliveController`（引用計數）讓「錄影」與「緊急掃描」共用同一個前景服務、互不干擾。
- 新增：`lib/services/emergency_relay_service.dart`、`emergency_settings.dart`、`keep_alive_controller.dart`、`lib/screens/emergency_settings_screen.dart`。
- 權限（`AndroidManifest.xml`）：`BLUETOOTH_SCAN`(neverForLocation)、`BLUETOOTH_CONNECT`，以及 API≤30 的 `BLUETOOTH`/`BLUETOOTH_ADMIN`/`ACCESS_FINE_LOCATION`。
- 相依套件（pubspec 新增）：`flutter_blue_plus`、`shared_preferences`、`permission_handler`。

---

## 二、環境設定

| 項目 | 內容 |
|------|------|
| Flutter SDK | 本機安裝於 `C:\src\flutter`（stable，**3.44.6 / Dart 3.12.2**），已加入使用者 PATH |
| App 需求 | `pubspec.yaml` 要求 `sdk: ^3.12.2` |
| 平台定位 | **完整功能限 Android**（影片編碼、BLE、sqflite 皆為 Android 原生）。Web 只能跑部分且 sqflite 不支援。 |
| Android 模擬器 | 有現成 AVD `Medium_Phone_API_35`。**必須用軟體 GPU 啟動**（見下方雷區） |

---

## 三、建置 / 執行

```bash
cd flutter_application_1
flutter pub get
flutter analyze          # 目前無任何問題
flutter test             # 目前 34 項全過

# 執行（模擬器必須用軟體 GPU，否則畫面全黑、截圖全黑）
&"$env:LOCALAPPDATA\Android\Sdk\emulator\emulator.exe" -avd Medium_Phone_API_35 -gpu swiftshader_indirect -no-snapshot
flutter run -d emulator-5554 --no-enable-impeller

# 建置 APK
flutter build apk --release
# 產物：build/app/outputs/flutter-apk/app-release.apk（約 54 MB，debug 簽章）
```

> **APK 目前用 debug 簽章**（無自訂 keystore）。上架/正式散佈前需設定 release 簽章（`android/app/build.gradle` 的 `signingConfigs` + `key.properties`）。

---

## 四、雷區 / 已知限制（重要）

1. **Android 模擬器畫面全黑 & 截圖全黑**
   - 硬體 GPU（Impeller/OpenGLES）在此模擬器下渲染與 `adb screencap` 都會失效。
   - 解法：模擬器用 `-gpu swiftshader_indirect` 啟動，`flutter run` 加 `--no-enable-impeller`。

2. **模擬器無法做 BLE 掃描**
   - 虛擬藍牙掃描會回 `SCAN_FAILED_APPLICATION_REGISTRATION_FAILED`（android-code 2）。這是模擬器先天限制。
   - App 已驗證到：權限流程、前景服務、掃描呼叫、失敗時 UI 正確顯示「無法掃描」且不卡住。
   - **緊急回報的完整收訊/回報，必須用實體 Android 手機 + 實體 ESP32 測試。**

3. **影片編碼需實體錄影資料**
   - 需連上 ESP32 鏡頭並打開「串流」開關才會錄到影格；沒有影格時匯出只會有 CSV。
   - 原生編碼器已用 integration test 在模擬器上驗證能產生有效 MP4（見 `integration_test/video_encoder_test.dart`）。

4. **本機測連線用 `10.0.2.2`**
   - 模擬器連本機伺服器要用 `10.0.2.2`（對應 host loopback）。例如以本機 `/api/status` 假伺服器餵儀表板時輸入 `10.0.2.2:8080`。

---

## 五、測試現況

- `flutter analyze`：乾淨（無 issue）。
- `flutter test`：**34 項全過**，含：
  - `BikeData.fromStatusJson`（GPS/速度/額外欄位解析）
  - `RideExportService`（CSV 內容、有/無影片分支、找不到記錄丟例外）— 影片編碼用假的 `VideoEncoder` 注入
  - `FallAlert.tryParse`（用韌體的位元組佈局驗證 BLE payload 解析）
  - 既有的 Repository / FrameStore / Recorder / KeepAlive 測試
- 模擬器實跑已驗：App 啟動、串流開關預設關閉、匯入按鈕已移除、緊急設定畫面與啟用流程（藍牙/通知權限、前景服務、掃描呼叫）。

---

## 六、下一步（給接手的人）

1. **實體裝置整合測試**（最關鍵）：真手機 + 真 ESP32，驗證
   - 鏡頭串流打開 → 錄影 → 匯出 MP4 能正常播放、CSV 座標正確。
   - 摔車情境 → ESP32 BLE 廣播 → App 掃到 → 成功 POST 到伺服器。
2. **伺服器端**：目前 App 只負責 POST `{"event":"fallen",...}` 到使用者填的 URL。伺服器要有對應端點（例如 `POST /api/fall`）接收；韌體另有 `/api/data`、`/api/frame`（見 `firmware/`）。
3. **Release 簽章**：正式散佈前設定 keystore。
4. （可選）背景 BLE 掃描較耗電，之後可評估「只在騎乘時掃描」或加排程，降低長時間常駐成本。
