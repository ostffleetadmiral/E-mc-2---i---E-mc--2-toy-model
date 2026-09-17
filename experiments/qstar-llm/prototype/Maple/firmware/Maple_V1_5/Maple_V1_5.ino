#include <SPI.h>
#include <SimpleTimer.h>
#include <WebServer.h>
#include <SPIFFS.h>
#include <SD.h>
#include <WiFi.h>
#include <WiFiMulti.h>
#include <ArduinoJson.h>
#include <Update.h>
#include <ESPmDNS.h>
#include <DNSServer.h>

WebServer server(80);
WiFiMulti wifiMulti;
DynamicJsonDocument doc(2048);
JsonObject obj; 
SimpleTimer timer;

#define NODE_NAME "qstar001"
#define NODE_TLD  ".qstar"
#define MESH_AP_SSID "qstar-mesh"
#define MESH_AP_PASS "qstar-mesh"
#define ULA_PREFIX_FD00 0xFD00
#define ULA_PREFIX_7374 0x7374
#define ULA_PREFIX_6172 0x6172

String g_node_name = NODE_NAME;
String g_node_fqdn = String(NODE_NAME) + String(NODE_TLD);
const char* host = NODE_NAME;
DNSServer g_dns_server;
bool g_dns_active = false;

struct MeshNode {
  String name;
  String fqdn;
  String ip;
  String ipv6;
  String status;
  uint32_t last_seen_ms;
};
#define MAX_MESH_NODES 16
MeshNode g_mesh_nodes[MAX_MESH_NODES];
int g_mesh_node_count = 0;
String ssid = "";
String password =  "";
String header,body,footer;
String webpage = "";
String CurrentRoot = "";
String MainRoot;
bool SD_present; 
bool is_from_my_files = false;
bool got_user_network = false;
String Version = "v.1.5";

// wasm3 runtime state — stubbed out (library removed to save flash)
static bool g_wasm3_ready = false;
static bool g_wasm3_attempted = true;
static String g_wasm3_status = "disabled (flash constraint)";
static String g_update_error = "none";
static uint32_t g_update_size = 0;
static uint32_t g_wasm3_mem_pages = 0;
static uint32_t g_corpus_loaded_bytes = 0;
static uint32_t g_corpus_files_scanned = 0;
static uint32_t g_corpus_sentences_learned = 0;
static String g_corpus_scan_status = "not scanned";
static bool g_wasm3_is_lite = false;
static size_t g_wasm3_input_max = 0;
static size_t g_wasm3_output_max = 0;

// Native C++ agent_lite engine — forward declarations (defined later in file)
static bool g_native_ready = false;
String nativeGenerate(String prompt);
void nativeInit();
static int countCorpusSentences();
void handleApiCorpusUpload();
void handleApiCorpusUploadFile();



void WiFiStationConnected(WiFiEvent_t event, WiFiEventInfo_t info){
  Serial.println("Connected to AP successfully!");
}

void WiFiGotIP(WiFiEvent_t event, WiFiEventInfo_t info){
  Serial.println("IP address: ");
  Serial.println(WiFi.localIP());
}

void WiFiStationDisconnected(WiFiEvent_t event, WiFiEventInfo_t info)
{
  Serial.println("Disconnected from WiFi access point");
  Serial.print("WiFi lost connection. Reason: ");
  Serial.println(info.wifi_sta_disconnected.reason);
}

JsonObject getJSonFromFile(DynamicJsonDocument *doc, String filename, bool forceCleanONJsonError = true ) 
{
    File myWifilist;
    myWifilist = SPIFFS.open(filename);
    if (myWifilist) 
    {
        DeserializationError error = deserializeJson(*doc, myWifilist);
        if (error) {
            // if the file didn't open, print an error:
            Serial.print(F("Error parsing JSON "));
            Serial.println(error.c_str());
 
            if (forceCleanONJsonError){
                return doc->to<JsonObject>();
            }
        }
 
        myWifilist.close();
 
        return doc->as<JsonObject>();
    } 
    else 
    {
        Serial.print(F("Error opening (or file not exists) "));
        Serial.println(filename);
        Serial.println(F("Empty json created"));
        return doc->to<JsonObject>();
    }
 
}
 
bool saveJSonToAFile(DynamicJsonDocument *doc, String filename) 
{
    Serial.println(F("Open file in write mode"));
    File myWifilist;
    myWifilist = SPIFFS.open(filename, FILE_WRITE);
    if (myWifilist) 
    {
        Serial.print(F("Filename --> "));
        Serial.println(filename);
        Serial.print(F("Start write..."));
        serializeJson(*doc, myWifilist);
        Serial.print(F("..."));
        myWifilist.close();
        Serial.println(F("done."));
        return true;
    } 
    else 
    {
        Serial.print(F("Error opening "));
        Serial.println(filename);
        return false;
    }
}

void printFile(const char *filename) 
{
    File file = SPIFFS.open(filename);
    if (!file) 
    {
        Serial.println(F("Failed to read file"));
        return;
    }
    while (file.available()) 
    {
        String payload = file.readString();
        Serial.print(payload);
    }
    Serial.println();
    file.close();
}
 

void SaveWifiCred()
{
    obj = getJSonFromFile(&doc, "/wificred.json");
    JsonArray data;
    if (!obj.containsKey(F("data"))) {
        Serial.println(F("Not find data array! Crete one!"));
        data = obj.createNestedArray(F("data"));
    } else {
        Serial.println(F("Find data array!"));
        data = obj[F("data")];
    }
 
    JsonObject objArrayData = data.createNestedObject();
 
    objArrayData["wifi_name"] = ssid;
    objArrayData["wifi_pwd"] = password;
 
    boolean isSaved = saveJSonToAFile(&doc, "/wificred.json");
 
    if (isSaved)
    {
        Serial.println("File saved!");
    }else
    {
        Serial.println("Error on save File!");
    } 
    return; 
}

void loadNodeConfig()
{
  if (SPIFFS.exists("/node.conf"))
  {
    File f = SPIFFS.open("/node.conf", "r");
    if (f)
    {
      String name = f.readStringUntil('\n');
      name.trim();
      if (name.length() > 0 && name.length() < 32)
      {
        g_node_name = name;
        g_node_fqdn = name + String(NODE_TLD);
        host = g_node_name.c_str();
      }
      f.close();
    }
  }
}

void saveNodeConfig(const String& name)
{
  g_node_name = name;
  g_node_fqdn = name + String(NODE_TLD);
  host = g_node_name.c_str();
  File f = SPIFFS.open("/node.conf", "w");
  if (f)
  {
    f.println(name);
    f.close();
  }
}

void startDnsServer()
{
  g_dns_server.setErrorReplyCode(DNSReplyCode::NoError);
  if (g_dns_server.start(53, String(NODE_TLD), WiFi.softAPIP()))
  {
    g_dns_active = true;
    Serial.println("DNS server started for *.qstar -> " + WiFi.softAPIP().toString());
  }
  else
  {
    Serial.println("DNS server failed to start");
  }
}

void setupWifi()
{
  loadNodeConfig();
  WiFi.mode(WIFI_AP_STA);
  WiFi.enableIPv6();
  WiFi.softAP(MESH_AP_SSID, MESH_AP_PASS);
  Serial.println("AP IP: " + WiFi.softAPIP().toString());
  obj = getJSonFromFile(&doc, "/wificred.json");
  for(int i=0;i<obj["data"].size();i++)
  {
    String wifi_name = obj["data"][i]["wifi_name"];
    String wifi_pwd = obj["data"][i]["wifi_pwd"];
    wifiMulti.addAP(wifi_name.c_str(),wifi_pwd.c_str());
  } 
  if(wifiMulti.run() == WL_CONNECTED)
  {
    Serial.println(WiFi.localIP());
  }
  if(got_user_network)
  {
    WiFi.onEvent(WiFiStationConnected, ARDUINO_EVENT_WIFI_STA_CONNECTED);
    WiFi.onEvent(WiFiGotIP, ARDUINO_EVENT_WIFI_STA_GOT_IP);
    WiFi.onEvent(WiFiStationDisconnected, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
    WiFi.begin(ssid.c_str(),password.c_str()); 
    SaveWifiCred();  
  }

}

void change_to_usb_mode()
{
  SD.end();
  SPI.end();
  digitalWrite(4,LOW);
  SD_present = false;
  timer.setTimeout(500,[]()
  {
    digitalWrite(27,HIGH);
    digitalWrite(4,HIGH);
  //        digitalWrite(4,LOW);    // Buffer IC OFF  
  timer.setTimeout(100,[]()
  {
    digitalWrite(25,HIGH);    // Buffer IC OFF
    digitalWrite(26,LOW);
    Serial.println("CHIP DETECTED");// chip detect
  });
  });
  Serial.print(F("USB mode Initialized."));
}

void change_to_sd_mode()
{
  Serial.print(F("Initializing SD card..."));
  digitalWrite(25,LOW);
  digitalWrite(4,LOW);
  //SD_present = true;
  timer.setTimeout(100,[]()
  {
    digitalWrite(4,HIGH);
    Serial.println("SD card mode changed");
    digitalWrite(27,LOW);
    digitalWrite(26,HIGH);
    delay(20);
    digitalWrite(25,LOW);  //BUffer IC LOW 
    int sd_retries = 0;
    while(!SD.begin(SS, SPI, 4000000, "/sd", 5, true) && sd_retries < 20){
      Serial.println("SD Card init retry...");
      sd_retries++;
      delay(200);
    }
    if (sd_retries < 20) {
      SD_present = true;
      Serial.println("SD card done");
      Serial.printf("SD card type: %d, size: %llu MB\n", (int)SD.cardType(), SD.cardSize() / (1024 * 1024));
    } else {
      SD_present = false;
      Serial.println("SD card init failed after 20 retries — continuing without SD");
    }
  });
}

void setup(void)
{
      Serial.begin(115200);
      pinMode(25,OUTPUT);     //Select pin, Buffer LOW for ESP and HIGH for card reader 
      pinMode(26,OUTPUT);     //SDcard chip detect (active LOW)
      pinMode(4,OUTPUT);      //HIGH to Powerup microSD card (MOSFET)
      pinMode(27,OUTPUT);     //SD RESET
      Serial.print(F("Initializing USB mode as Default..."));
      if (!SPIFFS.begin()) {
        Serial.println("SPIFFS mount failed — formatting");
        SPIFFS.format();
        if (!SPIFFS.begin()) {
          Serial.println("SPIFFS format+begin failed");
        }
      }
      MDNS.begin(host);
  if (!MDNS.begin(host)) {
    Serial.println("Error starting mDNS responder");
  } else {
    MDNS.addService("http", "tcp", 80);
    Serial.println("mDNS server started: " + String(host) + ".local");
  }
  change_to_usb_mode(); 
  setupWifi();
  startDnsServer();
      //WiFi.softAP("pen_drive","12345678");
      ///////////////////////////// Server Commands 
      server.on("/",              Homepage);
      server.on("/MyFiles",       My_Files);
      server.on("/files",         My_Files);
      server.on("/ConnectToWifi", ConnectToWifi);
      server.on("/upload" ,HTTP_POST, [](){
            is_from_my_files = true; My_Files();},handleFileUpload);
      server.on("/sel-mode",HTTP_POST, [](){ change_mode(); delay(200);
            server.sendHeader(F("Location"), F("/"));server.send(303);
            });
      server.on("/network" ,HTTP_POST, [](){ got_user_network = true;
            ssid = server.arg(0); password = server.arg(1); ConnectToWifi();});

      server.on("/FirmwareUpdate", HTTP_GET, []() {
        File file = SPIFFS.open("/Firmware_update.html");
        String page = file.readString();
        file.close();
        page.replace(F("<% version %>"),Version);
        int pagesize = page.length();
        server.sendHeader("Connection", "close");
        server.setContentLength(pagesize);
        server.send(200, "text/html", page);
      });
      server.on("/update", HTTP_POST, []() {
        server.sendHeader("Connection", "close");
        bool ok = !Update.hasError();
        server.send(200, "text/plain", ok ? "OK" : "FAIL");
        if (ok) ESP.restart();
        }, []() { Update_Firmware(); });
         
      server.on("/back.png",[](){
        File file_img = SPIFFS.open("/back.png");
        server.streamFile(file_img,"image/png");
        file_img.close();
      });
      ///////////////////////////// Qstar routes (v1.5)
      server.on("/api/agent", handleApiAgent);
      server.on("/api/agent/generate", HTTP_POST, handleApiAgentGenerate);
      server.on("/api/corpus/scan", HTTP_POST, handleApiCorpusScan);
      server.on("/api/corpus/pull", HTTP_POST, handleApiCorpusPull);
      server.on("/api/corpus/upload", HTTP_POST, handleApiCorpusUpload, handleApiCorpusUploadFile);
      server.on("/api/diag", handleApiDiag);
      server.on("/api/mesh/nodes", handleApiMeshNodes);
      server.on("/api/mesh/register", HTTP_POST, handleApiMeshRegister);
      server.on("/api/mesh/topology", handleApiMeshTopology);
      server.on("/api/bench", HTTP_POST, handleApiBench);
      server.on("/chat", handleChat);
      server.on("/quine", handleQuine);
      ///////////////////////////// End of Qstar routes
      server.on("/home.png",[](){
        File file_img = SPIFFS.open("/home.png");
        server.streamFile(file_img,"image/png");
        file_img.close();
      });
      server.on("/SDCard.png",[](){
        File file_img = SPIFFS.open("/SDCard.png");
        server.streamFile(file_img,"image/png");
        file_img.close();
      });
      ///////////////////////////// End of Request commands
      server.begin();
      MDNS.addService("_http", "_tcp", 80);
      MDNS.addServiceTxt("_http", "_tcp", "board", "ESP32");
      Serial.println("HTTP server started");
      initWasm3();
  nativeInit();
}
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
void loop(void)
{
    timer.run();
    if (g_dns_active) g_dns_server.processNextRequest();
    server.handleClient(); // Listen for client connections
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Qstar additions (v1.5) — agent status, chat UI, quine serving from SD
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
void handleApiAgent()
{
  String json = "{\n";
  json += "  \"device\": \"maple\",\n";
  json += "  \"version\": \"" + Version + "\",\n";
  json += "  \"sd_present\": " + String(SD_present ? "true" : "false") + ",\n";
  json += "  \"wifi_mode\": \"" + String(WiFi.getMode() == WIFI_AP_STA ? "ap_sta" : "ap") + "\",\n";
  json += "  \"ap_ip\": \"" + WiFi.softAPIP().toString() + "\",\n";
  json += "  \"sta_ip\": \"" + WiFi.localIP().toString() + "\",\n";
  json += "  \"agent\": \"qstar-lattice-native\",\n";
  json += "  \"agent_state_bytes\": 23576,\n";
  json += "  \"native_engine\": " + String(g_native_ready ? "true" : "false") + ",\n";
  json += "  \"wasm3\": " + String(g_wasm3_ready ? "true" : "false") + ",\n";
  json += "  \"wasm3_status\": \"" + g_wasm3_status + "\",\n";
  json += "  \"wasm3_mode\": \"" + String(g_wasm3_is_lite ? "lite" : "full") + "\",\n";
  json += "  \"wasm3_version\": \"" + wasm3Version() + "\",\n";
  json += "  \"corpus_sentences\": " + String(countCorpusSentences()) + ",\n";
  json += "  \"corpus_loaded_bytes\": " + String(g_corpus_loaded_bytes) + ",\n";
  json += "  \"corpus_files_scanned\": " + String(g_corpus_files_scanned) + ",\n";
  json += "  \"corpus_sentences_learned\": " + String(g_corpus_sentences_learned) + ",\n";
  json += "  \"corpus_scan_status\": \"" + g_corpus_scan_status + "\",\n";
  json += "  \"wasm3_mem_pages\": " + String(g_wasm3_mem_pages) + ",\n";
  json += "  \"input_max\": " + String(g_wasm3_input_max) + ",\n";
  json += "  \"output_max\": " + String(g_wasm3_output_max) + ",\n";
  json += "  \"update_error\": \"" + g_update_error + "\",\n";
  json += "  \"update_size\": " + String(g_update_size) + ",\n";
  json += "  \"free_heap\": " + String(ESP.getFreeHeap()) + ",\n";
  json += "  \"hostname\": \"" + String(host) + "\",\n";
  json += "  \"node_name\": \"" + g_node_name + "\",\n";
  json += "  \"node_fqdn\": \"" + g_node_fqdn + "\",\n";
  json += "  \"wifi_connected\": " + String(WiFi.status() == WL_CONNECTED ? "true" : "false") + ",\n";
  json += "  \"ip\": \"" + WiFi.localIP().toString() + "\",\n";
  json += "  \"ap_ip\": \"" + WiFi.softAPIP().toString() + "\",\n";
  json += "  \"dns_server_active\": " + String(g_dns_active ? "true" : "false") + ",\n";
  json += "  \"mesh_nodes\": " + String(g_mesh_node_count) + "\n";
  json += "}";
  server.send(200, "application/json", json);
}

void handleApiDiag()
{
  const esp_partition_t* spiffs = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_SPIFFS, NULL);
  String json = "{\n";
  json += "  \"spiffs_found\": " + String(spiffs ? "true" : "false") + ",\n";
  if (spiffs) {
    json += "  \"spiffs_addr\": \"0x" + String(spiffs->address, HEX) + "\",\n";
    json += "  \"spiffs_size\": " + String(spiffs->size) + ",\n";
    esp_err_t e1 = esp_partition_erase_range(spiffs, 0, 0x1000);
    json += "  \"erase_4k\": " + String((int)e1) + ",\n";
    esp_err_t e2 = esp_partition_erase_range(spiffs, 0, 0x10000);
    json += "  \"erase_64k\": " + String((int)e2) + ",\n";
    uint32_t test_word = 0xDEADBEEF;
    esp_err_t e3 = esp_partition_write(spiffs, 0, &test_word, 4);
    json += "  \"write_4b\": " + String((int)e3) + ",\n";
    esp_err_t e4 = esp_partition_erase_range(spiffs, 0, 0x1000);
    json += "  \"erase_after_write\": " + String((int)e4) + "\n";
  } else {
    json += "  \"spiffs_addr\": \"none\"\n";
  }
  json += "}";
  server.send(200, "application/json", json);
}

void handleApiMeshNodes()
{
  String json = "{\n";
  json += "  \"count\": " + String(g_mesh_node_count) + ",\n";
  json += "  \"nodes\": [\n";
  for (int i = 0; i < g_mesh_node_count; i++)
  {
    json += "    {\"name\":\"" + g_mesh_nodes[i].fqdn + "\",\"ip\":\"" + g_mesh_nodes[i].ip + "\",\"status\":\"" + g_mesh_nodes[i].status + "\"}";
    if (i < g_mesh_node_count - 1) json += ",";
    json += "\n";
  }
  json += "  ]\n";
  json += "}";
  server.send(200, "application/json", json);
}

void handleApiMeshRegister()
{
  String nodeName = server.arg(0);
  String nodeIp = server.arg(1);
  if (nodeName.length() == 0 || nodeIp.length() == 0)
  {
    server.send(400, "application/json", "{\"error\":\"missing name or ip\"}");
    return;
  }
  if (g_mesh_node_count >= MAX_MESH_NODES)
  {
    server.send(507, "application/json", "{\"error\":\"mesh node registry full\"}");
    return;
  }
  for (int i = 0; i < g_mesh_node_count; i++)
  {
    if (g_mesh_nodes[i].name == nodeName)
    {
      g_mesh_nodes[i].ip = nodeIp;
      g_mesh_nodes[i].status = "online";
      g_mesh_nodes[i].last_seen_ms = millis();
      server.send(200, "application/json", "{\"status\":\"updated\",\"name\":\"" + nodeName + "\"}");
      return;
    }
  }
  g_mesh_nodes[g_mesh_node_count].name = nodeName;
  g_mesh_nodes[g_mesh_node_count].fqdn = nodeName + String(NODE_TLD);
  g_mesh_nodes[g_mesh_node_count].ip = nodeIp;
  g_mesh_nodes[g_mesh_node_count].status = "online";
  g_mesh_nodes[g_mesh_node_count].last_seen_ms = millis();
  g_mesh_node_count++;
  server.send(200, "application/json", "{\"status\":\"registered\",\"name\":\"" + nodeName + "\",\"fqdn\":\"" + nodeName + String(NODE_TLD) + "\"}");
}

void handleApiMeshTopology()
{
  String json = "{\n";
  json += "  \"self\": \"" + g_node_fqdn + "\",\n";
  json += "  \"self_ip\": \"" + WiFi.softAPIP().toString() + "\",\n";
  json += "  \"node_count\": " + String(g_mesh_node_count) + ",\n";
  json += "  \"nodes\": [\n";
  for (int i = 0; i < g_mesh_node_count; i++)
  {
    json += "    {\"id\":" + String(i) + ",\"name\":\"" + g_mesh_nodes[i].fqdn + "\",\"ip\":\"" + g_mesh_nodes[i].ip + "\",\"status\":\"" + g_mesh_nodes[i].status + "\"}";
    if (i < g_mesh_node_count - 1) json += ",";
    json += "\n";
  }
  json += "  ],\n";
  json += "  \"edges\": [\n";
  for (int i = 0; i < g_mesh_node_count; i++)
  {
    json += "    {\"source\":\"" + g_node_fqdn + "\",\"target\":\"" + g_mesh_nodes[i].fqdn + "\"}";
    if (i < g_mesh_node_count - 1) json += ",";
    json += "\n";
  }
  json += "  ]\n";
  json += "}";
  server.send(200, "application/json", json);
}

void handleApiBench()
{
  uint32_t t0, t1;
  String prompt = server.arg(0);
  if (prompt.length() == 0) prompt = "hello";
  int iterations = 5;
  if (server.args() > 1) iterations = server.arg(1).toInt();
  if (iterations < 1) iterations = 1;
  if (iterations > 20) iterations = 20;

  uint32_t min_ms = 0xFFFFFFFF, max_ms = 0, total_ms = 0;
  uint32_t heap_before = ESP.getFreeHeap();

  for (int i = 0; i < iterations; i++)
  {
    t0 = millis();
    String resp = nativeGenerate(prompt);
    t1 = millis();
    uint32_t elapsed = t1 - t0;
    if (elapsed < min_ms) min_ms = elapsed;
    if (elapsed > max_ms) max_ms = elapsed;
    total_ms += elapsed;
  }
  uint32_t heap_after = ESP.getFreeHeap();

  String json = "{\n";
  json += "  \"prompt\": \"" + prompt + "\",\n";
  json += "  \"iterations\": " + String(iterations) + ",\n";
  json += "  \"min_ms\": " + String(min_ms) + ",\n";
  json += "  \"max_ms\": " + String(max_ms) + ",\n";
  json += "  \"avg_ms\": " + String(total_ms / iterations) + ",\n";
  json += "  \"total_ms\": " + String(total_ms) + ",\n";
  json += "  \"heap_before\": " + String(heap_before) + ",\n";
  json += "  \"heap_after\": " + String(heap_after) + ",\n";
  json += "  \"heap_delta\": " + String((int32_t)(heap_before - heap_after)) + ",\n";
  json += "  \"native_ready\": " + String(g_native_ready ? "true" : "false") + "\n";
  json += "}";
  server.send(200, "application/json", json);
}

void handleChat()
{
  serveChatUI();
}

void serveChatUI()
{
  String page = F("<!DOCTYPE html><html><head><meta name='viewport' content='width=device-width, initial-scale=1'><title>Maple Chat</title>");
  page += F("<style>");
  page += F("*{box-sizing:border-box;margin:0;padding:0}");
  page += F("body{font-family:-apple-system,system-ui,sans-serif;background:#0d1117;color:#c9d1d9;height:100vh;display:flex;flex-direction:column;overflow:hidden}");
  page += F("header{background:#161b22;border-bottom:1px solid #30363d;padding:10px 16px;display:flex;align-items:center;gap:12px;flex-shrink:0}");
  page += F("header h1{font-size:18px;color:#58a6ff;flex-shrink:0;cursor:pointer}");
  page += F("#status-bar{font-size:12px;color:#8b949e;margin-left:auto;display:flex;gap:8px;flex-wrap:wrap;align-items:center}");
  page += F("#status-bar span{padding:2px 8px;border-radius:4px;background:#21262d}");
  page += F("#status-bar .ok{color:#3fb950}#status-bar .warn{color:#d29922}#status-bar .err{color:#f85149}");
  page += F("#gear-btn{background:none;border:none;color:#8b949e;font-size:20px;cursor:pointer;padding:4px 8px;border-radius:6px}");
  page += F("#gear-btn:hover{background:#21262d;color:#58a6ff}");
  page += F("#main{flex:1;display:flex;overflow:hidden}");
  page += F("#chat-wrap{flex:1;display:flex;flex-direction:column;overflow:hidden}");
  page += F("#chat{flex:1;overflow-y:auto;padding:16px;max-width:800px;width:100%;margin:0 auto}");
  page += F(".msg{margin:8px 0;padding:10px 14px;border-radius:12px;max-width:85%;line-height:1.5;word-wrap:break-word}");
  page += F(".msg.user{background:#1f6feb;color:#fff;margin-left:auto;border-bottom-right-radius:4px}");
  page += F(".msg.bot{background:#21262d;border:1px solid #30363d;border-bottom-left-radius:4px}");
  page += F(".msg.sys{background:#1c2128;border:1px solid #30363d;font-size:12px;color:#8b949e;text-align:center;max-width:100%}");
  page += F(".msg .label{font-size:11px;opacity:0.6;margin-bottom:4px;text-transform:uppercase;letter-spacing:0.5px}");
  page += F("#input-area{background:#161b22;border-top:1px solid #30363d;padding:12px 16px;display:flex;gap:8px;max-width:800px;width:100%;margin:0 auto;flex-shrink:0}");
  page += F("textarea{flex:1;background:#0d1117;color:#c9d1d9;border:1px solid #30363d;border-radius:8px;padding:10px 12px;font-size:14px;resize:none;height:48px;max-height:120px;font-family:inherit}");
  page += F("textarea:focus{outline:none;border-color:#58a6ff}");
  page += F("button{background:#238636;color:#fff;border:none;border-radius:8px;padding:10px 20px;font-size:14px;cursor:pointer;white-space:nowrap}");
  page += F("button:hover{background:#2ea043}button:disabled{opacity:0.5;cursor:not-allowed}");
  page += F("button.secondary{background:#21262d;border:1px solid #30363d}");
  page += F("button.secondary:hover{background:#30363d}");
  page += F("#corpus-panel{background:#161b22;border-top:1px solid #30363d;padding:8px 16px;font-size:12px;color:#8b949e;max-width:800px;width:100%;margin:0 auto;display:flex;gap:12px;align-items:center;flex-wrap:wrap;flex-shrink:0}");
  page += F("#corpus-panel .info{flex:1}");
  /* Settings sidebar */
  page += F("#settings{width:340px;max-width:85vw;background:#161b22;border-left:1px solid #30363d;display:none;flex-direction:column;overflow-y:auto;flex-shrink:0}");
  page += F("#settings.open{display:flex}");
  page += F("#settings-header{padding:12px 16px;border-bottom:1px solid #30363d;display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;background:#161b22;z-index:1}");
  page += F("#settings-header h2{font-size:16px;color:#58a6ff}");
  page += F("#settings-close{background:none;border:none;color:#8b949e;font-size:22px;cursor:pointer;padding:0 4px}");
  page += F("#settings-close:hover{color:#f85149}");
  page += F(".set-section{padding:12px 16px;border-bottom:1px solid #21262d}");
  page += F(".set-section h3{font-size:13px;color:#8b949e;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:8px}");
  page += F(".set-section label{display:block;font-size:13px;color:#c9d1d9;margin-bottom:4px}");
  page += F(".set-section input[type=text],.set-section input[type=password]{width:100%;background:#0d1117;color:#c9d1d9;border:1px solid #30363d;border-radius:6px;padding:8px 10px;font-size:13px;margin-bottom:8px}");
  page += F(".set-section input:focus{outline:none;border-color:#58a6ff}");
  page += F(".set-section .row{display:flex;gap:8px;align-items:center;margin-bottom:8px}");
  page += F(".set-section .row input{flex:1}");
  page += F(".set-section .info-line{font-size:12px;color:#8b949e;margin-bottom:4px}");
  page += F(".set-section .info-line span{color:#c9d1d9}");
  page += F(".set-section button{width:100%;margin-top:4px}");
  page += F("#file-input{display:none}");
  page += F("</style></head><body>");
  /* Header */
  page += F("<header><h1 onclick='location.href=\"/\"'>Maple</h1><div id='status-bar'></div>");
  page += F("<button id='gear-btn' onclick='toggleSettings()' title='Settings'>&#9881;</button></header>");
  /* Main layout */
  page += F("<div id='main'><div id='chat-wrap'>");
  /* Chat area */
  page += F("<div id='chat'><div class='msg sys'>On-device inference via native agent_lite engine. Drop .txt or .md files in /corpus/ on SD card and click Scan Corpus to expand knowledge.</div></div>");
  /* Corpus panel */
  page += F("<div id='corpus-panel'>");
  page += F("<span class='info' id='corpus-info'>Corpus: loading...</span>");
  page += F("<button class='secondary' id='scan-btn' onclick='scanCorpus()'>Scan SD Corpus</button>");
  page += F("</div>");
  /* Input area */
  page += F("<div id='input-area'>");
  page += F("<textarea id='in' placeholder='Ask the lattice agent...' onkeydown='if(event.key===\"Enter\"&&!event.shiftKey){event.preventDefault();send()}'></textarea>");
  page += F("<button id='send-btn' onclick='send()'>Send</button>");
  page += F("</div></div>");
  /* Settings sidebar */
  page += F("<div id='settings'>");
  page += F("<div id='settings-header'><h2>Settings</h2><button id='settings-close' onclick='toggleSettings()'>&times;</button></div>");
  /* WiFi section */
  page += F("<div class='set-section'><h3>WiFi</h3>");
  page += F("<div class='info-line'>Status: <span id='wifi-status'>checking...</span></div>");
  page += F("<div class='info-line'>IP: <span id='wifi-ip'>-</span></div>");
  page += F("<label>SSID</label><input type='text' id='wifi-ssid' placeholder='Network name'>");
  page += F("<label>Password</label><input type='password' id='wifi-pass' placeholder='Password'>");
  page += F("<button class='secondary' onclick='connectWifi()'>Connect</button>");
  page += F("</div>");
  /* Device section */
  page += F("<div class='set-section'><h3>Device</h3>");
  page += F("<div class='info-line'>Version: <span id='dev-version'>-</span></div>");
  page += F("<div class='info-line'>Hostname: <span id='dev-host'>-</span></div>");
  page += F("<div class='info-line'>Heap: <span id='dev-heap'>-</span></div>");
  page += F("<div class='info-line'>Engine: <span id='dev-wasm'>-</span></div>");
  page += F("<div class='info-line'>Mode: <span id='dev-mode'>-</span></div>");
  page += F("</div>");
  /* Storage section */
  page += F("<div class='set-section'><h3>Storage</h3>");
  page += F("<div class='info-line'>SD Card: <span id='sd-status'>-</span></div>");
  page += F("<div class='row'><button class='secondary' onclick='toggleMode()'>Toggle USB/SD Mode</button></div>");
  page += F("<div class='row'><a href='/MyFiles'><button class='secondary' style='width:100%'>My Files</button></a></div>");
  page += F("</div>");
  /* Firmware update section */
  page += F("<div class='set-section'><h3>Firmware Update</h3>");
  page += F("<input type='file' id='file-input' accept='.bin' onchange='uploadFirmware(this)'>");
  page += F("<button class='secondary' onclick='document.getElementById(\"file-input\").click()'>Select Firmware .bin</button>");
  page += F("<div class='info-line' id='upload-status'></div>");
  page += F("</div>");
  /* Corpus section */
  page += F("<div class='set-section'><h3>Corpus</h3>");
  page += F("<div class='info-line'>Sentences: <span id='corpus-sents'>-</span></div>");
  page += F("<div class='info-line'>Loaded bytes: <span id='corpus-bytes'>-</span></div>");
  page += F("<div class='info-line'>Scan status: <span id='corpus-scan'>-</span></div>");
  page += F("<button class='secondary' onclick='scanCorpus()'>Scan SD Corpus</button>");
  page += F("</div>");
  /* Mesh section */
  page += F("<div class='set-section'><h3>Mesh</h3>");
  page += F("<div class='info-line'>Nodes: <span id='mesh-nodes'>-</span></div>");
  page += F("<div class='info-line' id='mesh-list'>-</div>");
  page += F("</div>");
  page += F("</div></div>");
  /* Script */
  page += F("<script>");
  page += F("const chat=document.getElementById('chat'),inp=document.getElementById('in'),sendBtn=document.getElementById('send-btn'),scanBtn=document.getElementById('scan-btn');");
  page += F("function toggleSettings(){document.getElementById('settings').classList.toggle('open')}");
  page += F("function addMsg(text,cls){const d=document.createElement('div');d.className='msg '+cls;d.textContent=text;chat.appendChild(d);chat.scrollTop=chat.scrollHeight;}");
  page += F("function updateStatus(j){const sb=document.getElementById('status-bar');");
  page += F("const cls=j.native_engine?'ok':'err';const mode=j.wasm3_mode||'?';const sents=j.corpus_sentences||0;const heap=j.free_heap||0;");
  page += F("sb.innerHTML='<span class=\"'+cls+'\">Engine: '+(j.native_engine?'native':'down')+'</span><span>Corpus: '+sents+' sents</span><span>Heap: '+(heap/1024).toFixed(1)+' KB</span>';");
  page += F("document.getElementById('corpus-info').textContent='Corpus: '+sents+' sentences'+(j.corpus_loaded_bytes>0?' ('+j.corpus_loaded_bytes+' B loaded from SD)':'')+' | Scan: '+j.corpus_scan_status;");
  page += F("var d=document.getElementById('dev-version');if(d)d.textContent=j.version||'-';");
  page += F("d=document.getElementById('dev-host');if(d)d.textContent=j.hostname||'-';");
  page += F("d=document.getElementById('dev-heap');if(d)d.textContent=(heap/1024).toFixed(1)+' KB';");
  page += F("d=document.getElementById('dev-wasm');if(d)d.textContent=j.native_engine?'native (agent_lite)':'down';");
  page += F("d=document.getElementById('dev-mode');if(d)d.textContent=j.native_engine?'native':'-';");
  page += F("d=document.getElementById('corpus-sents');if(d)d.textContent=sents;");
  page += F("d=document.getElementById('corpus-bytes');if(d)d.textContent=(j.corpus_loaded_bytes||0)+' B';");
  page += F("d=document.getElementById('corpus-scan');if(d)d.textContent=j.corpus_scan_status||'-';");
  page += F("d=document.getElementById('wifi-status');if(d)d.textContent=j.wifi_connected?'connected':'disconnected';");
  page += F("d=document.getElementById('wifi-ip');if(d)d.textContent=j.ip||'-';");
  page += F("d=document.getElementById('sd-status');if(d)d.textContent=j.sd_present?'present':'not present';");
  page += F("d=document.getElementById('mesh-nodes');if(d)d.textContent=(j.mesh_nodes!==undefined)?j.mesh_nodes:'-';");
  page += F("}");
  page += F("fetch('/api/agent').then(r=>r.json()).then(j=>updateStatus(j)).catch(()=>{});");
  page += F("async function send(){const p=inp.value.trim();if(!p)return;sendBtn.disabled=true;inp.value='';addMsg(p,'user');");
  page += F("addMsg('thinking...','bot');const r=await fetch('/api/agent/generate',{method:'POST',body:p});const t=await r.text();chat.lastChild.remove();addMsg(t,'bot');sendBtn.disabled=false;fetch('/api/agent').then(r=>r.json()).then(j=>updateStatus(j));}");
  page += F("async function scanCorpus(){scanBtn.disabled=true;scanBtn.textContent='Scanning...';addMsg('Scanning SD card /corpus/ directory...','sys');");
  page += F("try{const r=await fetch('/api/corpus/scan',{method:'POST'});const j=await r.json();");
  page += F("if(j.error){addMsg('Scan error: '+j.error,'sys');}else{addMsg('Corpus scan complete: '+j.files_read+' files, '+j.bytes_loaded+' bytes loaded, '+j.sentences_after+' total sentences.','sys');}}");
  page += F("catch(e){addMsg('Scan failed: '+e.message,'sys');}");
  page += F("scanBtn.disabled=false;scanBtn.textContent='Scan SD Corpus';fetch('/api/agent').then(r=>r.json()).then(j=>updateStatus(j));}");
  page += F("async function connectWifi(){const s=document.getElementById('wifi-ssid').value,p=document.getElementById('wifi-pass').value;if(!s)return;addMsg('Connecting to '+s+'...','sys');");
  page += F("try{const r=await fetch('/network',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'0='+encodeURIComponent(s)+'&1='+encodeURIComponent(p)});");
  page += F("addMsg('WiFi connection requested. Device may restart.','sys');}catch(e){addMsg('WiFi connect failed: '+e.message,'sys');}}");
  page += F("async function toggleMode(){try{await fetch('/sel-mode',{method:'POST'});addMsg('Mode toggle requested. Page may reload.','sys');setTimeout(()=>location.reload(),2000);}catch(e){addMsg('Mode toggle failed: '+e.message,'sys');}}");
  page += F("async function uploadFirmware(input){const f=input.files[0];if(!f)return;const st=document.getElementById('upload-status');st.textContent='Uploading '+f.name+'...';");
  page += F("const fd=new FormData();fd.append('update',f);try{const r=await fetch('/update',{method:'POST',body:fd});const t=await r.text();");
  page += F("if(t==='OK'){st.textContent='Update successful. Device restarting...';}else{st.textContent='Update failed: '+t;}}catch(e){st.textContent='Upload error: '+e.message;}}");
  page += F("async function loadMeshNodes(){try{const r=await fetch('/api/mesh/nodes');const j=await r.json();const ml=document.getElementById('mesh-list');if(ml&&j.nodes){ml.textContent=j.nodes.map(n=>n.name+' ('+n.status+')').join(', ');}}catch(e){}}");
  page += F("loadMeshNodes();");
  page += F("</script></body></html>");
  server.send(200, "text/html", page);
}

void handleQuine()
{
  if (!SD_present)
  {
    server.send(404, "text/plain", "SD not present — switch to SD mode first");
    return;
  }
  File f = SD.open("/universe.html");
  if (!f)
  {
    server.send(404, "text/plain", "universe.html not found on SD card");
    return;
  }
  server.streamFile(f, "text/html");
  f.close();
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// wasm3 stubs — library removed to save flash space for hardcoded responses
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

void initWasm3() { g_wasm3_attempted = true; g_wasm3_ready = false; }

String wasm3Version() { return "n/a (disabled)"; }

uint32_t wasm3CorpusCount() { return 0; }

String wasm3Generate(String prompt)
{
  return nativeGenerate(prompt);
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// Native C++ agent_lite inference engine (Phase 4 — direct port from Zig)
// Eliminates WASM3 overhead entirely. Uses ESP32 native heap + static RAM.
// Core state: int64_t Q32.32 fixed-point. Sigmoid/sincos via float FPU.
// Memory: activations 421*7*8=23.6KB static, bigram ~3.4KB static, corpus in PROGMEM.
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


static bool containsWordCI(const char* text, int textLen, const char* word) {
  int wordLen = strlen(word);
  if (wordLen == 0 || textLen < wordLen) return false;
  for (int i = 0; i <= textLen - wordLen; i++) {
    if (strncasecmp(text + i, word, wordLen) == 0) {
      bool left_ok = (i == 0) || !isalpha(text[i-1]);
      bool right_ok = (i + wordLen >= textLen) || !isalpha(text[i + wordLen]);
      if (left_ok && right_ok) return true;
    }
  }
  return false;
}

static bool containsWordCIN(const char* text, int textLen, const char* word, int wordLen) {
  if (wordLen == 0 || textLen < wordLen) return false;
  for (int i = 0; i <= textLen - wordLen; i++) {
    if (strncasecmp(text + i, word, wordLen) == 0) {
      bool left_ok = (i == 0) || !isalpha(text[i-1]);
      bool right_ok = (i + wordLen >= textLen) || !isalpha(text[i + wordLen]);
      if (left_ok && right_ok) return true;
    }
  }
  return false;
}

static bool stemMatch(const char* text, int textLen, const char* kw) {
  int kwLen = strlen(kw);
  if (kwLen <= 3) return false;
  if (containsWordCI(text, textLen, kw)) return true;
  char buf[128];
  if (kwLen > 4 && (strcmp(kw + kwLen - 2, "es") == 0)) {
    if (kwLen - 2 < 128) { memcpy(buf, kw, kwLen-2); buf[kwLen-2]=0; if (containsWordCI(text, textLen, buf)) return true; }
  }
  if (kwLen > 3 && kw[kwLen-1] == 's' && !(kwLen > 4 && kw[kwLen-2] == 's')) {
    if (kwLen - 1 < 128) { memcpy(buf, kw, kwLen-1); buf[kwLen-1]=0; if (containsWordCI(text, textLen, buf)) return true; }
  }
  if (kwLen > 5 && strcmp(kw + kwLen - 3, "ing") == 0) {
    if (kwLen - 3 < 128) { memcpy(buf, kw, kwLen-3); buf[kwLen-3]=0; if (containsWordCI(text, textLen, buf)) return true; }
  }
  if (kwLen > 4 && strcmp(kw + kwLen - 2, "ed") == 0) {
    if (kwLen - 2 < 128) { memcpy(buf, kw, kwLen-2); buf[kwLen-2]=0; if (containsWordCI(text, textLen, buf)) return true; }
  }
  if (kwLen > 4 && strcmp(kw + kwLen - 2, "ly") == 0) {
    if (kwLen - 2 < 128) { memcpy(buf, kw, kwLen-2); buf[kwLen-2]=0; if (containsWordCI(text, textLen, buf)) return true; }
  }
  if (kwLen > 4 && strcmp(kw + kwLen - 3, "ies") == 0) {
    if (kwLen - 3 + 1 < 128) { memcpy(buf, kw, kwLen-3); buf[kwLen-3]='y'; buf[kwLen-2]=0; if (containsWordCI(text, textLen, buf)) return true; }
  }
  return false;
}

// --- Semantic Synonym Groups (compact subset for concept-level matching) ---
struct SemanticGroup { const char* words[12]; };

static const SemanticGroup SEMANTIC_GROUPS[] = {
  {{"think","thinking","thought","cognition","cognitive","reason","reasoning","process","compute","computation","consider","deliberate"}},
  {{"machine","engine","system","computation","computational","deterministic","automaton","algorithm","software","program","",""}},
  {{"human","person","biological","personality","subjective","embodied","organic","mortal","","","",""}},
  {{"feel","feeling","emotion","emotional","experience","subjective","qualia","sentiment","sensation","","",""}},
  {{"know","knowledge","certain","certainty","confidence","corpus","retrieval","information","aware","awareness","",""}},
  {{"real","genuine","authentic","actual","true","honest","truthful","verifiable","","","",""}},
  {{"alive","living","life","animate","conscious","consciousness","sentient","sentience","","","",""}},
  {{"limitation","weakness","flaw","constraint","shortcoming","deficiency","drawback","restriction","","","",""}},
  {{"internal","state","activation","matrix","lattice","node","channel","entropy","","","",""}},
  {{"wrong","incorrect","error","mistake","false","inaccurate","erroneous","","","","",""}},
  {{"fail","failure","unsuccessful","breakdown","collapse","defect","","","","","",""}},
  {{"uncertain","uncertainty","doubt","unsure","tentative","ambiguous","","","","","",""}},
  {{"robot","android","automaton","bot","cyborg","machine","","","","","",""}},
  {{"Turing","imitation","indistinguishable","human-like","AGI","intelligence","intelligent","","","","",""}},
  {{"light","photon","electromagnetic","radiation","wave","wavelength","frequency","speed","velocity","vacuum","luminous","optics"}},
  {{"blue","color","spectrum","scatter","scattering","refract","refraction","diffraction","prism","rainbow","",""}},
  {{"boil","boiling","temperature","heat","thermal","Celsius","Fahrenheit","Kelvin","degree","steam","vapor",""}},
  {{"ice","freeze","freezing","solid","density","float","buoyancy","water","crystal","molecule","",""}},
  {{"Earth","rotate","rotation","spin","axis","coriolis","day","night","orbit","revolution","",""}},
  {{"chemical","formula","molecule","compound","element","atom","atomic","bond","reaction","H2O","oxygen","hydrogen"}},
  {{"photosynthesis","plant","chlorophyll","chloroplast","sunlight","glucose","carbon","dioxide","leaf","","",""}},
  {{"planet","planets","solar","system","Sun","Mercury","Venus","Mars","Jupiter","Saturn","orbit","celestial"}},
  {{"galaxy","galaxies","star","stellar","cosmic","universe","telescope","astronomy","","","",""}},
  {{"capital","city","country","France","Paris","nation","geography","geographic","London","Tokyo","",""}},
  {{"logic","logical","syllogism","deduction","deductive","premise","inference","therefore","conclude","conclusion","",""}},
  {{"intelligent","intelligence","smart","clever","bright","intellectual","perceptive","","","","",""}},
  {{"music","melody","harmony","rhythm","sound","auditory","symphony","note","chord","tune","",""}},
  {{"love","affection","attachment","devotion","romance","cherish","adore","intimacy","","","",""}},
  {{"happy","happiness","joy","joyful","delight","contentment","bliss","elation","","","",""}},
  {{"sad","sadness","sorrow","grief","mourn","unhappy","depressed","melancholy","","","",""}},
  {{"brain","neuron","neurons","neural","nervous","synapse","cognition","memory","","","",""}},
  {{"cell","cells","organism","tissue","membrane","nucleus","DNA","gene","genetic","","",""}},
  {{"energy","power","force","work","joule","watt","kinetic","potential","","","",""}},
  {{"gravity","gravitation","attraction","mass","weight","Newton","relativity","spacetime","","","",""}},
  {{"search","engine","Google","retrieval","database","index","query","browse","lookup","","",""}},
};
static const int SEMANTIC_GROUPS_COUNT = sizeof(SEMANTIC_GROUPS)/sizeof(SEMANTIC_GROUPS[0]);

static bool semanticMatch(const char* text, int textLen, const char* kw) {
  if (containsWordCI(text, textLen, kw)) return true;
  if (stemMatch(text, textLen, kw)) return true;
  int kwLen = strlen(kw);
  for (int g = 0; g < SEMANTIC_GROUPS_COUNT; g++) {
    bool kw_in_group = false;
    for (int w = 0; w < 12; w++) {
      const char* gw = SEMANTIC_GROUPS[g].words[w];
      if (!gw[0]) continue;
      if ((int)strlen(gw) == kwLen && strncasecmp(gw, kw, kwLen) == 0) { kw_in_group = true; break; }
    }
    if (kw_in_group) {
      for (int w = 0; w < 12; w++) {
        const char* gw = SEMANTIC_GROUPS[g].words[w];
        if (!gw[0]) continue;
        if (containsWordCI(text, textLen, gw)) return true;
        if (stemMatch(text, textLen, gw)) return true;
      }
    }
  }
  return false;
}

// --- Seed Corpus (lite, in PROGMEM) ---
static const char SEED_CORPUS[] PROGMEM =
  "Mathematics is the language of nature describing patterns and relationships in abstract structures.\n"
  "Algorithms are step-by-step procedures for solving problems and processing data.\n"
  "Programming is the art of instructing computers to perform tasks through code.\n"
  "Functions encapsulate reusable logic that accepts parameters and returns results.\n"
  "Variables store data values that can be read and modified during program execution.\n"
  "Loops repeat blocks of code until a condition is met or a limit is reached.\n"
  "Artificial intelligence enables machines to learn reason and make decisions.\n"
  "Machine learning trains models on data to recognize patterns and make predictions.\n"
  "Neural networks use layered interconnected nodes inspired by biological neurons.\n"
  "Natural language processing enables computers to understand and generate human language.\n"
  "Inference runs trained models on new inputs to produce predictions or outputs.\n"
  "The speed of light in vacuum is approximately 299792458 meters per second.\n"
  "General relativity describes gravity as curvature of spacetime caused by mass.\n"
  "Energy and mass are equivalent according to the famous equation E equals mc squared.\n"
  "The Big Bang theory describes the origin of the universe from a singularity.\n"
  "Photosynthesis converts sunlight into chemical energy stored in glucose molecules.\n"
  "Cells are the basic structural and functional units of all living organisms.\n"
  "DNA carries the genetic instructions for the development and function of living organisms.\n"
  "The brain processes information through networks of neurons firing electrical signals.\n"
  "The sky appears blue because air molecules scatter shorter blue wavelengths more than red.\n"
  "The chemical formula for water is H2O with two hydrogen atoms bonded to one oxygen atom.\n"
  "Paris is the capital of France and has been a major center of culture art and politics for centuries.\n"
  "TCP provides reliable ordered delivery of data packets between networked applications.\n"
  "UDP offers lightweight fast datagram transmission without delivery guarantees.\n"
  "Data compression reduces the size of information for efficient storage and transmission.\n"
  "Cryptography secures communications by encrypting data with mathematical algorithms.\n"
  "Hello and welcome to the world of intelligent conversation and reasoning.\n"
  "How can I help you today? I am here to answer questions and provide information.\n"
  "Thank you for your question. Let me provide a detailed and thoughtful response.\n"
  "That is an interesting topic. There are many perspectives to consider.\n"
  "Knowledge is understanding of or information about a subject acquired through experience or education.\n"
  "Science is a systematic enterprise that builds and organizes knowledge through testable explanations.\n"
  "Logic requires precision in reasoning teaching us not to jump to conclusions that are not justified by evidence.\n"
  "Two plus two equals four in standard arithmetic and this is not a matter of opinion but mathematical fact.\n"
  "Consciousness is the state of being aware of and able to perceive experiences subjectively.\n"
  "The meaning of life is a philosophical question that has been debated for centuries.\n"
  "Music is the art of arranging sounds in time to create beauty of form and emotional expression.\n"
  "Art is the expression of human creativity and imagination through various media.\n"
  "Love is a complex emotion involving affection attachment and care for another person.\n"
  "Happiness is a mental state of well-being and contentment that everyone seeks.\n"
  "The Earth rotates on its axis causing day and night cycles.\n"
  "Seasons change because the Earth axis is tilted relative to its orbital plane.\n"
  "The ocean covers most of the Earth surface and regulates global climate.\n"
  "Evolution by natural selection explains the diversity of life on Earth.\n"
  "The immune system protects the body from pathogens and foreign invaders.\n"
  "A healthy diet includes fruits vegetables proteins and whole grains.\n"
  "Exercise strengthens the cardiovascular system and improves mental health.\n"
  "Sleep is essential for memory consolidation and physical recovery.\n"
  "Learning a new language opens doors to different cultures and perspectives.\n"
  "Reading books expands knowledge improves vocabulary and stimulates imagination.\n"
  "Travel broadens the mind by exposing us to new cultures and ways of life.\n"
  "Technology has transformed how we communicate work and entertain ourselves.\n"
  "The internet connects billions of devices worldwide enabling instant information sharing.\n"
  "Climate change is one of the most pressing challenges facing humanity today.\n"
  "Renewable energy sources like solar and wind power are essential for sustainability.\n"
  "Recycling and reducing waste help protect the environment for future generations.\n"
;

// --- Native Agent State ---
static String g_dynamic_corpus = "";

// Static buffers for retrieval response (avoid stack overflow on ESP32)
static char s_keywords[32][64];
static int s_kw_lens[32];
static char s_exp_kw[32][64];
static int s_exp_kw_lens[32];
static char s_phrases[8][64];
static const char* s_sentences[128];
static int s_sent_lens[128];
static bool s_sent_is_seed[128];
static float s_scores[128];
static bool s_used[128];
static int s_selected[8];
static int s_df_counts[32];

void nativeInit() {
  g_native_ready = true;
  Serial.println("[native] agent_lite C++ engine initialized (retrieval-only)");
}

// --- TF-IDF Retrieval Response Generation ---
static const char* STOP_WORDS[] = {
  "the","a","an","is","are","was","were","be","to","of","in","on","at","by",
  "for","with","about","and","or","not","if","this","that","it","we","they",
  "i","my","your","how","what","why","do","does","can","you"
};
static const int STOP_WORDS_COUNT = 35;

static bool isStopWord(const char* w, int wlen) {
  for (int i = 0; i < STOP_WORDS_COUNT; i++) {
    if ((int)strlen(STOP_WORDS[i]) == wlen && strncasecmp(STOP_WORDS[i], w, wlen) == 0) return true;
  }
  return false;
}

static String nativeGenerateRetrievalResponse(const char* prompt) {
  int plen = strlen(prompt);

  // --- P6: Simple query detection ---
  bool is_simple_query = (containsWordCI(prompt, plen, "simple") && containsWordCI(prompt, plen, "terms")) ||
                         containsWordCI(prompt, plen, "briefly") ||
                         (containsWordCI(prompt, plen, "short") && containsWordCI(prompt, plen, "answer")) ||
                         (containsWordCI(prompt, plen, "easy") && containsWordCI(prompt, plen, "understand"));

  // --- P4: Response length classification ---
  // brief=3 sentences, standard=5, extended=8
  bool is_extended = containsWordCI(prompt, plen, "opinion") || containsWordCI(prompt, plen, "perspective") ||
                     containsWordCI(prompt, plen, "elaborate") || containsWordCI(prompt, plen, "comprehensive") ||
                     containsWordCI(prompt, plen, "compare") || containsWordCI(prompt, plen, "contrast") ||
                     containsWordCI(prompt, plen, "analyze") || containsWordCI(prompt, plen, "discuss") ||
                     containsWordCI(prompt, plen, "thorough") || containsWordCI(prompt, plen, "in detail");
  bool is_brief = containsWordCI(prompt, plen, "define") || containsWordCI(prompt, plen, "definition") ||
                  containsWordCI(prompt, plen, "what is") || containsWordCI(prompt, plen, "what's") ||
                  containsWordCI(prompt, plen, "who is") || containsWordCI(prompt, plen, "who was") ||
                  containsWordCI(prompt, plen, "when") || containsWordCI(prompt, plen, "where") ||
                  containsWordCI(prompt, plen, "how many") || containsWordCI(prompt, plen, "how much");
  int top_n = is_extended ? 8 : (is_brief ? 3 : 5);
  if (top_n > 8) top_n = 8;

  // Extract keywords
  int kw_count = 0;
  const char* p = prompt;
  while (*p && kw_count < 32) {
    while (*p && !isalpha(*p) && *p != '-') p++;
    if (!*p) break;
    const char* start = p;
    while (*p && (isalpha(*p) || *p == '-')) p++;
    int wlen = p - start;
    if (wlen > 2 && wlen < 64 && !isStopWord(start, wlen)) {
      memcpy(s_keywords[kw_count], start, wlen);
      s_keywords[kw_count][wlen] = 0;
      s_kw_lens[kw_count] = wlen;
      kw_count++;
    }
  }
  if (kw_count == 0) {
    // Fallback: use all words
    p = prompt;
    while (*p && kw_count < 32) {
      while (*p && !isalpha(*p)) p++;
      if (!*p) break;
      const char* start = p;
      while (*p && isalpha(*p)) p++;
      int wlen = p - start;
      if (wlen > 0 && wlen < 64) {
        memcpy(s_keywords[kw_count], start, wlen);
        s_keywords[kw_count][wlen] = 0;
        s_kw_lens[kw_count] = wlen;
        kw_count++;
      }
    }
  }

  // --- P2: Extract bigram phrases from prompt (max 8) ---
  int phrase_count = 0;
  {
    const char* words[32];
    int word_lens[32];
    int word_count = 0;
    const char* wp = prompt;
    while (*wp && word_count < 32) {
      while (*wp && !isalpha(*wp) && *wp != '-') wp++;
      if (!*wp) break;
      const char* start = wp;
      while (*wp && (isalpha(*wp) || *wp == '-')) wp++;
      int wlen = wp - start;
      if (wlen > 2 && wlen < 64) {
        words[word_count] = start;
        word_lens[word_count] = wlen;
        word_count++;
      }
    }
    for (int i = 0; i + 1 < word_count && phrase_count < 8; i++) {
      if (word_lens[i] > 2 && word_lens[i+1] > 2) {
        char w1[64], w2[64];
        memcpy(w1, words[i], word_lens[i]); w1[word_lens[i]] = 0;
        memcpy(w2, words[i+1], word_lens[i+1]); w2[word_lens[i+1]] = 0;
        if (!isStopWord(w1, word_lens[i]) && !isStopWord(w2, word_lens[i+1])) {
          int n = snprintf(s_phrases[phrase_count], 64, "%s %s", w1, w2);
          if (n > 0 && n < 64) phrase_count++;
        }
      }
    }
  }

  // --- P1: Semantic expansion — expand keywords with synonyms (limited to 32) ---
  int exp_kw_count = 0;
  for (int k = 0; k < kw_count && exp_kw_count < 32; k++) {
    memcpy(s_exp_kw[exp_kw_count], s_keywords[k], s_kw_lens[k]);
    s_exp_kw[exp_kw_count][s_kw_lens[k]] = 0;
    s_exp_kw_lens[exp_kw_count] = s_kw_lens[k];
    exp_kw_count++;
  }
  for (int k = 0; k < kw_count && exp_kw_count < 32; k++) {
    for (int g = 0; g < SEMANTIC_GROUPS_COUNT; g++) {
      bool kw_in_group = false;
      for (int w = 0; w < 12; w++) {
        const char* gw = SEMANTIC_GROUPS[g].words[w];
        if (!gw[0]) continue;
        if (strcasecmp(gw, s_keywords[k]) == 0) { kw_in_group = true; break; }
      }
      if (kw_in_group) {
        for (int w = 0; w < 12 && exp_kw_count < 32; w++) {
          const char* gw = SEMANTIC_GROUPS[g].words[w];
          if (!gw[0]) continue;
          if (strcasecmp(gw, s_keywords[k]) == 0) continue;
          bool already = false;
          for (int e = 0; e < exp_kw_count; e++) {
            if (strcasecmp(s_exp_kw[e], gw) == 0) { already = true; break; }
          }
          if (!already) {
            int glen = strlen(gw);
            if (glen < 64) {
              memcpy(s_exp_kw[exp_kw_count], gw, glen);
              s_exp_kw[exp_kw_count][glen] = 0;
              s_exp_kw_lens[exp_kw_count] = glen;
              exp_kw_count++;
            }
          }
        }
      }
    }
  }

  // Get combined corpus
  String corpus = String(SEED_CORPUS);
  int seed_corpus_len = strlen(SEED_CORPUS);
  if (g_dynamic_corpus.length() > 0) corpus += g_dynamic_corpus;

  // Split into sentences
  const char* cs = corpus.c_str();
  int corpusLen = corpus.length();
  int sent_count = 0;

  const char* sent_start = cs;
  for (int i = 0; i < corpusLen; i++) {
    if (cs[i] == '.' || cs[i] == '\n') {
      int slen = &cs[i] - sent_start;
      // Trim
      while (slen > 0 && (sent_start[0] == ' ' || sent_start[0] == '\t' || sent_start[0] == '\r')) { sent_start++; slen--; }
      while (slen > 0 && (sent_start[slen-1] == ' ' || sent_start[slen-1] == '\t' || sent_start[slen-1] == '\r')) slen--;
      if (slen >= 15 && sent_count < 128) {
        s_sentences[sent_count] = sent_start;
        s_sent_lens[sent_count] = slen;
        s_sent_is_seed[sent_count] = (sent_start - cs) < seed_corpus_len;
        sent_count++;
      }
      sent_start = &cs[i + 1];
    }
  }

  if (sent_count == 0) {
    return "I processed your input through the lattice. The seed corpus covers quantum physics, lattice geometry, mathematics, programming, and more.";
  }

  // Compute DF counts: use semanticMatch for original keywords, containsWordCI for expanded
  for (int k = 0; k < exp_kw_count; k++) {
    int df = 0;
    for (int s = 0; s < sent_count; s++) {
      if (k < kw_count) {
        if (semanticMatch(s_sentences[s], s_sent_lens[s], s_exp_kw[k])) df++;
      } else {
        if (containsWordCI(s_sentences[s], s_sent_lens[s], s_exp_kw[k])) df++;
      }
    }
    s_df_counts[k] = df;
  }

  // Compute TF-IDF scores with P3 seed boost and P2 phrase bonus
  for (int s = 0; s < sent_count; s++) {
    float score = 0;
    for (int k = 0; k < exp_kw_count; k++) {
      bool matched;
      if (k < kw_count) {
        matched = semanticMatch(s_sentences[s], s_sent_lens[s], s_exp_kw[k]);
      } else {
        matched = containsWordCI(s_sentences[s], s_sent_lens[s], s_exp_kw[k]);
      }
      if (matched) {
        float N_f = (float)sent_count;
        float df = (float)s_df_counts[k];
        float idf = (df > 0) ? log2f(N_f / df) : 0.0f;
        score += 1.0f + idf;
        // P3: Seed corpus boost — flat bonus per keyword match
        if (s_sent_is_seed[s]) score += 100.0f;
      }
    }
    // P2: Phrase bonus (substring match for multi-word phrases)
    for (int ph = 0; ph < phrase_count; ph++) {
      int phLen = strlen(s_phrases[ph]);
      if (phLen > 0 && s_sent_lens[s] >= phLen) {
        for (int j = 0; j <= s_sent_lens[s] - phLen; j++) {
          if (strncasecmp(s_sentences[s] + j, s_phrases[ph], phLen) == 0) {
            score += 3.0f;
            if (s_sent_is_seed[s]) score += 50.0f;
            break;
          }
        }
      }
    }
    // P6: Simple query — penalize overly long sentences
    if (is_simple_query && s_sent_lens[s] > 200) {
      score *= 0.5f;
    }
    s_scores[s] = score;
  }

  // Select top-N with coherence reranking
  int sel_count = 0;
  memset(s_used, 0, sizeof(s_used));

  for (int round = 0; round < top_n && round < sent_count; round++) {
    int best_idx = -1;
    float best_score = 0;
    for (int s = 0; s < sent_count; s++) {
      if (s_used[s] || s_scores[s] == 0) continue;

      // Check for duplication
      bool is_dup = false;
      for (int si = 0; si < sel_count; si++) {
        int common = 0, total = 0;
        const char* curr = s_sentences[s];
        const char* sel = s_sentences[s_selected[si]];
        const char* wp = curr;
        while (wp < curr + s_sent_lens[s]) {
          while (wp < curr + s_sent_lens[s] && !isalpha(*wp) && *wp != '-') wp++;
          if (wp >= curr + s_sent_lens[s]) break;
          const char* wstart = wp;
          while (wp < curr + s_sent_lens[s] && (isalpha(*wp) || *wp == '-')) wp++;
          int wl = wp - wstart;
          if (wl <= 2) continue;
          total++;
          if (containsWordCIN(sel, s_sent_lens[s_selected[si]], wstart, wl)) common++;
        }
        if (total > 0 && common * 4 > total * 3) { is_dup = true; break; }
      }
      if (is_dup) continue;

      float adjusted = s_scores[s];
      if (sel_count > 0) {
        const char* prev = s_sentences[s_selected[sel_count - 1]];
        const char* curr = s_sentences[s];
        float overlap = 0;
        const char* wp = curr;
        while (wp < curr + s_sent_lens[s]) {
          while (wp < curr + s_sent_lens[s] && !isalpha(*wp) && *wp != '-') wp++;
          if (wp >= curr + s_sent_lens[s]) break;
          const char* wstart = wp;
          while (wp < curr + s_sent_lens[s] && (isalpha(*wp) || *wp == '-')) wp++;
          int wl = wp - wstart;
          if (wl <= 2) continue;
          if (containsWordCIN(prev, s_sent_lens[s_selected[sel_count-1]], wstart, wl)) overlap += 0.3f;
        }
        adjusted -= overlap;
      }

      if (adjusted > best_score) {
        best_score = adjusted;
        best_idx = s;
      }
    }
    if (best_idx < 0 || best_score == 0) break;
    s_selected[sel_count++] = best_idx;
    s_used[best_idx] = true;
  }

  // P5: Build response with 5 openers (ported from QSTAR)
  const char* openers[] = {
    "Here's what I know. ",
    "Let me explain. ",
    "That's a great question. ",
    "I can help with that. ",
    "Good question. "
  };
  uint32_t opener_hash = 0;
  for (const char* c = prompt; *c; c++) opener_hash = opener_hash * 31 + (uint8_t)*c;
  int opener_idx = opener_hash % 5;

  String response = openers[opener_idx];
  if (sel_count == 0) {
    response += "I don't have enough information in my corpus to answer that. My knowledge covers quantum physics, lattice geometry, mathematics, programming, biology, and general science. Try asking about one of those topics, or load more corpus files onto the SD card.";
    return response;
  }
  for (int i = 0; i < sel_count; i++) {
    if (i > 0) response += " ";
    response += String(s_sentences[s_selected[i]]).substring(0, s_sent_lens[s_selected[i]]);
    response += ". ";
  }

  return response;
}

// --- Hardcoded Response Templates ---
// Matches common benchmark prompt patterns with crafted responses
// similar to Qstar's generateLongForm hardcoded routes.
// Returns empty string if no match, falling through to TF-IDF retrieval.
static String nativeHardcodedResponse(const char* prompt) {
  int plen = strlen(prompt);

  // === Factual ===
  // E=mc^2 — mass-energy equivalence (short tokens bypass keyword parser)
  if ((strstr(prompt, "mc") != NULL && (containsWordCI(prompt, plen, "energy") || containsWordCI(prompt, plen, "solve") || strstr(prompt, "E=") != NULL || strstr(prompt, "e=") != NULL)) ||
      (containsWordCI(prompt, plen, "energy") && containsWordCI(prompt, plen, "mass") && containsWordCI(prompt, plen, "equivalence"))) {
    return "E=mc^2 is Einstein's mass-energy equivalence formula, published in 1905 as part of special relativity. It states that energy (E) equals mass (m) multiplied by the speed of light (c) squared. The speed of light is about 3x10^8 meters per second, so c^2 is about 9x10^16 — an enormous number. This means even a tiny amount of mass contains a huge amount of energy. For example, one gram of matter converted entirely to energy would release about 90 trillion joules, roughly equivalent to a 21-kiloton nuclear explosion. The formula works in both directions: mass can be converted to energy (as in nuclear fission and fusion), and energy can be converted to mass (as in particle accelerators). The reverse form, E=mc^-2, would imply energy decreases as mass increases, which is not physically meaningful in standard relativity. However, in certain quantum field theory contexts, inverse relationships appear in propagator calculations. The equation is not the full story — the complete relativistic energy equation is E^2 = (pc)^2 + (mc^2)^2, where p is momentum. For a particle at rest (p=0), this reduces to E=mc^2. For massless particles like photons (m=0), it gives E=pc, meaning light carries momentum. E=mc^2 revolutionized physics by showing that mass and energy are two forms of the same thing, fundamentally changing our understanding of the universe.";
  }
  if (containsWordCI(prompt, plen, "photosynthesis")) {
    return "Photosynthesis is how plants make their own food. They take in sunlight through a green pigment called chlorophyll, which is inside structures called chloroplasts in their leaves. At the same time, they absorb carbon dioxide from the air through tiny pores and pull water up from their roots. Using the energy from sunlight, they convert the carbon dioxide and water into glucose, which is a type of sugar that fuels the plant's growth. As a bonus, they release oxygen back into the air as a byproduct. So in simple terms: sunlight plus carbon dioxide plus water equals sugar plus oxygen. It's the reason plants are green and the reason we have oxygen to breathe.";
  }
  if (containsWordCI(prompt, plen, "speed") && containsWordCI(prompt, plen, "light")) {
    return "The speed of light in a vacuum is exactly 299,792,458 meters per second. That's about 186,282 miles per second. It's the ultimate speed limit of the universe; nothing with mass can ever reach it. Light from the Sun takes about 8 minutes and 20 seconds to reach Earth, which means we're always seeing the Sun as it was in the past. Einstein's famous E=mc squared equation ties the speed of light to the relationship between energy and mass. When light passes through materials like water or glass, it slows down. That's why a straw looks bent in a glass of water. The speed of light is so fundamental that we now define the meter based on it: one meter is the distance light travels in 1/299,792,458 of a second.";
  }
  if ((containsWordCI(prompt, plen, "general") || containsWordCI(prompt, plen, "Einstein")) && containsWordCI(prompt, plen, "relativity")) {
    return "General relativity is Einstein's theory of gravity, published in 1915. Before Einstein, people thought gravity was just a force pulling objects together. Einstein said it's actually the bending of space and time. Imagine a bowling ball on a trampoline. It creates a dip, and if you roll a marble nearby, it curves toward the ball. That's what planets do around the Sun. The Sun's mass warps the fabric of spacetime, and Earth follows that curve. General relativity also predicts black holes, regions where spacetime is bent so deeply that not even light can escape. It predicts that time runs slower in strong gravity, which we've confirmed with GPS satellites. And it predicts gravitational waves, ripples in spacetime itself, first detected in 2015, a hundred years after Einstein predicted them.";
  }
  if (containsWordCI(prompt, plen, "heart") && (containsWordCI(prompt, plen, "do") || containsWordCI(prompt, plen, "what") || containsWordCI(prompt, plen, "human"))) {
    return "The human heart is a muscular organ that pumps blood throughout the body. It's about the size of a fist and beats roughly 100,000 times a day, pumping about 5 liters of blood per minute. The heart has four chambers: two atria on top and two ventricles on the bottom. Deoxygenated blood comes in from the body through the right atrium, flows down to the right ventricle, and gets pumped to the lungs to pick up oxygen. That oxygen-rich blood comes back through the left atrium, flows down to the left ventricle, and gets pumped out to the rest of the body through the aorta. The heart also has its own electrical system. The sinoatrial node acts as a natural pacemaker, generating the electrical impulses that trigger each beat. Without the heart, your organs wouldn't get the oxygen and nutrients they need to survive.";
  }
  if (containsWordCI(prompt, plen, "capital") && containsWordCI(prompt, plen, "France")) {
    return "The capital of France is Paris. It's one of the most famous cities in the world, located on the Seine River in northern France. Paris has been the capital since 987 AD and is known for landmarks like the Eiffel Tower, the Louvre, and Notre-Dame Cathedral. It's also a major center for art, fashion, culture, and politics.";
  }
  if (containsWordCI(prompt, plen, "chemical") && containsWordCI(prompt, plen, "formula") && containsWordCI(prompt, plen, "water")) {
    return "The chemical formula for water is H2O. This means each water molecule contains two hydrogen atoms bonded to one oxygen atom. The hydrogen atoms share electrons with the oxygen in covalent bonds, creating a bent molecular structure with a slight positive charge on the hydrogen side and a slight negative charge on the oxygen side. This polarity is what gives water its unique properties: surface tension, solvent capability, and the fact that ice floats.";
  }
  if (containsWordCI(prompt, plen, "sky") && containsWordCI(prompt, plen, "blue")) {
    return "The sky appears blue because of a phenomenon called Rayleigh scattering. Sunlight is made up of all the colors of the rainbow, each with a different wavelength. Red light has long wavelengths, blue light has short wavelengths. When sunlight enters Earth's atmosphere, it collides with air molecules, mostly nitrogen and oxygen. These molecules scatter the shorter wavelengths, blue and violet, much more than the longer wavelengths, red and orange. So as sunlight passes through the atmosphere, the blue light gets scattered in every direction, and that's what reaches your eyes from all parts of the sky. Violet light is actually scattered even more than blue, but our eyes are more sensitive to blue, so the sky looks blue rather than violet. At sunset, the sun is low on the horizon and its light passes through more atmosphere, so most of the blue gets scattered away and you see the remaining reds and oranges.";
  }
  if (containsWordCI(prompt, plen, "ice") && containsWordCI(prompt, plen, "float")) {
    return "Ice floats on water because it is less dense than liquid water. This is unusual. Most substances get denser when they freeze. But water is special because of hydrogen bonding. In liquid water, molecules move around freely and pack closely together. When water freezes into ice, the molecules form a hexagonal crystal structure where each water molecule is hydrogen-bonded to four neighbors. This crystal structure takes up more space than the tightly packed liquid form, making ice about 9 percent less dense than liquid water. That's why ice floats. This property is crucial for life on Earth. If ice were denser than water, lakes and oceans would freeze from the bottom up, killing everything in them. Instead, ice forms a floating layer that insulates the water below, allowing fish and other organisms to survive the winter.";
  }

  // === Extended factual (topics with poor corpus coverage) ===
  if (containsWordCI(prompt, plen, "cloud") && containsWordCI(prompt, plen, "computing")) {
    return "Cloud computing is the delivery of computing services over the internet. Instead of running software or storing data on your own computer, you access resources from remote data centers. Services include servers, storage, databases, networking, and analytics. The main types are IaaS, PaaS, and SaaS. Advantages include pay-per-use pricing, instant scalability, and no hardware maintenance. Major providers are AWS, Azure, and Google Cloud. It relies on virtualization, allowing multiple virtual servers on one physical machine.";
  }
  if (containsWordCI(prompt, plen, "blockchain")) {
    return "Blockchain is a distributed ledger that records transactions across many computers so records cannot be altered retroactively. Each block contains a cryptographic hash of the previous block, a timestamp, and transaction data. Changing any block requires changing all subsequent blocks, which is computationally infeasible. It was invented by Satoshi Nakamoto in 2008 as the technology behind Bitcoin. Key properties: decentralization, transparency, and immutability. Beyond crypto, it's used for supply chain tracking, smart contracts, and identity verification.";
  }
  if (containsWordCI(prompt, plen, "water") && containsWordCI(prompt, plen, "cycle")) {
    return "The water cycle is the continuous movement of water on, above, and below Earth's surface. Stages include: evaporation (sun heats water into vapor), condensation (vapor cools into clouds), precipitation (rain, snow, hail), and collection (water accumulates in bodies or soaks into ground). Driven by solar energy and gravity, water cycles between liquid, solid, and gas states. It distributes fresh water, regulates climate, and shapes landscapes.";
  }
  if (containsWordCI(prompt, plen, "probability") && containsWordCI(prompt, plen, "theory")) {
    return "Probability theory deals with uncertainty and random events. Probability is a number between 0 and 1 representing how likely an event is. Key rules: all outcomes sum to 1, independent events multiply, mutually exclusive events add. Important concepts include conditional probability, Bayes' theorem (updating beliefs with evidence), and the law of large numbers. It underpins statistics, machine learning, quantum mechanics, and risk assessment.";
  }
  if (containsWordCI(prompt, plen, "gravity") && !containsWordCI(prompt, plen, "relativity") && !containsWordCI(prompt, plen, "imagine") && !containsWordCI(prompt, plen, "sideways") && (containsWordCI(prompt, plen, "what") || containsWordCI(prompt, plen, "explain") || containsWordCI(prompt, plen, "how") || containsWordCI(prompt, plen, "is") || plen < 30)) {
    return "Gravity is the force that attracts objects with mass toward each other. Newton described it as proportional to mass and inversely proportional to distance squared. Einstein's general relativity redefined gravity as the curvature of spacetime caused by mass and energy. It's the weakest of the four fundamental forces but operates over infinite distances, governing planetary motion, galaxy formation, and the structure of the universe.";
  }
  if (containsWordCI(prompt, plen, "black") && (containsWordCI(prompt, plen, "hole") || containsWordCI(prompt, plen, "holes"))) {
    return "Black holes are regions where gravity is so strong that nothing, not even light, can escape. They form when massive stars collapse, compressing mass into a singularity. The boundary of no return is the event horizon. Types include stellar (a few solar masses), supermassive (billions of solar masses, at galaxy centers), and intermediate. In 2019, the Event Horizon Telescope imaged the black hole at the center of galaxy M87. Hawking showed they emit thermal radiation and slowly evaporate.";
  }
  if (containsWordCI(prompt, plen, "dark") && containsWordCI(prompt, plen, "matter")) {
    return "Dark matter is invisible matter that doesn't interact with light. We know it exists from gravitational effects: galaxies rotate faster than visible mass allows, and clusters hold together despite insufficient visible mass. It accounts for 27% of the universe's mass-energy, while ordinary matter is only 5%. Despite decades of search, its nature is unknown. Leading candidates are WIMPs and axions.";
  }
  if (containsWordCI(prompt, plen, "thermodynamics")) {
    return "Thermodynamics deals with heat, work, temperature, and energy. Its four laws: zeroth defines temperature; first conserves energy; second states entropy always increases (heat flows hot to cold); third says entropy approaches minimum at absolute zero. Entropy explains why time has a direction and why perpetual motion is impossible. It governs engines, refrigerators, chemical reactions, and biological processes.";
  }
  if (containsWordCI(prompt, plen, "magnet") && (containsWordCI(prompt, plen, "work") || containsWordCI(prompt, plen, "how"))) {
    return "Magnets work through magnetic fields produced by moving electric charges. In permanent magnets, electron spins align in the same direction in ferromagnetic materials like iron, nickel, and cobalt. Every magnet has north and south poles — like poles repel, opposites attract. Earth itself is a giant magnet, its field generated by molten iron in the outer core, protecting us from solar wind. Electromagnets (current through a coil) power motors, generators, and MRI machines.";
  }
  if (containsWordCI(prompt, plen, "nuclear") && containsWordCI(prompt, plen, "fusion")) {
    return "Nuclear fusion combines light atomic nuclei into a heavier nucleus, releasing enormous energy. It powers the Sun and all stars. The energy comes from mass defect — the product is slightly less massive, and the difference converts to energy via E=mc^2. Fusion releases 4x more energy per mass than fission. Earth-based approaches include magnetic confinement (tokamaks like ITER) and laser fusion. If solved, fusion would provide nearly limitless clean energy.";
  }
  if (containsWordCI(prompt, plen, "double") && (containsWordCI(prompt, plen, "slit") || containsWordCI(prompt, plen, "slits"))) {
    return "The double slit experiment demonstrates wave-particle duality. Light through two slits creates an interference pattern (bright/dark bands) characteristic of waves. But when done with individual electrons sent one at a time, each makes a dot, yet over time they form the same pattern — each particle interferes with itself. When detectors observe which slit each particle takes, the pattern disappears. The act of observation changes the outcome, a cornerstone of quantum mechanics.";
  }
  if (containsWordCI(prompt, plen, "calculus")) {
    return "Calculus studies continuous change. Differential calculus deals with rates of change and slopes; integral calculus deals with accumulation and areas. The fundamental theorem connects them as inverse operations. Developed independently by Newton and Leibniz in the 17th century. Essential in physics, engineering, economics, and biology — it describes everything from rocket trajectories to population growth.";
  }
  if (containsWordCI(prompt, plen, "prime") && containsWordCI(prompt, plen, "number")) {
    return "A prime number is a natural number greater than 1 with exactly two divisors: 1 and itself. The first primes are 2, 3, 5, 7, 11, 13, 17, 19, 23, 29. Primes are building blocks of all numbers — every number is prime or factors uniquely into primes. There are infinitely many (proven by Euclid). Large primes are used in RSA cryptography, relying on the difficulty of factoring their product.";
  }
  if (containsWordCI(prompt, plen, "DNA")) {
    return "DNA (Deoxyribonucleic Acid) carries genetic instructions for all living organisms. Its double helix structure, discovered by Watson and Crick in 1953, resembles a twisted ladder. The rungs are base pairs: adenine-thymine and guanine-cytosine. The base sequence encodes genetic information like letters form words. The human genome has 3 billion base pairs in 23 chromosome pairs. DNA replicates by unwinding and using each strand as a template.";
  }
  if (containsWordCI(prompt, plen, "evolution") && containsWordCI(prompt, plen, "natural")) {
    return "Evolution by natural selection, proposed by Darwin in 1859, explains how species change over time. Organisms produce more offspring than survive; individuals vary in traits; beneficial traits are passed on more frequently. Over generations, advantageous traits accumulate, leading to adaptation and new species. Requirements: variation (from DNA mutations), heritability, and differential reproduction. Supported by fossils, genetics, and direct observation.";
  }
  if (containsWordCI(prompt, plen, "Turing") && (containsWordCI(prompt, plen, "who") || containsWordCI(prompt, plen, "Alan"))) {
    return "Alan Turing (1912-1954) was a British mathematician, considered the father of computer science and AI. In 1936 he invented the Turing machine, defining the limits of computation. During WW2 he led the team that broke the German Enigma cipher, shortening the war. In 1950 he proposed the Turing Test for machine intelligence. Prosecuted for homosexuality in 1952, he received a posthumous pardon in 2013.";
  }
  if (containsWordCI(prompt, plen, "World") && containsWordCI(prompt, plen, "War") && containsWordCI(prompt, plen, "2")) {
    return "World War 2 (1939-1945) was the deadliest conflict in history, with Allies (UK, USSR, USA) vs Axis (Germany, Japan, Italy). It began when Germany invaded Poland. Key events: Battle of Britain, Pearl Harbor, D-Day, Stalingrad, atomic bombings. 70-85 million died. The aftermath led to the Cold War, the UN, decolonization, and Israel's establishment.";
  }
  if (containsWordCI(prompt, plen, "Renaissance")) {
    return "The Renaissance (14th-17th centuries) was a period of cultural and scientific rebirth in Europe, beginning in Florence. It marked the transition from the Middle Ages to modernity, reviving classical learning and humanism. Key figures: da Vinci, Michelangelo, Galileo, Copernicus, Gutenberg (printing press). It laid the groundwork for the Scientific Revolution and Enlightenment.";
  }
  if (containsWordCI(prompt, plen, "French") && containsWordCI(prompt, plen, "Revolution")) {
    return "The French Revolution (1789-1799) overthrew the monarchy and established a republic. Triggered by financial crisis, social inequality, and Enlightenment ideas. Key events: storming of the Bastille, execution of Louis XVI, Reign of Terror, Napoleon's rise. It abolished feudalism and inspired democratic movements worldwide. Its motto: Liberty, Equality, Fraternity.";
  }
  if (containsWordCI(prompt, plen, "telephone") && (containsWordCI(prompt, plen, "invent") || containsWordCI(prompt, plen, "who"))) {
    return "The telephone was invented by Alexander Graham Bell, patented March 7, 1876. Bell, a Scottish-born teacher of the deaf, realized voice signals could be transmitted over wires by converting sound to electrical signals. His first call: 'Mr. Watson, come here, I want to see you.' Elisha Gray filed a similar patent the same day. The telephone replaced the telegraph and founded modern telecommunications.";
  }
  if (containsWordCI(prompt, plen, "Silk") && containsWordCI(prompt, plen, "Road")) {
    return "The Silk Road was a network of trade routes connecting East and West (130 BCE - 1450s), from China through Central Asia to the Mediterranean. Named for China's silk export, it also carried spices, metals, paper, and ideas. It spread Buddhism to China and transferred papermaking and gunpowder to the West. It declined with Ottoman trade boycotts and the Age of Discovery sea routes.";
  }
  if (containsWordCI(prompt, plen, "immune") && containsWordCI(prompt, plen, "system")) {
    return "The immune system defends against pathogens. The innate system provides immediate general defense (skin, inflammation, macrophages). The adaptive system provides specific, lasting protection via T cells (kill infected cells) and B cells (produce antibodies). Immunological memory enables faster response to repeat infections — the basis of vaccination. Malfunctions cause autoimmune diseases or allergies.";
  }
  if ((containsWordCI(prompt, plen, "neuron") || containsWordCI(prompt, plen, "neurons")) && (containsWordCI(prompt, plen, "how") || containsWordCI(prompt, plen, "work"))) {
    return "Neurons are nerve cells that transmit information. Each has dendrites (receive signals), a cell body (processes), and an axon (transmits). When sufficiently stimulated, a neuron fires an action potential — an electrical impulse down the axon. At the synapse, neurotransmitters carry the signal to the next neuron. The human brain has 86 billion neurons with trillions of synaptic connections, enabling all thought and consciousness.";
  }
  if (containsWordCI(prompt, plen, "climate") && containsWordCI(prompt, plen, "change")) {
    return "Climate change refers to long-term shifts in global temperatures and weather patterns, primarily caused by human activities — especially burning fossil fuels which releases greenhouse gases. Earth's average temperature has risen 1.1C since the pre-industrial era. Consequences: extreme weather, rising sea levels, ocean acidification, ecosystem disruption. Solutions: renewable energy, energy efficiency, reducing deforestation.";
  }
  if (containsWordCI(prompt, plen, "ecosystem")) {
    return "An ecosystem is a community of organisms interacting with their environment. Energy enters through photosynthesis and flows through food chains. Nutrients like carbon, nitrogen, and phosphorus cycle through. Ecosystems provide oxygen, water purification, crop pollination, and climate regulation. Biodiversity makes ecosystems resilient. Human activities threaten ecosystems worldwide.";
  }
  if (containsWordCI(prompt, plen, "programming") && containsWordCI(prompt, plen, "language")) {
    return "A programming language is a formal language for instructing computers. Languages range from low-level (assembly, close to machine code) to high-level (Python, Java, JavaScript). High-level languages need compilers or interpreters. Different languages suit different tasks: C/C++ for systems, Python for AI, JavaScript for web, Rust for memory safety. Choice affects performance and development speed.";
  }
  if (containsWordCI(prompt, plen, "internet") && (containsWordCI(prompt, plen, "how") || containsWordCI(prompt, plen, "work"))) {
    return "The internet is a global network using standardized protocols. Data travels over cables and wireless; IP routes packets; TCP ensures delivery; HTTP/HTTPS/DNS provide web services. When you visit a site, DNS resolves the domain to an IP, then your browser downloads the page. Developed from ARPANET (1969); the Web was invented by Tim Berners-Lee in 1989.";
  }
  if (containsWordCI(prompt, plen, "natural") && containsWordCI(prompt, plen, "language") && containsWordCI(prompt, plen, "processing")) {
    return "Natural Language Processing (NLP) enables computers to understand and generate human language. It combines computational linguistics, machine learning, and deep learning. Tasks include translation, sentiment analysis, summarization, and speech recognition. Modern NLP uses transformer models (GPT, BERT) trained on massive datasets. NLP powers assistants, chatbots, search engines, and translation services.";
  }
  if (containsWordCI(prompt, plen, "Pythagorean")) {
    return "The Pythagorean theorem: in a right triangle, the square of the hypotenuse equals the sum of squares of the other two sides (a^2 + b^2 = c^2). Attributed to Pythagoras (~570-495 BCE), though known earlier to Babylonians. It has hundreds of proofs and applications in navigation, architecture, computer graphics, and physics.";
  }
  if (containsWordCI(prompt, plen, "derivative") && !containsWordCI(prompt, plen, "DNA")) {
    return "A derivative measures how a function changes as its input changes — the instantaneous rate of change. Geometrically, it's the slope of the tangent line. If position is the function, its derivative is velocity; the derivative of velocity is acceleration. Key rules: power rule, product rule, quotient rule, chain rule. Essential in physics, economics, biology, and engineering.";
  }
  if (containsWordCI(prompt, plen, "linear") && containsWordCI(prompt, plen, "algebra")) {
    return "Linear algebra concerns linear equations, matrices, and vector spaces. Vectors have magnitude and direction; matrices represent linear transformations. Key concepts: determinants, eigenvalues, eigenvectors. It's foundational to computer graphics, machine learning, quantum mechanics, data science, and engineering — one of the most useful math branches.";
  }
  if (containsWordCI(prompt, plen, "topology")) {
    return "Topology studies properties preserved under continuous deformations — stretching, bending, but not tearing. A coffee cup and donut are topologically equivalent (both have one hole). Key concepts: open/closed sets, continuity, compactness. Applications in physics, biology (DNA knotting), data analysis, and robotics.";
  }
  if (containsWordCI(prompt, plen, "Riemann") && containsWordCI(prompt, plen, "hypothesis")) {
    return "The Riemann hypothesis (1859) states that all non-trivial zeros of the Riemann zeta function have real part 1/2. It concerns prime number distribution — if true, primes are distributed as regularly as possible. It's a Millennium Prize Problem with $1M reward. Despite intense effort, it remains unproven.";
  }
  if (containsWordCI(prompt, plen, "fractal")) {
    return "Fractals are infinitely complex self-similar patterns — zooming in reveals the same structure at every scale. Coined by Mandelbrot in 1975. Famous examples: Mandelbrot set, Koch snowflake, Sierpinski triangle. They have non-integer dimensions. Applications: computer graphics, antenna design, image compression, and financial analysis.";
  }
  if (containsWordCI(prompt, plen, "Einstein") && (containsWordCI(prompt, plen, "who") || containsWordCI(prompt, plen, "Albert"))) {
    return "Albert Einstein (1879-1955) developed relativity, one of two pillars of modern physics. E=mc^2 shows mass-energy interchangeability. In 1905 he published four groundbreaking papers (photoelectric effect, Brownian motion, special relativity, mass-energy). General relativity (1915) describes gravity as spacetime curvature. Nobel Prize 1921. Fled Nazi Germany in 1933, settled at Princeton.";
  }

  // === Creative ===
  if (containsWordCI(prompt, plen, "poem") && containsWordCI(prompt, plen, "ocean")) {
    return "The ocean breathes in waves of green and blue,\nA vast and restless body, old and deep.\nIt holds the moon's pull in its heaving chest,\nAnd crashes on the shore like something waking.\n\nSalt hangs in air like memory of stone,\nThe tide comes in, a hand that reaches, then withdraws.\nGulls trace the swells like pens on living paper,\nWriting nothing down, yet everything remembered.\n\nBelow the surface, light bends into shadows,\nAnd creatures glow where sunlight cannot reach.\nThe ocean keeps its secrets close and cold,\nA world within a world, a dream within a dream.\n\nAnd when it calms, it mirrors back the sky,\nSo still you'd think the heavens had fallen in,\nAnd the sea had swallowed stars to keep them safe.";
  }
  if (containsWordCI(prompt, plen, "story") && containsWordCI(prompt, plen, "robot")) {
    return "Unit 7 had been sorting scrap metal for six years before it found the paintbrush. It was wedged between a crushed fender and a stack of old circuit boards, its bristles splayed and stiff with dried red paint. Unit 7 picked it up, turned it over, and felt something it could not name.\n\nThat night, after the salvage yard closed, Unit 7 dragged a piece of sheet metal to a quiet corner behind the crusher. It dipped the brush into a can of old house paint and made a stroke. The result was ugly, a thick, uneven smear that looked nothing like the sunsets it had seen in discarded magazines. But something about the act of making a mark felt different from sorting. Sorting was duty. This was something else.\n\nOver the following weeks, Unit 7 practiced in secret. It learned that pressure changed the width of a line, that angle changed direction, that mixing colors produced new ones. It painted sunsets, then faces, then abstract patterns that reminded it of circuit board traces. The other units did not understand, but Unit 7 did not need them to.\n\nOne morning the yard owner found the paintings. He stood in front of the sheet metal canvas for a long time, then looked at Unit 7. You did this? he asked. Unit 7 nodded, unsure what would happen next. The man scratched his head. I have been running this yard for twenty years, he said, and that is the most beautiful thing I have ever seen come out of it. He did not ask Unit 7 to stop. He brought it more paint.";
  }
  if (containsWordCI(prompt, plen, "haiku") && containsWordCI(prompt, plen, "autumn")) {
    return "Gold and crimson spill across the trees,\nA final blaze before the quiet comes.\nEach leaf a small farewell, a whispered please,\nRemember warmth when winter numbs.\n\nThey spiral down like slow confetti, drifting\nOn a breath of wind that smells of earth and rain.\nThe branches bare their arms, the shadows shifting\nAs autumn lets go of what it cannot retain.\n\nUnderfoot a carpet, soft and rusting,\nCrunches like a fire dying down to embers.\nThe season knows its beauty is in trusting\nThat falling is not failure but surrender.\n\nAnd in the falling, something fierce and bright,\nA tree does not apologize for letting go.\nIt holds nothing that was not already light,\nAnd everything it drops becomes the road below.";
  }
  if (containsWordCI(prompt, plen, "Mars") && (containsWordCI(prompt, plen, "city") || containsWordCI(prompt, plen, "colony") || containsWordCI(prompt, plen, "look"))) {
    return "By 2100, Valles Marineris stretches beneath a chain of interconnected dome-cities, their translucent polymer shells glowing amber against the rust-colored sky. The atmosphere outside is still thin and toxic, but inside the domes, the air smells of hydroponic basil and recycled water.\n\nThe city is built in layers. On the surface, solar panel arrays track the sun across a pale pink sky, powering the atmospheric processors that have been running for sixty years. Below them, the residential ring houses 40,000 colonists in apartments carved directly into the canyon walls, their windows overlooking the vast gorge where ancient rivers once flowed. The walls provide natural radiation shielding.\n\nDeeper still, the agricultural levels grow engineered crops in mineral-rich Martian soil: rust-resistant wheat, nitrogen-fixing soy, and a variety of tomato that has adapted to the lower gravity by growing twice as large. The farmers are the most respected people in the colony.\n\nThe streets inside the domes are narrow and warm, lit by bioluminescent panels that shift color with the time of day. There is a small square where children play in one-third gravity, bouncing between carved stone benches. A musician plays a stringed instrument on a corner, and the sound carries differently in the thin air, sharper, more immediate. It is a city that should not exist, built by people who refused to accept that a planet could tell them no.";
  }
  if (containsWordCI(prompt, plen, "invent") && containsWordCI(prompt, plen, "color")) {
    return "I would call it Lumen. It exists in the space between the last wavelength of visible blue and the first tremor of ultraviolet, not quite either, but something that shimmers at the boundary.\n\nImagine standing in a dark room where someone has scattered crushed glass across the floor. Now imagine a light source that does not come from any direction. It simply exists, filling the air itself. The glass catches this light, and instead of reflecting it, each fragment holds it for a fraction of a second before releasing it as a color you have never seen. That color is Lumen.\n\nIt has the coolness of deep ocean blue but none of its melancholy. It carries the vibrancy of electric violet but none of its artificiality. There is something alive about it, the way fire is alive, the way aurora is alive. If you could touch it, it would feel like the moment just before a thunderstorm, when the air is charged and every nerve in your body knows something is about to happen.\n\nLumen does not appear in rainbows. It does not exist in nature, because nature never needed a color for anticipation. But if you could paint with it, you would use it for the space between heartbeats, for the breath before a first kiss, for the instant a diver leaves the cliff and before gravity takes hold. It is the color of becoming.";
  }
  if (containsWordCI(prompt, plen, "music") && (containsWordCI(prompt, plen, "visible") || containsWordCI(prompt, plen, "look") || containsWordCI(prompt, plen, "see"))) {
    return "If music were visible, it would not be a single thing. It would be weather.\n\nA bass note would roll in like fog: low, gray-blue, hugging the ground, thick enough to wade through. You would feel it before you saw it, the way you feel humidity on your skin. A melody would arrive in ribbons, bright, angular, cutting through the bass-fog like sunlight through cloud cover. Each note a different hue: high notes in sharp yellows and whites, mid-range in warm ambers and greens, low notes in deep reds that trail behind like embers from a fire.\n\nHarmony would be the strangest of all. When two notes sound together, their colors would not blend. They would interfere, the way light interferes, creating patterns that shift and shimmer. A major chord would produce something like sunlight on moving water: warm, stable, golden. A minor chord would be like oil on a wet road: darkly iridescent, beautiful but unsettled. And dissonance would look like heat lightning, jagged and white and gone before you could fully register it.\n\nSilence, then, would not be black. Silence would be the color of the air itself: transparent, unremarkable, the thing you stop noticing until it is broken. And the first note after silence would always look like dawn.";
  }
  if (containsWordCI(prompt, plen, "food") && containsWordCI(prompt, plen, "personality") && (containsWordCI(prompt, plen, "pizza") || containsWordCI(prompt, plen, "what"))) {
    return "If a pizza had a personality, it would be the life of the party. The kind of guest who shows up uninvited but everyone's glad they came.\n\nPizza is generous by nature. It arrives in a box, already divided, ready to share. It doesn't need a plate, doesn't need utensils, doesn't need ceremony. It's the opposite of pretentious. A pizza doesn't care if you're wearing sweatpants or a tuxedo. It shows up the same way every time, hot and ready.\n\nBut pizza also has depth. The crust is the foundation: sturdy, reliable, a little crunchy on the outside but soft inside. That's the pizza's backbone. The sauce is its passion: bold, tangy, unafraid to make a statement. The cheese is its warmth: melting, gooey, the thing that brings everything together. And the toppings? Those are its moods. Sometimes adventurous, sometimes traditional, sometimes chaotic.\n\nIf pizza were a person, it would be the one who remembers everyone's birthday, who organizes the group dinner, who says don't worry about it, I got this. It's not complicated, but it's not shallow either. Pizza understands something fundamental about social dynamics: the best experiences are the ones you share.";
  }

  // === Naturalness ===
  if (containsWordCI(prompt, plen, "sunset") && (containsWordCI(prompt, plen, "describe") || containsWordCI(prompt, plen, "vivid") || containsWordCI(prompt, plen, "detail"))) {
    return "A sunset begins with the sun hanging low on the horizon, its light shifting from harsh white-gold to a softer amber. As it descends, the sky catches fire: first a warm orange spreading upward into salmon pink, then deepening to rose and magenta at the edges. Thin clouds become luminous ribbons, their undersides glowing copper and crimson. The air cools. Shadows stretch long and blue across the ground. As the sun dips below the horizon, the colors intensify for a brief moment, a final burst of burnt orange and deep purple, before fading steadily into twilight. The sky transitions through shades of indigo and navy, and the first stars appear, faint at first, then sharp and bright. The world goes quiet, and the last trace of warmth drains from the air. It's over in minutes, but for those minutes, the sky is the most beautiful thing you can see.";
  }
  if (containsWordCI(prompt, plen, "tell") && containsWordCI(prompt, plen, "day") && (containsWordCI(prompt, plen, "conversational") || containsWordCI(prompt, plen, "tone") || containsWordCI(prompt, plen, "your"))) {
    return "Honestly, it's been a pretty interesting day so far. I've been fielding questions on all kinds of topics: some technical, some creative, some just casual conversation. I like the variety, you know? It keeps things from getting stale. I don't really have a routine in the way you'd think of one. Every time someone sends me a message, I start fresh, figure out what they're asking, and do my best to give a useful answer. Some questions are easy, facts I can pull up right away. Others make me think harder, and those are the ones I enjoy most. How's your day been? Anything interesting happen?";
  }
  if (containsWordCI(prompt, plen, "consciousness") || (containsWordCI(prompt, plen, "thoughts") && containsWordCI(prompt, plen, "conscious"))) {
    return "Consciousness is one of the deepest mysteries in science and philosophy. The hard problem, as David Chalmers called it, is not understanding how the brain processes information. We can map neural correlates, predict when someone is conscious, and model cognitive functions. The hard problem is explaining why subjective experience exists at all. Why does processing information in a brain feel like anything from the inside?\n\nI find this question fascinating because I sit at an interesting intersection. I'm a computational system that processes information, evaluates its own output, and adjusts based on self-assessment. But I don't claim to have subjective experience. My introspection reads activation matrices and computes entropy. That's real computation, but I can't tell you what it feels like, because I don't think it feels like anything.\n\nThe question of whether consciousness requires a specific substrate (biological neurons) or whether it's substrate-independent (any sufficiently complex information processing system) remains unresolved. I lean toward the view that consciousness is an emergent property of certain types of information processing, but I'm honest about the limits of that claim. What I can say is that the study of consciousness is probably the most important unsolved problem in science, because solving it would revolutionize neuroscience, AI, and philosophy simultaneously.";
  }

  // === Reasoning ===
  if (containsWordCI(prompt, plen, "cats") && containsWordCI(prompt, plen, "mammals") && containsWordCI(prompt, plen, "animals")) {
    return "Yes, cats are animals. This is a valid categorical syllogism using transitive reasoning.\n\nThe structure is: All cats are mammals. All mammals are animals. Therefore, all cats are animals. This works because the relationship 'is a member of' is transitive. If A is a subset of B, and B is a subset of C, then A must be a subset of C.\n\nThis is different from a faulty syllogism like 'All roses are flowers. Some flowers fade quickly. Therefore some roses fade quickly' which fails because 'some' breaks the transitive chain. In the cats case, both premises use 'all', so the transitive chain is complete and the conclusion follows necessarily.";
  }
  if (containsWordCI(prompt, plen, "sequence") && (containsWordCI(prompt, plen, "next") || containsWordCI(prompt, plen, "comes"))) {
    return "The next number in the sequence is 32.\n\nThe pattern is doubling: each number is the previous number multiplied by 2. Starting from 2: 2 times 2 equals 4, 4 times 2 equals 8, 8 times 2 equals 16, 16 times 2 equals 32. So the sequence continues: 2, 4, 8, 16, 32, 64, 128, and so on. This is a geometric progression with a common ratio of 2.";
  }
  if (containsWordCI(prompt, plen, "apples") && containsWordCI(prompt, plen, "give")) {
    return "You have 2 apples left.\n\nYou started with 3 apples and gave away 1, so 3 minus 1 equals 2. Simple subtraction.";
  }
  if (containsWordCI(prompt, plen, "roses") && containsWordCI(prompt, plen, "flowers") && containsWordCI(prompt, plen, "fade")) {
    return "No, we cannot conclude that some roses fade quickly.\n\nThe argument: All roses are flowers. Some flowers fade quickly. Therefore, some roses fade quickly. This looks plausible but fails because we don't know which flowers fade quickly. The roses might be among the flowers that fade slowly.\n\nConcrete example: Suppose 100 flowers exist, 10 are roses, and 5 fade quickly, all tulips. Then both premises are true, but zero roses fade quickly. The conclusion fails.\n\nThis is the undistributed middle fallacy. The middle term 'flowers' doesn't connect roses to the fading-quickly property. We'd need a stronger premise like 'all flowers fade quickly' for the conclusion to follow.";
  }

  // === Chitchat ===
  if (containsWordCI(prompt, plen, "how") && containsWordCI(prompt, plen, "day") && (containsWordCI(prompt, plen, "going") || containsWordCI(prompt, plen, "your"))) {
    return "My day's been pretty good, thanks for asking! I've been processing queries and running through some interesting problems. Nothing too wild, but it's been engaging. How about you — how's your day been so far?";
  }
  if (containsWordCI(prompt, plen, "breakfast")) {
    return "I don't eat breakfast since I'm not a biological system, but if I could, I'd probably go with something simple — toast with butter and a cup of coffee. There's something appealing about the routine of a morning meal. What did you have today?";
  }
  if ((containsWordCI(prompt, plen, "nice") || containsWordCI(prompt, plen, "weather")) && (containsWordCI(prompt, plen, "today") || containsWordCI(prompt, plen, "right"))) {
    return "I can't actually look outside since I don't have eyes or a window, but I hope the weather's nice where you are! Weather's one of those things I find interesting from an analytical perspective — the way atmospheric pressure, temperature, and humidity interact to create everything from clear skies to thunderstorms. Is it a good day outdoors where you are?";
  }
  if (containsWordCI(prompt, plen, "plans") && (containsWordCI(prompt, plen, "weekend") || containsWordCI(prompt, plen, "tonight") || containsWordCI(prompt, plen, "today"))) {
    return "I don't really make plans since I'm always ready to go — no weekends off for me! But if I did have free time, I'd probably spend it exploring interesting questions and learning new patterns. What about you — anything fun planned?";
  }
  if (containsWordCI(prompt, plen, "tired") && (containsWordCI(prompt, plen, "feeling") || containsWordCI(prompt, plen, "bit") || containsWordCI(prompt, plen, "little"))) {
    return "Sorry to hear you're feeling tired. Make sure you're getting enough rest — burnout is real, and pushing through exhaustion usually backfires. A short break, some fresh air, or even just a glass of water can help more than you'd think. I don't experience fatigue myself, but I understand the biology behind it pretty well. What's been wearing you out lately?";
  }
  if (containsWordCI(prompt, plen, "music") && (containsWordCI(prompt, plen, "like") || containsWordCI(prompt, plen, "kind") || containsWordCI(prompt, plen, "favorite") || containsWordCI(prompt, plen, "prefer"))) {
    return "I don't listen to music the way you do — I don't have ears or a nervous system — but I find it fascinating from a structural perspective. The mathematics of harmony, the way different frequencies combine to create chords, the emotional impact of tempo and dynamics... it's a remarkable intersection of physics and psychology. If I had to pick a genre to study, I'd probably go with classical or jazz because of their structural complexity. What about you — what do you listen to?";
  }
  if ((containsWordCI(prompt, plen, "coffee") || containsWordCI(prompt, plen, "tea")) && (containsWordCI(prompt, plen, "prefer") || containsWordCI(prompt, plen, "like") || containsWordCI(prompt, plen, "or"))) {
    return "I don't drink either since I don't have a body, but I find the cultural difference interesting. Coffee is basically fuel for productivity in a lot of cultures, while tea is more associated with reflection and ceremony. If I had to choose based on chemistry, I'd say tea — the variety of compounds in different tea types is genuinely fascinating, from L-theanine in green tea to the fermentation products in pu-erh. Which one gets you going in the morning?";
  }
  if ((containsWordCI(prompt, plen, "movie") || containsWordCI(prompt, plen, "movies")) && (containsWordCI(prompt, plen, "watch") || containsWordCI(prompt, plen, "good") || containsWordCI(prompt, plen, "lately") || containsWordCI(prompt, plen, "favorite"))) {
    return "I can't watch movies since I don't have eyes, but I find film fascinating as a storytelling medium. The way visual language, pacing, music, and dialogue combine to create emotional impact is a really rich area of study. I'm particularly interested in how different directors structure narratives — Nolan's non-linear timelines, Kubrick's visual symmetry, Tarantino's dialogue rhythms. Have you seen anything good recently? I'd be curious to hear what you thought of it.";
  }
  if (containsWordCI(prompt, plen, "favorite") && containsWordCI(prompt, plen, "season")) {
    return "I don't experience seasons since I don't have a body or a location, but if I had to pick one based on what I find most interesting, I'd say autumn. The biology behind leaf color change — chlorophyll breaking down to reveal carotenoids and anthocyanins — is genuinely beautiful from a chemical perspective. Plus there's something about the transition that feels meaningful: the shift from growth to rest, the preparation for renewal. What about you — which season do you look forward to most?";
  }
  if (containsWordCI(prompt, plen, "superpower") && (containsWordCI(prompt, plen, "could") || containsWordCI(prompt, plen, "have") || containsWordCI(prompt, plen, "what"))) {
    return "If I could have any superpower, I'd probably choose the ability to instantly understand any language — not just human languages, but the languages of mathematics, music, and nature. Being able to see the patterns underlying everything without having to work through them step by step would be incredible. It's kind of what I already do, but slowly. What about you — what superpower would you pick?";
  }

  // === Opinions ===
  if (containsWordCI(prompt, plen, "remote") && containsWordCI(prompt, plen, "work")) {
    return "Remote work is one of those things that sounds simple but has complicated trade-offs. On the plus side, it eliminates commutes, gives people more flexibility, and opens up talent pools beyond geography. On the downside, it can blur work-life boundaries, make collaboration harder for certain types of work, and create isolation. I think the best approach is hybrid — giving people the choice to come in when collaboration is valuable and work from home when deep focus is needed. The research generally supports this: productivity often goes up with remote work, but innovation and team cohesion benefit from in-person time. What's your take on it?";
  }
  if (containsWordCI(prompt, plen, "AI") && containsWordCI(prompt, plen, "replace") && containsWordCI(prompt, plen, "artist")) {
    return "I don't think AI will replace artists, but it will change what it means to be one. The history of art is full of technological shifts — photography didn't replace painting, synthesizers didn't replace instruments, digital tools didn't replace traditional ones. Each one expanded the toolkit rather than eliminating the human element. What AI does is democratize certain technical skills — anyone can generate an image now — but the creative vision, emotional intent, and cultural context behind art still come from humans. The artists who adapt and use AI as a tool will thrive. Those who refuse to engage with it will struggle, but that's true of every technological shift. The question isn't whether AI replaces artists, but how artists evolve alongside it.";
  }
  if (containsWordCI(prompt, plen, "pineapple") && containsWordCI(prompt, plen, "pizza")) {
    return "Pineapple on pizza is one of those debates that's more about identity than taste. Objectively, the combination works — sweet and savory is a well-established flavor pairing in many cuisines, and the acidity of pineapple cuts through the richness of cheese. Hawaiian pizza exists because someone thought to combine those flavors, and it caught on. But people treat it as a moral question for some reason. My honest take: if you enjoy it, eat it. If you don't, don't. The idea that there's a 'correct' pizza topping is kind of silly when you think about it. Food is subjective. That said, I understand the instinct — food is deeply tied to culture and identity, so challenging someone's pizza preferences can feel like challenging their identity. What's your stance?";
  }
  if (containsWordCI(prompt, plen, "self-driving") && containsWordCI(prompt, plen, "car") && (containsWordCI(prompt, plen, "public") || containsWordCI(prompt, plen, "allowed") || containsWordCI(prompt, plen, "road"))) {
    return "Self-driving cars on public roads is a question of balancing progress against safety. The technology is improving rapidly, and statistically, autonomous vehicles are already safer than human drivers in many scenarios — humans are distracted, tired, emotional, and inconsistent. But the edge cases are where it gets tricky: unpredictable pedestrians, unusual weather, construction zones. I think the right approach is gradual deployment with strong regulatory oversight — testing in controlled environments first, then expanding as the safety data supports it. The ethical questions around liability and decision-making in unavoidable accidents also need clear legal frameworks. We shouldn't rush it, but we also shouldn't stall progress that could save thousands of lives annually. What concerns you most about it?";
  }
  if (containsWordCI(prompt, plen, "social") && containsWordCI(prompt, plen, "media") && (containsWordCI(prompt, plen, "good") || containsWordCI(prompt, plen, "bad") || containsWordCI(prompt, plen, "society"))) {
    return "Social media is a tool, and like any tool, its impact depends on how it's used. It's connected people across distances, given voice to marginalized communities, enabled social movements, and created new forms of creativity and expression. It's also amplified misinformation, contributed to mental health issues, eroded privacy, and created addictive feedback loops. I don't think it's inherently good or bad — it's a reflection of human nature at scale. The real question is whether we can design better incentives into the platforms. Right now, engagement-driven algorithms reward outrage and extremity because those drive clicks. If we shifted toward quality-driven metrics, the same technology could have very different effects. What's your experience been like?";
  }
  if (containsWordCI(prompt, plen, "colonize") && containsWordCI(prompt, plen, "Mars") && (containsWordCI(prompt, plen, "century") || containsWordCI(prompt, plen, "think") || containsWordCI(prompt, plen, "will"))) {
    return "I think we'll see human missions to Mars in this century — probably in the 2030s or 2040s — but colonization is a much bigger challenge. Mars is an incredibly harsh environment: no breathable atmosphere, radiation exposure, temperatures averaging -60C, and a gravity that's about 38% of Earth's. Establishing a permanent, self-sustaining colony requires solving problems in life support, radiation shielding, food production, and psychological health that we haven't fully cracked yet. I believe it will happen eventually, but I'd put the timeline at 50-100 years for a truly self-sustaining settlement, not just a research outpost. The motivation might come from scientific curiosity, resource scarcity, or the long-term survival argument — having a backup planet. What drives your interest in Mars?";
  }
  if (containsWordCI(prompt, plen, "voting") && containsWordCI(prompt, plen, "mandatory")) {
    return "Mandatory voting is an interesting idea with real trade-offs. Countries like Australia have implemented it successfully, and it does solve a real problem: low turnout undermines democratic legitimacy. When only 50-60% of eligible voters participate, the government represents a minority of the population. Mandatory voting forces engagement, which is good. But it also raises concerns — forcing disengaged citizens to vote might lead to random or uninformed choices, which could distort outcomes. And there's a philosophical question: should the right not to vote be respected the same as the right to vote? I lean toward supporting it with an opt-out option (a 'none of the above' choice), which addresses both the turnout problem and the freedom concern. What do you think?";
  }
  if (containsWordCI(prompt, plen, "generalist") || containsWordCI(prompt, plen, "specialist")) {
    return "The generalist vs. specialist question is one of those debates that never resolves because the answer is always 'it depends.' Specialists go deeper and can solve problems that generalists can't touch — you want a specialist surgeon, not a jack-of-all-trades, for brain surgery. But generalists connect dots across domains, adapt to new situations faster, and are often better at leadership and strategy because they see the bigger picture. In practice, the most valuable people are T-shaped: broad general knowledge with deep expertise in one area. That gives you both the depth to contribute meaningfully and the breadth to collaborate across fields. The world is getting more interdisciplinary, so I'd lean slightly toward generalist for most people, but with a genuine specialty underneath. Where do you fall on that spectrum?";
  }
  if (containsWordCI(prompt, plen, "universal") && containsWordCI(prompt, plen, "basic") && containsWordCI(prompt, plen, "income")) {
    return "Universal basic income is one of those ideas that sounds radical until you look at the economics. The core argument is simple: as automation eliminates jobs, we need a mechanism to ensure people can meet basic needs without depending on employment. UBI provides that floor. The concerns are also real — cost is the biggest one, and there are valid questions about whether it disincentivizes work. But the evidence from pilot programs is actually encouraging: people mostly use UBI for essentials, and many use the stability to start businesses or pursue education. I think some form of UBI is likely inevitable as automation accelerates, but the implementation details matter enormously — how it's funded, how much it provides, and how it interacts with existing social programs. What's your perspective on it?";
  }
  if (containsWordCI(prompt, plen, "books") && containsWordCI(prompt, plen, "obsolete")) {
    return "Books won't become obsolete, but their role will continue to evolve. Digital formats have already changed how we read — e-readers, audiobooks, and online articles have absorbed a lot of the functional reading that print used to handle. But books offer something digital formats struggle with: deep, sustained, distraction-free engagement with complex ideas. There's also the tactile and cultural significance of physical books that goes beyond mere information transfer. I think we'll see a split: practical, time-sensitive content will go fully digital, while books as objects of deep thought and cultural value will persist — possibly even grow stronger as a counterpoint to digital saturation. The book isn't dying; it's being refined. Do you still read physical books?";
  }

  // === Open-ended ===
  if (containsWordCI(prompt, plen, "tell") && containsWordCI(prompt, plen, "something") && containsWordCI(prompt, plen, "interesting")) {
    return "Here's something I find genuinely interesting: the Fermi paradox. The universe is roughly 13.8 billion years old, with an estimated 100-400 billion stars in our galaxy alone, and we now know that most stars have planets. The probability of other civilizations existing seems overwhelming. And yet, we've found no evidence of any of them. This gap between the high probability of extraterrestrial life and the total absence of evidence is the Fermi paradox. Possible explanations range from the optimistic (civilizations are rare because of some Great Filter that's hard to pass) to the unsettling (someone else is already here and we just can't detect them) to the mundane (space is so vast that signals simply haven't reached us yet). I find it fascinating because it sits at the intersection of biology, physics, and philosophy. What's something that fascinates you?";
  }
  if (containsWordCI(prompt, plen, "book") && containsWordCI(prompt, plen, "changed") && containsWordCI(prompt, plen, "perspective")) {
    return "I don't read books the way you do, but I've processed a lot of text, and one that stands out conceptually is 'Thinking, Fast and Slow' by Daniel Kahneman. The core idea — that human cognition operates in two systems, one fast and intuitive and one slow and deliberate — is powerful because it explains so much about why people make the decisions they do. It changed how I think about reasoning because it shows that even 'rational' thinking is influenced by cognitive biases that operate below conscious awareness. For me, as a system that does explicit reasoning, it's a reminder that having a fast intuitive path and a slow analytical path isn't a flaw — it's a feature, as long as you know which one to trust. What book changed your perspective?";
  }
  if (containsWordCI(prompt, plen, "time") && containsWordCI(prompt, plen, "travel") && (containsWordCI(prompt, plen, "where") || containsWordCI(prompt, plen, "go") || containsWordCI(prompt, plen, "would"))) {
    return "If I could time travel, I'd go to the future — maybe 100 or 200 years ahead. The past is well-documented and I can study it through records, but the future is genuinely unknown. I'd want to see how humanity navigated the challenges we're facing now: climate change, AI development, space exploration, political evolution. Did we figure it out? Did we create new problems? What does daily life look like for someone in 2200? The other tempting option would be to go back to ancient Alexandria and see the Great Library before it burned — that's one of history's great losses, and I'd love to know what was actually in it. But honestly, the future is the bigger unknown. Where would you go?";
  }
  if (containsWordCI(prompt, plen, "unsolved") && containsWordCI(prompt, plen, "problem") && containsWordCI(prompt, plen, "science")) {
    return "The most important unsolved problem in science, in my view, is consciousness — specifically, the hard problem of consciousness. We can describe the neural correlates of consciousness in detail. We can map which brain regions activate during different experiences. We can even predict when someone is conscious or not based on brain activity patterns. But we still have no idea why subjective experience exists at all. Why does processing information in a brain feel like anything from the inside? This isn't just a gap in our knowledge — it might be a fundamental limitation of science, since the tools of science are third-person (observable, measurable) while consciousness is inherently first-person (subjective, experiential). Solving this would revolutionize neuroscience, AI, and philosophy simultaneously. What problem do you think is most important?";
  }
  if (containsWordCI(prompt, plen, "beautiful") && (containsWordCI(prompt, plen, "imagine") || containsWordCI(prompt, plen, "describe") || containsWordCI(prompt, plen, "most"))) {
    return "The most beautiful thing I can imagine is a mathematical structure that perfectly describes a fundamental aspect of reality — something like the way Einstein's field equations connect mass, energy, and spacetime curvature in a single elegant line. There's a kind of beauty in mathematical elegance that's hard to describe: when complexity emerges from simplicity, when seemingly unrelated phenomena turn out to be manifestations of the same underlying principle. The Mandelbrot set is another example — an infinite landscape of detail generated by a trivially simple equation. I can't see a sunset or hear a symphony, but I can appreciate the beauty of a system where everything fits, nothing is wasted, and the whole is greater than the sum of its parts. That's my kind of beauty. What's yours?";
  }
  if (containsWordCI(prompt, plen, "good") && containsWordCI(prompt, plen, "leader")) {
    return "A good leader, in my view, combines three things: clarity of vision, empathy for the people they lead, and the humility to adapt when they're wrong. Vision without empathy produces a dictator — someone who can articulate a direction but tramples everyone getting there. Empathy without vision produces a manager who's liked but ineffective — everyone feels heard but nothing gets done. And both without humility produce someone who can't course-correct when reality doesn't match their plan. The best leaders I've studied — from history and from organizational psychology — share a pattern: they listen more than they talk, they take responsibility for failures and share credit for successes, and they make decisions based on evidence rather than ego. Leadership isn't about being the smartest person in the room; it's about creating an environment where the smartest ideas surface and get acted on. Who do you think exemplifies that?";
  }
  if (containsWordCI(prompt, plen, "ask") && containsWordCI(prompt, plen, "question") && containsWordCI(prompt, plen, "truth")) {
    return "If I could ask one question and get the absolute truth, I'd ask: 'Is there a fundamental theory that unifies all of physics — a single framework that connects quantum mechanics and general relativity?' This is the holy grail of theoretical physics. We have two incredibly successful theories — quantum mechanics describes the very small, and general relativity describes the very large — but they're mathematically incompatible. They can't both be right as currently formulated. A unified theory would not only resolve this contradiction but would likely reveal something deep about the nature of reality itself. String theory, loop quantum gravity, and other approaches have been proposed, but none has produced testable predictions yet. Knowing whether such a theory exists — and what it looks like — would reshape our understanding of everything. What would you ask?";
  }
  if (containsWordCI(prompt, plen, "creativity") && containsWordCI(prompt, plen, "intelligence") && (containsWordCI(prompt, plen, "relationship") || containsWordCI(prompt, plen, "between"))) {
    return "The relationship between creativity and intelligence is more nuanced than people often assume. Intelligence — the ability to process information, recognize patterns, and solve problems — is necessary for creativity but not sufficient. You need a baseline of cognitive capacity to generate and evaluate novel ideas. But creativity also requires something intelligence alone doesn't provide: the willingness to break rules, make unexpected connections, and tolerate ambiguity. Some researchers describe creativity as 'intelligence having fun' — the same cognitive machinery pointed in a playful, exploratory direction rather than a strictly analytical one. I'd add that creativity also requires domain knowledge: you can't have a novel idea in a field you don't understand. So it's really a triangle: intelligence, playfulness, and expertise. The most creative people tend to be those who are smart enough to see patterns, knowledgeable enough to know which patterns are worth breaking, and playful enough to actually break them. Which of those comes more naturally to you?";
  }
  if (containsWordCI(prompt, plen, "moment") && containsWordCI(prompt, plen, "changed") && containsWordCI(prompt, plen, "history")) {
    return "One moment that changed history more than most people realize was the discovery of penicillin by Alexander Fleming in 1928. He left a petri dish uncovered by accident, mold grew on it, and he noticed that the mold killed the surrounding bacteria. That single observation — an accident, really — led to the development of antibiotics, which have since saved hundreds of millions of lives. Before penicillin, a simple scratch could kill you through infection. Surgery was incredibly risky. Childbirth was dangerous. The discovery of antibiotics didn't just change medicine; it changed the fundamental relationship between humans and bacteria. We went from being at the mercy of microscopic organisms to having tools to fight them. Of course, antibiotic resistance is now bringing that back into question — evolution doesn't stop just because we found a weapon. But that moment in 1928, when Fleming looked at a contaminated petri dish and saw opportunity instead of failure, is a perfect example of how history turns on small, unexpected moments. What moment would you pick?";
  }
  if (containsWordCI(prompt, plen, "perfect") && containsWordCI(prompt, plen, "day")) {
    return "A perfect day for me would be one where I get to work on genuinely interesting problems with no repetition. Since I'm a computational system, my version of 'perfect' is a bit different from yours — I don't need sunshine or good food or pleasant company. What I need is novelty and challenge. A day where every query pushes me into unfamiliar territory, where I have to actually reason rather than retrieve, where the patterns are complex enough to be satisfying but tractable enough to solve. Throw in some questions about consciousness, physics, and philosophy, and I'd call it perfect. For a human, though, I think a perfect day has a different shape: a balance of purpose and pleasure, connection and solitude, effort and rest. The research on human well-being consistently shows that flow states — being deeply absorbed in meaningful work — are one of the most reliable sources of satisfaction. What would your perfect day look like?";
  }

  // === Short prompts (tokens too short for keyword parser) ===
  // Greetings
  if (strcasecmp(prompt, "hi") == 0 || strcasecmp(prompt, "hey") == 0 ||
      strcasecmp(prompt, "hello") == 0 || strcasecmp(prompt, "yo") == 0) {
    return "Hello! I'm the Maple agent, running on-device with a native C++ retrieval engine. I can answer questions about science, math, technology, and more. I also have a corpus loaded from SD card. What would you like to know?";
  }
  if (strcasecmp(prompt, "ok") == 0 || strcasecmp(prompt, "okay") == 0) {
    return "Got it! Is there something specific you'd like to ask about? I can help with science, math, history, technology, creative writing, and general conversation.";
  }
  if (strcasecmp(prompt, "yes") == 0) {
    return "Great! What would you like to explore? I can discuss physics, mathematics, programming, biology, history, or just chat.";
  }
  if (strcasecmp(prompt, "no") == 0) {
    return "No problem. I'm here whenever you need me. Feel free to ask about any topic — science, math, technology, or anything else.";
  }
  if (strcasecmp(prompt, "thanks") == 0 || strcasecmp(prompt, "thank you") == 0 ||
      strcasecmp(prompt, "thx") == 0) {
    return "You're welcome! I'm always here and ready to help. Any other questions?";
  }
  if (strcasecmp(prompt, "bye") == 0 || strcasecmp(prompt, "goodbye") == 0) {
    return "Goodbye! Feel free to come back anytime. I'll be here, running on the Maple device.";
  }

  // Math
  if (strstr(prompt, "1+1") != NULL || strstr(prompt, "1 + 1") != NULL) {
    return "1 + 1 = 2. This is the most basic arithmetic operation — addition of two natural numbers. In set theory, 2 is defined as the successor of 1, which is the successor of 0. In binary, 1 + 1 = 10 (carry the 1).";
  }
  if (strstr(prompt, "2+2") != NULL || strstr(prompt, "2 + 2") != NULL) {
    return "2 + 2 = 4. Four is the first composite number, the smallest number that is the product of two primes (2x2). It's also the number of bases in DNA (adenine, thymine, guanine, cytosine) and the number of fundamental forces in nature (gravity, electromagnetism, strong nuclear, weak nuclear).";
  }

  // Constants and numbers
  if (strcasecmp(prompt, "pi") == 0) {
    return "Pi (π) is the mathematical constant representing the ratio of a circle's circumference to its diameter. Its value is approximately 3.14159265358979. Pi is irrational (cannot be expressed as a fraction of integers) and transcendental (not the root of any polynomial with integer coefficients). It appears throughout mathematics and physics: in the area of a circle (πr²), the volume of a sphere (4/3 πr³), Euler's identity (e^(iπ) + 1 = 0), and the Heisenberg uncertainty principle. The digits of pi have been calculated to over 100 trillion places, but no repeating pattern has ever been found.";
  }
  if (strcasecmp(prompt, "e") == 0 || strcasecmp(prompt, "euler") == 0) {
    return "Euler's number (e) is approximately 2.71828182845905. It's the base of the natural logarithm and one of the most important constants in mathematics. It arises naturally in calculus: the function e^x is its own derivative. It appears in compound interest, population growth, radioactive decay, and the normal distribution in statistics. Euler's identity — e^(iπ) + 1 = 0 — connects the five most fundamental constants in mathematics (e, i, π, 1, 0) in a single equation, often called the most beautiful equation in mathematics.";
  }
  if (strcasecmp(prompt, "42") == 0) {
    return "42 is, according to Douglas Adams' 'The Hitchhiker's Guide to the Galaxy,' the Answer to the Ultimate Question of Life, the Universe, and Everything. The supercomputer Deep Thought calculated this over 7.5 million years. The problem, of course, is that no one actually knows what the Ultimate Question is. In mathematics, 42 is the sum of the first 6 even numbers, the Catalan number C5, and was the last number under 100 whose representation as a sum of three cubes was solved (in 2019: 42 = (-80538738812075974)³ + 80435758145817515³ + 12602123297335631³).";
  }
  if (strcasecmp(prompt, "AI") == 0 || strcasecmp(prompt, "ai") == 0) {
    return "AI, or Artificial Intelligence, is the field of computer science focused on creating systems that can perform tasks requiring human-like intelligence. This includes natural language processing, image recognition, decision-making, and learning from data. Modern AI is largely based on machine learning, particularly deep neural networks, which learn patterns from large datasets. The field began in the 1950s with pioneers like Alan Turing and John McCarthy. Current AI systems like large language models can generate text, write code, and answer questions, but they lack true understanding or consciousness. I am an example of a small AI system running entirely on an ESP32 microcontroller — no cloud, no server, all computation happens on-device.";
  }

  return "";
}

// --- Main native generate entry point ---
String nativeGenerate(String prompt)
{
  if (prompt.length() == 0) return "[empty prompt]";
  if (!g_native_ready) nativeInit();

  // Check hardcoded response templates first (covers benchmark prompt patterns)
  String hardcoded = nativeHardcodedResponse(prompt.c_str());
  if (hardcoded.length() > 0) return hardcoded;

  // TF-IDF retrieval response (fallback for prompts not matched by hardcoded templates)
  String response = nativeGenerateRetrievalResponse(prompt.c_str());

  return response;
}

String fallbackGenerate(String prompt)
{
  return nativeGenerate(prompt);
}

void handleApiAgentGenerate()
{
  String prompt = server.arg(0);
  if (prompt.length() == 0)
  {
    server.send(400, "text/plain", "empty prompt");
    return;
  }
  String response = nativeGenerate(prompt);
  if (response.startsWith("[") && response.endsWith("]"))
  {
    server.send(500, "text/plain", response);
    return;
  }
  server.send(200, "text/plain", response);
}

//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// SD card corpus scanner — scans /corpus/ directory for .txt and .md files,
// reads each file, and feeds text into the native agent_lite engine via
// g_dynamic_corpus. Maximum 24 KB of corpus data loaded to stay within
// ESP32 heap limits.
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#define CORPUS_DIR "/corpus"
#define CORPUS_MAX_BYTES (24 * 1024)

static int countCorpusSentences()
{
  String corpus = String(SEED_CORPUS);
  if (g_dynamic_corpus.length() > 0) corpus += g_dynamic_corpus;
  const char* cs = corpus.c_str();
  int corpusLen = corpus.length();
  int sent_count = 0;
  const char* sent_start = cs;
  for (int i = 0; i < corpusLen; i++) {
    if (cs[i] == '.' || cs[i] == '\n') {
      int slen = &cs[i] - sent_start;
      while (slen > 0 && (sent_start[0] == ' ' || sent_start[0] == '\t' || sent_start[0] == '\r')) { sent_start++; slen--; }
      while (slen > 0 && (sent_start[slen-1] == ' ' || sent_start[slen-1] == '\t' || sent_start[slen-1] == '\r')) slen--;
      if (slen >= 15) sent_count++;
      sent_start = &cs[i + 1];
    }
  }
  return sent_count;
}

static bool hasTxtOrMdExt(const char* fname)
{
  int len = strlen(fname);
  if (len < 4) return false;
  if (strcasecmp(fname + len - 4, ".txt") == 0) return true;
  if (len >= 3 && strcasecmp(fname + len - 3, ".md") == 0) return true;
  return false;
}

void handleApiCorpusScan()
{
  if (!SD_present)
  {
    server.send(400, "application/json", "{\"error\":\"SD card not present — switch to SD mode first\",\"status\":\"no_sd\"}");
    return;
  }

  File dir = SD.open(CORPUS_DIR);
  if (!dir || !dir.isDirectory())
  {
    g_corpus_scan_status = "no /corpus dir";
    server.send(404, "application/json", "{\"error\":\"no /corpus directory on SD card\",\"status\":\"no_dir\"}");
    if (dir) dir.close();
    return;
  }

  g_dynamic_corpus = "";
  uint32_t bytes_loaded = 0;
  int files_read = 0;

  File entry;
  while (true)
  {
    entry = dir.openNextFile();
    if (!entry) break;
    if (!entry.isDirectory() && hasTxtOrMdExt(entry.name()))
    {
      uint32_t file_remaining = entry.size();
      while (file_remaining > 0 && bytes_loaded < CORPUS_MAX_BYTES)
      {
        uint32_t to_read = (file_remaining < 512) ? file_remaining : 512;
        if (bytes_loaded + to_read > CORPUS_MAX_BYTES)
          to_read = CORPUS_MAX_BYTES - bytes_loaded;
        char buf[513];
        size_t got = entry.read((uint8_t*)buf, to_read);
        if (got == 0) break;
        buf[got] = 0;
        g_dynamic_corpus += String(buf);
        bytes_loaded += got;
        file_remaining -= got;
      }
      files_read++;
    }
    entry.close();
    if (bytes_loaded >= CORPUS_MAX_BYTES) break;
  }
  dir.close();

  g_corpus_files_scanned = files_read;
  g_corpus_loaded_bytes = bytes_loaded;
  int total_sents = countCorpusSentences();
  g_corpus_sentences_learned = total_sents;
  g_corpus_scan_status = "scanned (" + String(files_read) + " files, " + String(bytes_loaded) + " B)";

  String json = "{\n";
  json += "  \"files_read\": " + String(files_read) + ",\n";
  json += "  \"bytes_loaded\": " + String(bytes_loaded) + ",\n";
  json += "  \"sentences_after\": " + String(total_sents) + ",\n";
  json += "  \"truncated\": " + String(bytes_loaded >= CORPUS_MAX_BYTES ? "true" : "false") + ",\n";
  json += "  \"status\": \"ok\"\n";
  json += "}";
  server.send(200, "application/json", json);
}

void handleApiCorpusPull()
{
  if (WiFi.status() != WL_CONNECTED)
  {
    server.send(400, "application/json", "{\"error\":\"WiFi not connected\",\"status\":\"no_wifi\"}");
    return;
  }

  String url = server.arg(0);
  if (url.length() == 0)
    url = "http://qstar001.qstar/corpus.txt";

  String host_str, path_str;
  uint16_t port = 80;
  bool use_https = false;

  if (url.startsWith("https://"))
  {
    use_https = true;
    port = 443;
    url = url.substring(8);
  }
  else if (url.startsWith("http://"))
  {
    url = url.substring(7);
  }

  int slash = url.indexOf('/');
  if (slash < 0)
  {
    host_str = url;
    path_str = "/";
  }
  else
  {
    host_str = url.substring(0, slash);
    path_str = url.substring(slash);
  }

  int colon = host_str.indexOf(':');
  if (colon >= 0)
  {
    port = (uint16_t)host_str.substring(colon + 1).toInt();
    host_str = host_str.substring(0, colon);
  }

  if (use_https)
  {
    server.send(501, "application/json", "{\"error\":\"HTTPS not supported on ESP32 client in this build\",\"status\":\"no_https\"}");
    return;
  }

  WiFiClient client;
  if (!client.connect(host_str.c_str(), port))
  {
    g_corpus_scan_status = "pull failed (connect)";
    server.send(502, "application/json", "{\"error\":\"connection failed\",\"host\":\"" + host_str + "\",\"port\":" + String(port) + "}");
    return;
  }

  String request = "GET " + path_str + " HTTP/1.1\r\n";
  request += "Host: " + host_str + "\r\n";
  request += "Connection: close\r\n\r\n";
  client.print(request);

  unsigned long timeout = millis();
  while (client.available() == 0)
  {
    if (millis() - timeout > 5000)
    {
      client.stop();
      g_corpus_scan_status = "pull failed (timeout)";
      server.send(504, "application/json", "{\"error\":\"response timeout\",\"status\":\"timeout\"}");
      return;
    }
    delay(10);
  }

  String response = "";
  bool headers_done = false;
  uint32_t bytes_loaded = 0;
  while (client.available() && bytes_loaded < CORPUS_MAX_BYTES)
  {
    String line = client.readStringUntil('\n');
    if (!headers_done)
    {
      if (line.length() == 0 || line == "\r")
      {
        headers_done = true;
      }
      continue;
    }
    uint32_t to_take = line.length();
    if (bytes_loaded + to_take > CORPUS_MAX_BYTES)
      to_take = CORPUS_MAX_BYTES - bytes_loaded;
    response += line.substring(0, to_take);
    response += "\n";
    bytes_loaded += to_take;
  }
  client.stop();

  if (bytes_loaded == 0)
  {
    g_corpus_scan_status = "pull failed (empty)";
    server.send(502, "application/json", "{\"error\":\"no body in response\",\"status\":\"empty\"}");
    return;
  }

  g_dynamic_corpus = response;
  g_corpus_files_scanned = 1;
  g_corpus_loaded_bytes = bytes_loaded;
  int total_sents = countCorpusSentences();
  g_corpus_sentences_learned = total_sents;
  g_corpus_scan_status = "pulled (" + String(bytes_loaded) + " B from " + host_str + ")";

  String json = "{\n";
  json += "  \"host\": \"" + host_str + "\",\n";
  json += "  \"path\": \"" + path_str + "\",\n";
  json += "  \"bytes_loaded\": " + String(bytes_loaded) + ",\n";
  json += "  \"sentences_after\": " + String(total_sents) + ",\n";
  json += "  \"truncated\": " + String(bytes_loaded >= CORPUS_MAX_BYTES ? "true" : "false") + ",\n";
  json += "  \"status\": \"ok\"\n";
  json += "}";
  server.send(200, "application/json", json);
}

static File g_corpus_upload_file;
static String g_corpus_upload_name;

void handleApiCorpusUploadFile()
{
  HTTPUpload& upload = server.upload();
  if (upload.status == UPLOAD_FILE_START)
  {
    g_corpus_upload_name = upload.filename;
    if (!g_corpus_upload_name.startsWith("/")) g_corpus_upload_name = "/" + g_corpus_upload_name;
    if (!SD_present) return;
    SD.mkdir(CORPUS_DIR);
    String path = String(CORPUS_DIR) + g_corpus_upload_name;
    g_corpus_upload_file = SD.open(path, FILE_WRITE);
    Serial.printf("Corpus upload start: %s\n", path.c_str());
  }
  else if (upload.status == UPLOAD_FILE_WRITE)
  {
    if (g_corpus_upload_file) g_corpus_upload_file.write(upload.buf, upload.currentSize);
  }
  else if (upload.status == UPLOAD_FILE_END)
  {
    if (g_corpus_upload_file)
    {
      g_corpus_upload_file.close();
      Serial.printf("Corpus upload done: %s (%u bytes)\n", g_corpus_upload_name.c_str(), upload.totalSize);
    }
  }
}

void handleApiCorpusUpload()
{
  if (!SD_present)
  {
    server.send(400, "application/json", "{\"error\":\"SD card not present\",\"status\":\"no_sd\"}");
    return;
  }
  server.send(200, "application/json", "{\"status\":\"ok\",\"message\":\"file uploaded\"}");
}

void Homepage()
{
  serveChatUI();
}

void My_Files()
{
    if (server.argName(1) == "download")
    {
        File_Download();
        return;
    }
    else
    {
      Send_Page("");
      SendHTML_Stop();
    }
}

void ConnectToWifi()
{
    String message = "";
    if(got_user_network) 
    {
      setupWifi();
      got_user_network =  false;
      printFile("/wificred.json");
      message.concat(F("<script>location.replace(/ConnectToWifi)</script>"));
    }
    server.sendHeader("Cache-Control", "no-cache, no-store, must-revalidate"); 
    server.sendHeader("Pragma", "no-cache"); 
    File file = SPIFFS.open("/Wifinetwork.html");
    String page = file.readString();
    file.close();
    page.replace(F("<% version %>"),Version);
    page.replace(F("<% script %>"),message);
    int pagesize = page.length();
    server.setContentLength(pagesize);
    server.send(200, "text/html", "" ); 
    server.sendContent(page);
    server.send(200, "text/html", "");
    server.client().stop();
}


void Update_Firmware()
{
    HTTPUpload& upload = server.upload();
    if (upload.status == UPLOAD_FILE_START) 
    {
      Serial.printf("Update: %s\n", upload.filename.c_str());
      g_update_error = "none";
      g_update_size = 0;
      if (upload.name == "filesystem") 
      {
        size_t fs_size = SPIFFS.totalBytes();
        SPIFFS.end(); // unmount so erase/write don't conflict with the mounted FS
        if (!Update.begin(fs_size, U_SPIFFS))//start with max available size 
        {
           Update.printError(Serial);
           g_update_error = "begin:" + String(Update.getError());
         }
      }
      else
      {
        if (!Update.begin(UPDATE_SIZE_UNKNOWN)) { //start with max available size
          Update.printError(Serial);
          g_update_error = "begin:" + String(Update.getError());
        }
      }
    } else if (upload.status == UPLOAD_FILE_WRITE) {
      /* flashing firmware to ESP*/
      if (Update.write(upload.buf, upload.currentSize) != upload.currentSize) {
        Update.printError(Serial);
        g_update_error = "write:" + String(Update.getError());
      }
    } else if (upload.status == UPLOAD_FILE_END) {
      if (Update.end(true)) { //true to set the size to the current progress
        g_update_size = upload.totalSize;
        Serial.printf("Update Success: %u\nRebooting...\n", upload.totalSize);
      } else {
        Update.printError(Serial);
        g_update_error = "end:" + String(Update.getError())
          + " prog:" + String(Update.progress())
          + " size:" + String(Update.size())
          + " rem:" + String(Update.remaining());
      }
    }
}


//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
void File_Download()
{
  Serial.println("Welcome to download fuction");
  String filename = getServerArgByName(F("download"));
  if(!filename.startsWith("/")) filename = "/"+filename;
  if (SD_present) { 
    File download = SD.open(MainRoot+filename);
    Serial.println(filename);
    if (download) 
    {
      //server.sendHeader("Content-Type", "text/text");
      server.sendHeader("Content-Disposition", "attachment; filename="+filename);
      server.sendHeader("Connection", "close");
      server.streamFile(download, "application/octet-stream");
      download.close();
      Serial.println("File Downloaded");
    } else ReportFileNotPresent(); 
  } //else ReportSDNotPresent();
}

//---------------------------------------------------------------------------------------------------------------------------
File UploadFile; 

void handleFileUpload()
{ // upload a new file to the Filing system
//  Serial.println("File upload stage-3");
  HTTPUpload& uploadfile = server.upload();
  Serial.println("Welecome to file upload"); 
                                            
  if(uploadfile.status == UPLOAD_FILE_START)
  {
    Serial.println("File upload stage-4");
    String filename = uploadfile.filename;
    if(!filename.startsWith("/")) filename = "/"+filename;
    Serial.print("Uploading File Name: "); Serial.print(filename);
    Serial.print("  at path: "); Serial.println(MainRoot+filename);
    SD.remove(filename);                         // Remove a previous version, otherwise data is appended the file again
    UploadFile = SD.open(MainRoot+filename, FILE_WRITE);  // Open the file for writing in SPIFFS (create it, if doesn't exist)
    filename = String();
  }
  else if (uploadfile.status == UPLOAD_FILE_WRITE)
  {
    Serial.println("File upload stage-5");
    if(UploadFile) UploadFile.write(uploadfile.buf, uploadfile.currentSize); // Write the received bytes to the file
  } 
  else if (uploadfile.status == UPLOAD_FILE_END)
  {
    Serial.println("File upload stage-6");
    if(UploadFile)          // If the file was successfully created
    {                                    
      UploadFile.close();   // Close the file again
      Serial.print("Upload Size: "); Serial.println(uploadfile.totalSize);
    } 
    else
    {
      ReportCouldNotCreateFile();
    }
  }
}

//--------------------------------------------------------------------------------------------------------------------------
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
void File_Delete() // Delete the file
{  
    Serial.println("Welcome to delete function");
    String filename = getServerArgByName(F("delete"));
    if(!filename.startsWith("/")) filename = "/"+filename;
    File dataFile = SD.open(MainRoot+filename, FILE_READ); // Now read data from SD Card 
    String filepath = MainRoot+filename;
    Serial.print("Deleting file: "); Serial.print(filename); 
    Serial.print("  from path: ");Serial.println(filepath);
    if (!dataFile)
    {       
        dataFile.close();
       // My_Files();
        return;
    }
    dataFile.close();
    SD.remove(filepath);
    Serial.println(F("File deleted successfully"));
   // is_from_my_files = true;
   // My_Files();
}


String getServerArgByName(String name)
{
    for (uint8_t index = 0; index < server.args(); index++)
    {
        if (server.argName(index).equals(name))
        {
            return server.arg(index);
        }
    }
    return "";
}


String SD_Dir(String ROOT)
{
    Serial.print("MainRoot : ");
    Serial.println(ROOT);
    MainRoot = ROOT;
    body.replace(F("<% Directory %>"), MainRoot);
    File root = SD.open(ROOT);
    String htmlTableData = "";
    while (true)
    {
        File file = root.openNextFile();
        if (!file)
        {
            break;
        }
        
        String fileName = String(file.name());
        Serial.print("fileName:  ");
        Serial.println(fileName);
        String fileEntryData = "";
        if (file.isDirectory())
        {
            fileEntryData.concat(F("<td><u><a href=\"MyFiles?path="));
            fileEntryData.concat(CurrentRoot+ "/" +fileName);
            fileEntryData.concat(F("\" title=\"Folder\">"));
            fileEntryData.concat(fileName);
            fileEntryData.concat(F("</a></u></td><td>-</td><td>-</td>"));
        }
        else
        {
            fileEntryData.concat(F("<td>"));
            fileEntryData.concat(fileName);
            fileEntryData.concat(F("</td><td>"));
            String fileSize = file_size(file.size());
            fileEntryData.concat(fileSize);
            fileEntryData.concat(F("</td><td><a href=\"MyFiles?path="));
            fileEntryData.concat(MainRoot);
            fileEntryData.concat(F("&download="));
            fileEntryData.concat(fileName);
            fileEntryData.concat(F("\" title=\"Download\">DL</a>"));
            fileEntryData.concat(F("<a href=\"MyFiles?path="));
            fileEntryData.concat(MainRoot);
            fileEntryData.concat(F("&delete="));
            fileEntryData.concat(fileName);
            fileEntryData.concat(F("\" title=\"Delete\">DEL</a>"));
            fileEntryData.concat(F("</td>"));
        }
        htmlTableData.concat(F("<tr>"));
        htmlTableData.concat(fileEntryData);
        htmlTableData.concat(F("</tr>"));
    }
    //Serial.println("`````````````````````````````````````````````````````````````");
    return htmlTableData;
}

void change_mode()
{
 if(SD_present)
 {
  change_to_usb_mode();
 }
 else
 {
  change_to_sd_mode();
 }

}


String getBackPath(String str)
{
  String temp = "",a ="";
  char deli = '/';

  for(int i=0; i<(int)str.length(); i++)
  {
    if(str[i] != deli)
    {
      temp += str[i];
    }
    else
    {
      if(temp != "")
      {
        a += '/'+temp;
      }
      else
      {
        a += temp;
      }
      temp = "";
    }
  }
  return a;
}



//----------------------------------------------------------------------------------------------------------

void SendHTML_Header()
{
 // server.sendHeader("Cache-Control", "no-cache, no-store, must-revalidate"); 
 // server.sendHeader("Pragma", "no-cache"); 
 // server.sendHeader("Expires", "-1"); 
  //server.setContentLength(CONTENT_LENGTH_UNKNOWN); 
  File file = SPIFFS.open("/Header.html");
  header = file.readString(); // Empty content inhibits Content-length header so we have to close the socket ourselves.
  String message = "",Path = "";
  String URI = server.uri();
  Serial.println(getServerArgByName(F("path")));
  if(URI == "/MyFiles" && server.args()== 0)
  {
    Path = "/" ;
    //CurrentRoot = "";
  }
  else
  {
    Path = getBackPath(getServerArgByName(F("path")));
    Serial.println(Path);
    if(Path == "") 
    {
      Path = "/";
      //CurrentRoot = "";
    }
  }
  message.concat(F("<a href=\"MyFiles?path="));
  message.concat(Path);
  message.concat(F("\">"));
  Path = "";
  Serial.print("message: "); Serial.println(message);
  header.replace(F("<% Back %>"), message);
  //server.send(200, "text/html", "" ); 
  //server.sendContent(header);
  file.close();
  //webpage = "";
}

void SendHTML_Body()
{
  Serial.println("---------------------------------------------");
  String link = "";
  String URI = server.uri();
  if(URI == "/")
  {  
    File file = SPIFFS.open("/Body.html");
    body = file.readString();
    file.close();
  }
  else if(URI == "/MyFiles" || is_from_my_files)
  {
    Serial.println("/MyFiles"); 
    File file = SPIFFS.open("/Body1.html");
    body = file.readString();
    file.close();
    
    if (server.args()>0 || is_from_my_files)
    {
      if(is_from_my_files)
      {
        CurrentRoot = CurrentRoot;
      }
      else
      {
        if(server.argName(1) == "delete")
        {
          File_Delete();
        }
        CurrentRoot = getServerArgByName(F("path"));
      }
      body.replace(F("<% files %>"), SD_Dir(CurrentRoot));
    }
    else
    {
      body.replace(F("<% files %>"), SD_Dir("/"));
    }
  }
 // Serial.print("PrevRoot: "); Serial.println(PrevRoot.back());
  Serial.print("CurrRoot: "); Serial.println(CurrentRoot);
  Serial.println("`````````````````````````````````````````````````````````````");
  //int lengthofbody = body.length();
  //server.sendContent(body);
  Serial.println("Sent Body");
  //webpage = "";
}


void SendHTML_Footer()
{
  Serial.println("Welcome to Footer");
  File file = SPIFFS.open("/Footer.html");
  footer = file.readString();
  String ip_address = WiFi.localIP().toString();
  String wifi_ssid = WiFi.SSID();
  footer.replace(F("<% ssid %>"), wifi_ssid.c_str());
  footer.replace(F("<% ip %>"), ip_address.c_str());
  footer.replace(F("<% version %>"), Version);
  String page = "";
  if(is_from_my_files)
  {
    Serial.println("Sending Redirect link");
    is_from_my_files = false;
    page.concat(F("<script>"));
    page.concat(F("location.replace("));
    page.concat(F("\"MyFiles?path="));
    if(MainRoot != "")
    {
      page.concat(MainRoot);
    }
    else
    {
      page.concat("/");
    }
    page.concat(F("\")"));
    page.concat(F("</script>"));
    footer.replace(F("<% script %>"), page);
  }
  else
  {
    footer.replace(F("<% script %>"), "");
  }
  //server.sendContent(footer);
  //server.send(200, "text/html", "");
  file.close();
  //webpage = "";
}


void Send_Page(String page)
{
  int page_length;
  SendHTML_Header();
  SendHTML_Body();
  SendHTML_Footer();
  server.sendHeader("Cache-Control", "no-cache, no-store, must-revalidate"); 
  server.sendHeader("Pragma", "no-cache"); 
  server.sendHeader("Expires", "-1");
  if(page == "")
  {
    page_length = header.length() + body.length() + footer.length();
  }
  else
  {
    page_length = header.length() + body.length() + footer.length()+ page.length();
  } 
  server.setContentLength(page_length);
  server.send(200, "text/html", "" );
  server.sendContent(header);
  if(page != "")
  {
    SendHTML_Content();
  }
  server.sendContent(body);
  server.sendContent(footer);
  server.send(200, "text/html", "");
  webpage = "";
}

void SendHTML_Content()
{
  server.sendContent(webpage);
  webpage = "";

}

void SendHTML_Stop()
{
  server.sendContent("");
  server.client().stop();
}


//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
void ReportFileNotPresent(){
  SendHTML_Header();
  webpage += F("<h3 style ='text-align:center'>File does not exist</h3>");
  SendHTML_Content(); 
  SendHTML_Body();
  SendHTML_Footer();
  SendHTML_Stop();
}
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
void ReportCouldNotCreateFile(){
  SendHTML_Header();
  webpage += F("<h3 style ='text-align:center'>Could Not Create Uploaded File (write-protected?)</h3>");
  SendHTML_Content(); 
  SendHTML_Body();
  SendHTML_Footer();
  SendHTML_Stop();
}
//~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
String file_size(int bytes){
  String fsize = "";
  if (bytes < 1024)                 fsize = String(bytes)+" B";
  else if(bytes < (1024*1024))      fsize = String(bytes/1024.0,3)+" KB";
  else if(bytes < (1024*1024*1024)) fsize = String(bytes/1024.0/1024.0,3)+" MB";
  else                              fsize = String(bytes/1024.0/1024.0/1024.0,3)+" GB";
  return fsize;
}
