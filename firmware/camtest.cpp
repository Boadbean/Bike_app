// ──────────────────────────────────────────────────────────────
//  camtest.cpp — OV2640 MJPEG 串流 + WiFi 設定 (SoftAP 供給)
//  燒錄：pio run -e camtest -t upload
//
//  流程：
//    開機 → 從 NVS 讀存過的 WiFi 帳密
//      有且連得上 → 相機 + /stream (port 80) + mDNS bike-assist.local
//      沒有 / 連不上 → 開設定熱點 bike-assist-setup，等 App 送帳密
//
//  設定：手機連上熱點 bike-assist-setup (密碼 bikeassist)，
//        App 送 POST http://192.168.4.1/provision
//        body: {"ssid":"...","password":"..."}
//
//  依賴：platformio.ini 的 lib_deps 需加入 bblanchon/ArduinoJson
// ──────────────────────────────────────────────────────────────
#include <Arduino.h>
#include "esp_camera.h"
#include <WiFi.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include "esp_http_server.h"

// ── 設定熱點常數 ──
static const char* AP_SSID = "bike-assist-setup";
static const char* AP_PASS = "bikeassist";   // ≥8 碼 → WPA2
static const char* MDNS_HOST = "bike-assist"; // → bike-assist.local

// ── MJPEG 串流常數 ──
static const char* STREAM_CONTENT_TYPE =
    "multipart/x-mixed-replace;boundary=frame";
static const char* STREAM_BOUNDARY = "\r\n--frame\r\n";
static const char* STREAM_PART =
    "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

httpd_handle_t webServer = nullptr;
Preferences prefs;

// ═══════════════════ NVS 帳密存取 ═══════════════════
bool loadCreds(String& ssid, String& pass) {
    prefs.begin("wifi", true);          // read-only
    ssid = prefs.getString("ssid", "");
    pass = prefs.getString("pass", "");
    prefs.end();
    return ssid.length() > 0;
}

void saveCreds(const String& ssid, const String& pass) {
    prefs.begin("wifi", false);         // read-write
    prefs.putString("ssid", ssid);
    prefs.putString("pass", pass);
    prefs.end();
}

// ═══════════════════ 相機 ═══════════════════
bool cameraInit() {
    camera_config_t config = {
        .pin_pwdn     = -1,
        .pin_reset    = -1,
        .pin_xclk     = 15,
        .pin_sccb_sda = 4,
        .pin_sccb_scl = 5,
        .pin_d7 = 16, .pin_d6 = 17,
        .pin_d5 = 18, .pin_d4 = 12,
        .pin_d3 = 10, .pin_d2 = 8,
        .pin_d1 = 9,  .pin_d0 = 11,
        .pin_vsync = 6,
        .pin_href  = 7,
        .pin_pclk  = 13,
        .xclk_freq_hz = 20000000,
        .ledc_timer   = LEDC_TIMER_0,
        .ledc_channel = LEDC_CHANNEL_0,
        .pixel_format = PIXFORMAT_JPEG,
        .frame_size   = FRAMESIZE_QVGA,   // 320x240 先求穩，穩了可改 VGA
        .jpeg_quality = 12,
        .fb_count     = 2,
        .fb_location  = CAMERA_FB_IN_PSRAM,
        .grab_mode    = CAMERA_GRAB_WHEN_EMPTY
    };
    return esp_camera_init(&config) == ESP_OK;
}

// ═══════════════════ /stream handler ═══════════════════
esp_err_t streamHandler(httpd_req_t* req) {
    char part[64];
    esp_err_t res = httpd_resp_set_type(req, STREAM_CONTENT_TYPE);
    if (res != ESP_OK) return res;
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    Serial.println("[Stream] 用戶端已連線");
    uint32_t frames = 0;

    while (true) {
        camera_fb_t* fb = esp_camera_fb_get();
        if (!fb) { res = ESP_FAIL; break; }

        size_t hlen = snprintf(part, sizeof(part), STREAM_PART, fb->len);
        res = httpd_resp_send_chunk(req, STREAM_BOUNDARY, strlen(STREAM_BOUNDARY));
        if (res == ESP_OK) res = httpd_resp_send_chunk(req, part, hlen);
        if (res == ESP_OK) res = httpd_resp_send_chunk(req, (const char*)fb->buf, fb->len);
        esp_camera_fb_return(fb);

        if (res != ESP_OK) break;   // 用戶端斷線
        if (++frames % 100 == 0)
            Serial.printf("[Stream] 已送出 %lu 張\n", frames);
    }
    Serial.println("[Stream] 用戶端離線");
    return res;
}

// ═══════════════════ /provision handler ═══════════════════
esp_err_t provisionHandler(httpd_req_t* req) {
    // 讀取 body
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

    // 解析 JSON {"ssid":"...","password":"..."}
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, buf);
    if (err) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad json");
        return ESP_FAIL;
    }
    String ssid = doc["ssid"] | "";
    String pass = doc["password"] | "";
    if (ssid.length() == 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "empty ssid");
        return ESP_FAIL;
    }

    Serial.printf("[Provision] 收到帳密 SSID=%s\n", ssid.c_str());
    saveCreds(ssid, pass);

    // AP 仍開著時試連 STA（~12s）
    WiFi.begin(ssid.c_str(), pass.c_str());
    unsigned long t0 = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - t0 < 12000) {
        delay(300); Serial.print(".");
    }
    Serial.println();

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    char resp[128];
    if (WiFi.status() == WL_CONNECTED) {
        String ip = WiFi.localIP().toString();
        Serial.printf("[Provision] 連線成功 IP=%s\n", ip.c_str());
        snprintf(resp, sizeof(resp),
                 "{\"status\":\"connected\",\"ip\":\"%s\"}", ip.c_str());
    } else {
        Serial.println("[Provision] 尚未連上，已儲存，重開後再試");
        snprintf(resp, sizeof(resp), "{\"status\":\"saved\"}");
    }
    httpd_resp_send(req, resp, HTTPD_RESP_USE_STRLEN);

    // 回應送出後重開，以純 STA 正常運作
    delay(1000);
    ESP.restart();
    return ESP_OK;
}

// ═══════════════════ HTTP servers ═══════════════════
void startStreamServer() {
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = 80;
    httpd_uri_t uri = {
        .uri = "/stream", .method = HTTP_GET,
        .handler = streamHandler, .user_ctx = nullptr
    };
    if (httpd_start(&webServer, &config) == ESP_OK)
        httpd_register_uri_handler(webServer, &uri);
}

void startProvisionServer() {
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = 80;
    httpd_uri_t uri = {
        .uri = "/provision", .method = HTTP_POST,
        .handler = provisionHandler, .user_ctx = nullptr
    };
    if (httpd_start(&webServer, &config) == ESP_OK)
        httpd_register_uri_handler(webServer, &uri);
}

// ═══════════════════ 連線模式 ═══════════════════
bool connectSTA(const String& ssid, const String& pass) {
    WiFi.mode(WIFI_STA);
    WiFi.begin(ssid.c_str(), pass.c_str());
    Serial.printf("[WiFi] 連線中 (%s)", ssid.c_str());
    unsigned long t0 = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - t0 < 15000) {
        delay(500); Serial.print(".");
    }
    Serial.println();
    return WiFi.status() == WL_CONNECTED;
}

void startProvisioning() {
    Serial.println("[Setup] 進入設定模式");
    WiFi.mode(WIFI_AP_STA);
    WiFi.softAP(AP_SSID, AP_PASS);
    startProvisionServer();
    Serial.printf("[Setup] 設定熱點: %s (密碼 %s)\n", AP_SSID, AP_PASS);
    Serial.printf("[Setup] 手機連上後，App 送設定到 http://%s/provision\n",
                  WiFi.softAPIP().toString().c_str());
}

void startCamera() {
    if (!cameraInit()) {
        Serial.println("[Camera] 初始化失敗，停住。檢查 PSRAM 與排線。");
        while (true) delay(1000);
    }
    Serial.println("[Camera] OV2640 初始化成功（QVGA JPEG）");

    if (MDNS.begin(MDNS_HOST))
        Serial.printf("[mDNS] http://%s.local/stream\n", MDNS_HOST);

    startStreamServer();
    Serial.printf("[Stream] 串流網址: http://%s/stream\n",
                  WiFi.localIP().toString().c_str());
    Serial.printf(">>> 在 App 輸入裝置 IP: %s 即可串流 <<<\n",
                  WiFi.localIP().toString().c_str());
}

// ═══════════════════ setup / loop ═══════════════════
void setup() {
    Serial.begin(115200);
    delay(1500);
    Serial.println("\n────── OV2640 MJPEG + WiFi 設定 ──────");

    if (psramFound())
        Serial.printf("[PSRAM] OK，大小: %u KB\n", ESP.getPsramSize() / 1024);
    else
        Serial.println("[PSRAM] ⚠ 未偵測到，檢查 platformio.ini 的 memory_type");

    String ssid, pass;
    if (loadCreds(ssid, pass) && connectSTA(ssid, pass)) {
        startCamera();          // 正常運作
    } else {
        startProvisioning();    // 等 App 送帳密
    }
}

void loop() {
    // AP_STA 設定模式：httpd 背景處理，這裡不做事
    // STA 正常模式：監看 WiFi，斷了就重連
    if (WiFi.getMode() == WIFI_STA && WiFi.status() != WL_CONNECTED) {
        Serial.println("[WiFi] 斷線，重連中...");
        WiFi.reconnect();
    }
    delay(5000);
}
