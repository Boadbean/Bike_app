// ──────────────────────────────────────────────────────────────────
//  main.cpp — 正式韌體(二代機 GOOUUU ESP32-S3-CAM)
//
//  2026-07-09:整合 apptest 功能,供一路實測 ────────────────────
//    + WiFi 供網(NVS 存帳密;SoftAP 供網熱點,手動不用重連)
//    + 鏡頭 MJPEG 串流(/stream)
//    + SD 卡掛載(板載 SDMMC)
//    + HTTP 狀態(供給測試 API:/api/status、/api/led)
//
//  ★2026-07-09 修正:/stream 改用「第二台 HTTP 伺服器(port 81)」
//    esp_http_server 單執行緒,/stream 是無窮迴圈會霸占整台伺服器,
//    導致同一台上的 /api/status 被餓死。把串流放獨立埠/獨立執行緒後,
//    鏡頭與數據 API 就能同時運作。
//
//  流程:
//    開機 → NVS 有帳密且連得上 → STA 模式(mDNS bike-assist.local)
//         → 否則開設定熱點 bike-assist-setup(密碼 bikeassist),
//           APP POST http://192.168.4.1/provision {"ssid":"..","password":".."}
//           (儲存後重開機以 STA 模式連線)
//
//  APP 介面:
//    控制/數據(port 80,連網後用 ESP32 的 IP 或 bike-assist.local):
//      GET  /api/status                          全部感測器/系統狀態 JSON
//      GET  /api/led?mode=left|right|hazard|off  手動測試方向燈(off 恢復自動)
//      POST /provision                           供網(僅未連上 STA 時開放)
//    鏡頭(port 81):
//      GET  /stream                              MJPEG 鏡頭串流
// ──────────────────────────────────────────────────────────────────
#include <Arduino.h>
#include <WiFi.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include <SD_MMC.h>
#include "esp_camera.h"
#include "esp_http_server.h"
#include "IMU.h"
#include "AccelAnalyzer.h"
#include "GPS.h"
#include "Network.h"
#include "IndicatorModule.h"

// ── 伺服器連線(STA 連上後,感測資料仍每 1s POST 到 App/FastAPI)──
#define SERVER_URL  "http://192.168.137.1:5000/api/data"  // 備用,實際 POST 已改用 gateway IP 動態組 URL(見 Network.cpp)

#define IMU_SEND_INTERVAL 1000   // IMU + 陀螺:每 1 秒送出
#define GPS_SEND_INTERVAL 5000   // GPS 座標:每 5 秒更新

// ── GPIO(二代機 GOOUUU ESP32-S3-CAM 腳位)────────────────────
// Camera DVP 固定占用 4-18;板載 microSD 占用 38/39/40
#define IMU_SDA_PIN          1   // I2C SDA
#define IMU_SCL_PIN          2   // I2C SCL
#define IMU_INT_PIN         14   // 中斷(原 3=JTAG-EN strapping,改 14)
#define GPS_RX_PIN          21   // UART RX ← GPS TX(原 41 讓給 Audio BCLK)
#define GPS_TX_PIN          -1   // 不接;設定 GPS 用(可選 GPIO47 讓給右方向燈)
#define INDICATOR_LEFT_PIN  46   // 左方向燈 / 警示燈(MOSFET Gate)
#define INDICATOR_RIGHT_PIN 47   // 右方向燈(MOSFET Gate,原 48 為板載 WS2812 衝突,改 47)
#define PIN_SD_CLK          39   // 板載 microSD(SDMMC 1-bit)
#define PIN_SD_CMD          38
#define PIN_SD_D0           40

// ── 供網常數(apptest 整合)──────────────────────────────────
static const char* AP_SSID   = "bike-assist-setup";
static const char* AP_PASS   = "bikeassist";
static const char* MDNS_HOST = "bike-assist";

// ── MJPEG 串流常數 ──────────────────────────────────────────────
static const char* STREAM_CONTENT_TYPE = "multipart/x-mixed-replace;boundary=frame";
static const char* STREAM_BOUNDARY     = "\r\n--frame\r\n";
static const char* STREAM_PART = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

// ── 模組 ───────────────────────────────────────
IMUManager      imu;
AccelAnalyzer   accel;
GPSModule       gps;
NetworkManager  network;
IndicatorModule indicator;
Preferences     prefs;
httpd_handle_t  webServer    = nullptr;   // port 80:控制 + 數據
httpd_handle_t  streamServer = nullptr;   // port 81:鏡頭串流(獨立執行緒)

// ── 系統狀態指標(供 /api/status 讀取)──────────
bool     imuOk = false, sdOk = false, camOk = false, staMode = false;
uint64_t sdSizeMB = 0;

// ── 計時器 ───────────────────────────────────────
unsigned long lastImuPrint  = 0;
unsigned long lastImuSend   = 0;
unsigned long lastGpsSend   = 0;

// ── GPS 快取(5s 才更新一次,1s 一起送出)─────
double cachedLat = 0, cachedLon = 0, cachedAlt = 0, cachedSpeed = 0;

// ── 警示燈狀態 ──────────────────────────────────
// true  = 碰撞觸發(A)→ 需手動解除
// false = 急煞觸發(E)→ 速度恢復後自動解除
bool hazardPermanent = false;

// ── 方向燈手動覆蓋(供 /api/led 路測時使用,off 恢復自動判斷)──
// 真正的碰撞事件(COLLISION)永遠優先介入,會清除手動覆蓋的狀態
enum class ManualLed { NONE, LEFT, RIGHT, HAZARD, OFF };
volatile ManualLed manualLed = ManualLed::NONE;

// ─────────────── NVS:WiFi 帳密 ───────────────
bool loadCreds(String& ssid, String& pass) {
    prefs.begin("wifi", true);
    ssid = prefs.getString("ssid", "");
    pass = prefs.getString("pass", "");
    prefs.end();
    return ssid.length() > 0;
}
void saveCreds(const String& ssid, const String& pass) {
    prefs.begin("wifi", false);
    prefs.putString("ssid", ssid);
    prefs.putString("pass", pass);
    prefs.end();
}

// ─────────────── 相機(QVGA JPEG,供 /stream)───────────────
bool cameraInit() {
    camera_config_t config = {
        .pin_pwdn = -1, .pin_reset = -1, .pin_xclk = 15,
        .pin_sccb_sda = 4, .pin_sccb_scl = 5,
        .pin_d7 = 16, .pin_d6 = 17, .pin_d5 = 18, .pin_d4 = 12,
        .pin_d3 = 10, .pin_d2 = 8,  .pin_d1 = 9,  .pin_d0 = 11,
        .pin_vsync = 6, .pin_href = 7, .pin_pclk = 13,
        .xclk_freq_hz = 20000000,
        .ledc_timer = LEDC_TIMER_0, .ledc_channel = LEDC_CHANNEL_0,
        .pixel_format = PIXFORMAT_JPEG, .frame_size = FRAMESIZE_QVGA,
        .jpeg_quality = 12, .fb_count = 2,
        .fb_location = CAMERA_FB_IN_PSRAM,
        .grab_mode = CAMERA_GRAB_WHEN_EMPTY
    };
    return esp_camera_init(&config) == ESP_OK;
}

// ─────────────── SD(與 camera 共用 SD_MMC,腳位固定)───────────────
void sdInit() {
    SD_MMC.setPins(PIN_SD_CLK, PIN_SD_CMD, PIN_SD_D0);
    if (!SD_MMC.begin("/sdcard", true, false)) {
        Serial.println("[SD] 掛載失敗");
        return;
    }
    sdSizeMB = SD_MMC.cardSize() / (1024 * 1024);
    File f = SD_MMC.open("/apptest.txt", FILE_WRITE);
    sdOk = f && f.print("bike-assist ok");
    if (f) f.close();
    Serial.printf("[SD] %s,容量 %llu MB\n", sdOk ? "OK" : "寫入失敗", sdSizeMB);
}

// ─────────────── HTTP handlers ───────────────
esp_err_t streamHandler(httpd_req_t* req) {
    char part[64];
    if (httpd_resp_set_type(req, STREAM_CONTENT_TYPE) != ESP_OK) return ESP_FAIL;
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    Serial.println("[Stream] 用戶端已連線");
    esp_err_t res = ESP_OK;
    while (true) {
        camera_fb_t* fb = esp_camera_fb_get();
        if (!fb) { res = ESP_FAIL; break; }
        size_t hlen = snprintf(part, sizeof(part), STREAM_PART, fb->len);
        res = httpd_resp_send_chunk(req, STREAM_BOUNDARY, strlen(STREAM_BOUNDARY));
        if (res == ESP_OK) res = httpd_resp_send_chunk(req, part, hlen);
        if (res == ESP_OK) res = httpd_resp_send_chunk(req, (const char*)fb->buf, fb->len);
        esp_camera_fb_return(fb);
        if (res != ESP_OK) break;
    }
    Serial.println("[Stream] 用戶端離線");
    return res;
}

esp_err_t statusHandler(httpd_req_t* req) {
    float ax = imu.getRawAX() / 16384.0f;
    float ay = imu.getRawAY() / 16384.0f;
    float az = imu.getRawAZ() / 16384.0f;

    char body[768];
    snprintf(body, sizeof(body),
        "{\"wifi\":\"%s\",\"ip\":\"%s\","
        "\"imu\":{\"ok\":%s,\"roll\":%.2f,\"pitch\":%.2f,"
        "\"ax\":%.2f,\"ay\":%.2f,\"az\":%.2f},"
        "\"accel\":{\"event\":\"%s\",\"magnitude\":%.2f},"
        "\"gps\":{\"chars\":%lu,\"fix\":%s,\"lat\":%.6f,\"lon\":%.6f,\"speed\":%.1f},"
        "\"led\":{\"direction\":\"%s\",\"manual\":%s},"
        "\"sd\":{\"ok\":%s,\"sizeMB\":%llu},"
        "\"camera\":%s}",
        staMode ? "sta" : "ap",
        staMode ? WiFi.localIP().toString().c_str()
                : WiFi.softAPIP().toString().c_str(),
        imuOk ? "true" : "false", imu.getRoll(), imu.getPitch(), ax, ay, az,
        accel.getEventStr(), accel.getMagnitude(),
        gps.charsProcessed(), gps.isLocationValid() ? "true" : "false",
        gps.getLatitude(), gps.getLongitude(), gps.getSpeed(),
        indicator.getDirectionStr(), manualLed != ManualLed::NONE ? "true" : "false",
        sdOk ? "true" : "false", sdSizeMB,
        camOk ? "true" : "false");

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    return httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
}

esp_err_t ledHandler(httpd_req_t* req) {
    char query[64] = {0}, mode[16] = {0};
    if (httpd_req_get_url_query_str(req, query, sizeof(query)) == ESP_OK)
        httpd_query_key_value(query, "mode", mode, sizeof(mode));

    if      (!strcmp(mode, "left"))   manualLed = ManualLed::LEFT;
    else if (!strcmp(mode, "right"))  manualLed = ManualLed::RIGHT;
    else if (!strcmp(mode, "hazard")) manualLed = ManualLed::HAZARD;
    else if (!strcmp(mode, "off"))    manualLed = ManualLed::OFF;
    else {
        httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                            "mode=left|right|hazard|off");
        return ESP_FAIL;
    }
    Serial.printf("[LED] 手動測試模式 → %s\n", mode);

    char body[48];
    snprintf(body, sizeof(body), "{\"ok\":true,\"led\":\"%s\"}", mode);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    return httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
}

esp_err_t provisionHandler(httpd_req_t* req) {
    int total = req->content_len;
    if (total <= 0 || total > 512) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad length");
        return ESP_FAIL;
    }
    char buf[513];
    int received = 0;
    while (received < total) {
        int r = httpd_req_recv(req, buf + received, total - received);
        if (r <= 0) {
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "recv failed");
            return ESP_FAIL;
        }
        received += r;
    }
    buf[received] = '\0';

    JsonDocument doc;
    if (deserializeJson(doc, buf)) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad json");
        return ESP_FAIL;
    }
    String ssid = doc["ssid"] | "";
    String pass = doc["password"] | "";
    if (ssid.isEmpty()) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "empty ssid");
        return ESP_FAIL;
    }

    Serial.printf("[Provision] 收到帳密 SSID=%s\n", ssid.c_str());
    saveCreds(ssid, pass);

    WiFi.begin(ssid.c_str(), pass.c_str());
    unsigned long t0 = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - t0 < 12000) {
        delay(300); Serial.print(".");
    }
    Serial.println();

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    char resp[128];
    if (WiFi.status() == WL_CONNECTED)
        snprintf(resp, sizeof(resp), "{\"status\":\"connected\",\"ip\":\"%s\"}",
                 WiFi.localIP().toString().c_str());
    else
        snprintf(resp, sizeof(resp), "{\"status\":\"saved\"}");
    httpd_resp_send(req, resp, HTTPD_RESP_USE_STRLEN);

    delay(1000);
    ESP.restart();
    return ESP_OK;
}

// ─────────────── HTTP server ───────────────
// ★兩台伺服器:
//   webServer(port 80)    → /api/status、/api/led、/provision
//   streamServer(port 81) → /stream(獨立 httpd task,不會餓死 /api/status)
void startHttpServer(bool withProvision) {
    // ── 控制/數據伺服器(port 80)────────────────────────────
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port      = 80;
    config.ctrl_port        = 32768;   // 預設值,明確寫出以便與第二台區隔
    config.max_uri_handlers = 6;
    if (httpd_start(&webServer, &config) != ESP_OK) {
        Serial.println("[HTTP] 控制伺服器啟動失敗");
        return;
    }
    httpd_uri_t status = { .uri = "/api/status", .method = HTTP_GET,
                           .handler = statusHandler, .user_ctx = nullptr };
    httpd_uri_t led    = { .uri = "/api/led", .method = HTTP_GET,
                           .handler = ledHandler, .user_ctx = nullptr };
    httpd_register_uri_handler(webServer, &status);
    httpd_register_uri_handler(webServer, &led);
    if (withProvision) {
        httpd_uri_t prov = { .uri = "/provision", .method = HTTP_POST,
                             .handler = provisionHandler, .user_ctx = nullptr };
        httpd_register_uri_handler(webServer, &prov);
    }

    // ── 鏡頭串流伺服器(port 81,獨立 httpd task)──────────────
    // /stream 是無窮迴圈、會霸占整台伺服器,所以放到獨立埠+獨立執行緒,
    // 才不會餓死 port 80 的 /api/status。
    if (camOk) {
        httpd_config_t scfg = HTTPD_DEFAULT_CONFIG();
        scfg.server_port      = 81;
        scfg.ctrl_port        = 32769;   // ★必須和第一台不同,否則第二台會 bind 失敗
        scfg.max_uri_handlers = 1;
        if (httpd_start(&streamServer, &scfg) == ESP_OK) {
            httpd_uri_t stream = { .uri = "/stream", .method = HTTP_GET,
                                   .handler = streamHandler, .user_ctx = nullptr };
            httpd_register_uri_handler(streamServer, &stream);
        } else {
            Serial.println("[HTTP] 串流伺服器(:81)啟動失敗");
        }
    }
}

// ─────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    delay(1500);
    Serial.println("=== 智慧單車輔助系統 啟動中 ===");

    // 開機初始化順序固定:LED → IMU → GPS → 相機 → SD → WiFi
    indicator.begin(INDICATOR_LEFT_PIN, INDICATOR_RIGHT_PIN);

    imuOk = imu.begin(IMU_SDA_PIN, IMU_SCL_PIN, IMU_INT_PIN);
    Serial.printf("[IMU] %s\n", imuOk ? "OK" : "失敗(檢查 I2C 接線/供電)");

    gps.begin(Serial1, 9600, GPS_RX_PIN, GPS_TX_PIN);

    if (!psramFound()) Serial.println("[PSRAM] ⚠ 未偵測到!");
    camOk = cameraInit();
    Serial.printf("[Camera] %s\n", camOk ? "OK" : "初始化失敗");

    sdInit();

    // WiFi:NVS 帳密優先,連上不成沒帳密則開供網熱點
    String ssid, pass;
    if (loadCreds(ssid, pass)) {
        network.begin(ssid.c_str(), pass.c_str(), SERVER_URL);
        staMode = network.isConnected();
    }
    if (!staMode) {
        WiFi.mode(WIFI_AP_STA);
        WiFi.softAP(AP_SSID, AP_PASS);
        Serial.printf("[Setup] 供網熱點 %s(密碼 %s),APP POST http://%s/provision\n",
                      AP_SSID, AP_PASS, WiFi.softAPIP().toString().c_str());
    } else {
        if (MDNS.begin(MDNS_HOST))
            Serial.printf("[mDNS] http://%s.local\n", MDNS_HOST);
        Serial.printf("[WiFi] IP=%s\n", WiFi.localIP().toString().c_str());
    }

    startHttpServer(!staMode);

    Serial.println("── APP 介面 ──────────────────");
    Serial.printf("狀態  GET http://%s/api/status\n",
                  staMode ? WiFi.localIP().toString().c_str() : "192.168.4.1");
    Serial.println("燈    GET /api/led?mode=left|right|hazard|off");
    Serial.printf("串流  GET http://%s:81/stream\n",
                  staMode ? WiFi.localIP().toString().c_str() : "192.168.4.1");
    Serial.println("=== 系統就緒 ===");
}

// ─────────────────────────────────────────────
void loop() {
    unsigned long now = millis();

    // ── IMU ──────────────────────────────────
    imu.update();
    float roll  = imu.getRoll();
    float pitch = imu.getPitch();
    float gx    = imu.getGX();
    float gy    = imu.getGY();
    float gz    = imu.getGZ();

    accel.update(imu.getRawAX(), imu.getRawAY(), imu.getRawAZ());
    AccelEvent accelEvent = accel.getEvent();

    // ── 方向燈 / 警示燈 ───────────────────────
    // 手動測試(/api/led)優先於自動 roll 判斷;off 恢復自動
    if (manualLed == ManualLed::NONE) {
        indicator.update(roll);
    } else if (manualLed == ManualLed::OFF) {
        indicator.off();
        hazardPermanent = false;
        manualLed = ManualLed::NONE;
    } else if (manualLed == ManualLed::LEFT) {
        indicator.activateLeft();
    } else if (manualLed == ManualLed::RIGHT) {
        indicator.activateRight();
    } else if (manualLed == ManualLed::HAZARD) {
        indicator.activateHazard();
    }

    // ── 自動警示燈觸發(A + E)── 真實碰撞事件永遠優先,取代手動測試 ──
    // A:碰撞(Magnitude > 3G)→ 永久警示,需手動解除
    if (accelEvent == AccelEvent::COLLISION && !indicator.isHazard()) {
        indicator.activateHazard();
        hazardPermanent = true;
        manualLed = ManualLed::NONE;
        Serial.println("[警示] ⚠ 碰撞偵測 → 啟動警示燈(需手動解除)");
    }
    // E:急煞(> 2G）+ GPS 速度 < 5 km/h → 暫時警示
    if (accelEvent == AccelEvent::BRAKE &&
        gps.isLocationValid() && gps.getSpeed() < 5.0 &&
        !indicator.isHazard() && manualLed == ManualLed::NONE) {
        indicator.activateHazard();
        hazardPermanent = false;
        Serial.println("[警示] 急煞+低速 → 啟動警示燈(自動解除)");
    }
    // E 自動解除:速度 > 15 km/h 且加速度正常(碰撞觸發則不解除)
    if (indicator.isHazard() && !hazardPermanent && manualLed == ManualLed::NONE &&
        gps.isLocationValid() && gps.getSpeed() > 15.0 &&
        accelEvent == AccelEvent::NORMAL) {
        indicator.off();
        Serial.println("[警示] 速度恢復正常 → 解除警示燈");
    }

    float accelX = accel.getX();
    float accelY = accel.getY();
    float accelZ = accel.getZ();

    // ── GPS:每次 loop 讀 UART,每 5s 更新快取 ──
    gps.update();
    if (now - lastGpsSend >= GPS_SEND_INTERVAL) {
        lastGpsSend = now;

        if (gps.isLocationValid()) {
            cachedLat   = gps.getLatitude();
            cachedLon   = gps.getLongitude();
            cachedAlt   = gps.getAltitude();
            cachedSpeed = gps.getSpeed();
            Serial.printf("[GPS] Lat: %.6f  Lon: %.6f  Alt: %.1f m  Speed: %.1f km/h\n",
                          cachedLat, cachedLon, cachedAlt, cachedSpeed);
        } else {
            Serial.printf("[GPS] 等待定位... (已收字元: %lu, 有效句子: %lu)\n",
                          gps.charsProcessed(), gps.sentencesWithFix());
        }
    }

    // ── Serial:每 500ms 印出 IMU + 陀螺 ──
    if (now - lastImuPrint >= 500) {
        lastImuPrint = now;

        Serial.printf("[IMU]  Pitch: %6.2f°  Roll: %6.2f°\n", pitch, roll);
        Serial.printf("[陀螺] gX: %6.2f°/s  gY: %6.2f°/s  gZ: %6.2f°/s\n", gx, gy, gz);
        Serial.printf("[加速] X: %5.2fG  Y: %5.2fG  Z: %5.2fG  合成: %5.2fG  事件: %s\n",
                      accelX, accelY, accelZ,
                      accel.getMagnitude(), AccelAnalyzer::eventToString(accelEvent));

        accel.resetWindow();
    }

    // ── 網路:每 1s 廣播 IMU + 最新 GPS 快取(WS → 手機;HTTP POST → 伺服器)──
    if (now - lastImuSend >= IMU_SEND_INTERVAL) {
        lastImuSend = now;
        network.update();

        SensorPayload payload = {
            .roll       = roll,
            .pitch      = pitch,
            .gx         = gx,
            .gy         = gy,
            .gz         = gz,
            .accelX     = accelX,
            .accelY     = accelY,
            .accelZ     = accelZ,
            .accelEvent = accel.getEventStr(),
            .latitude   = cachedLat,
            .longitude  = cachedLon,
            .altitude   = cachedAlt,
            .speed      = cachedSpeed
        };

        network.broadcast(payload);
        if (staMode) network.postToServer(payload);
    }

    // ── STA 斷線重連(供網後最有可能是 STA 模式)───────
    if (staMode && WiFi.status() != WL_CONNECTED) {
        static unsigned long lastRe = 0;
        if (now - lastRe > 5000) {
            lastRe = now;
            Serial.println("[WiFi] 斷線,重連中...");
            WiFi.reconnect();
        }
    }

    delay(10);
}
