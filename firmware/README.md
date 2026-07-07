# bike-assist 韌體（ESP32-S3 OV2640）

`camtest.cpp` — MJPEG 串流 + 手機 App 設定 WiFi(SoftAP 供給)。

## 複製到你的 PlatformIO 專案

把 `camtest.cpp` 複製到你的專案 `src/`(取代舊的 camtest.cpp)。

## platformio.ini 需加入依賴

`lib_deps` 加上 ArduinoJson(其餘 Preferences / ESPmDNS 為 framework 內建):

```ini
lib_deps =
    espressif/esp32-camera
    bblanchon/ArduinoJson@^7
```

## 燒錄

```
pio run -e camtest -t upload
pio device monitor
```

## 設定流程

1. 第一次燒錄後(NVS 沒存過帳密),裝置開設定熱點 **bike-assist-setup**(密碼 **bikeassist**)。
2. 手機 WiFi 連上 bike-assist-setup。
3. 開 App → 主畫面右上 📡 →「設定裝置連線」→ 輸入你的網路 SSID/密碼 → 送出。
   - App 會 POST 到 `http://192.168.4.1/provision`。
4. 裝置存到 NVS、嘗試連線後回應,並自動重開機以 STA 連上。
5. 之後每次開機都會自動用存過的帳密連線,直接串流。

## 重設 WiFi

要清掉存的帳密重新設定,可在韌體 `setup()` 開頭暫時加一次
`prefs.begin("wifi", false); prefs.clear(); prefs.end();` 燒錄一次即可。

## 已知限制

- 手機需手動切到 bike-assist-setup 熱點(手機系統限制,App 無法自動切)。
- 設定時建議先關手機行動數據,避免 Android 把請求走行動數據而連不到 192.168.4.1。
- 若目標網路是手機自己的熱點,設定當下熱點沒開,裝置會回「已儲存」並於重開後再連;
  App 拿不到 IP,需切回熱點後在主畫面輸入裝置 IP,或試 `bike-assist.local`。
