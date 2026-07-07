# bike-assist

智慧型自行車輔助系統:ESP32-S3 硬體 + AI 路況偵測 + 手機 App 即時顯示與後端。

## 專案結構

| 資料夾 | 內容 |
|--------|------|
| [`flutter_application_1/`](flutter_application_1/) | Flutter App:即時儀表板(GPS/IMU/速度)、鏡頭 MJPEG 串流、歷史路線地圖回放、騎乘記錄(sqflite)、裝置 WiFi 設定 |
| [`firmware/`](firmware/) | ESP32-S3 韌體:OV2640 MJPEG 串流 + SoftAP WiFi 設定(見 [firmware/README.md](firmware/README.md)) |

## App 快速開始

```bash
cd flutter_application_1
flutter pub get
flutter run            # 或 flutter run -d chrome / -d <裝置>
```

需先安裝 [Flutter SDK](https://docs.flutter.dev/get-started/install);要跑 Android 需 Android SDK 與裝置/模擬器。

> 注意:騎乘記錄用的 sqflite 不支援純網頁,鏡頭/儀表板可在 web 上以模擬資料執行,完整功能請用 Android 裝置/模擬器。

## 韌體快速開始

`firmware/camtest.cpp` 需放進你的 PlatformIO 專案 `src/`,並在 `platformio.ini` 的 `lib_deps` 加入 `bblanchon/ArduinoJson` 與 `espressif/esp32-camera`。詳見 [firmware/README.md](firmware/README.md)。

## 系統架構

```
[ESP32-S3] ──WiFi/HTTP──> [手機 App]
  ├─ OV2640  → MJPEG /stream          即時鏡頭
  ├─ MPU6050 → 加速度 / 傾角           儀表板
  └─ GPS     → 經緯度 / 速度           路線記錄
```
