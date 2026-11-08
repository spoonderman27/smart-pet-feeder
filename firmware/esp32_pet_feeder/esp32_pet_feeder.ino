/*
 * Smart Pet Care and Monitoring System - ESP32 firmware
 *
 * The ESP32 reads all the sensors and controls the food gates (servos), the
 * water pump and the cooling fan. It sends the data to the Raspberry Pi with
 * MQTT (Mosquitto broker on the Pi). The Pi runs the camera and pet recognition
 * and sends everything to Firebase for the mobile app.
 *
 *   ESP32  <--MQTT-->  Raspberry Pi  <-->  Firebase  <-->  Flutter app
 *
 * Water refill and the fan still work when Wi-Fi or the Pi is down
 * (the last settings are saved in flash).
 *
 * MQTT topics:
 *   petfeeder/feeder01/telemetry  ESP32 -> Pi   sensor data every 5 s
 *   petfeeder/feeder01/event      ESP32 -> Pi   pet presence, feeding result, pump, fan
 *   petfeeder/feeder01/status     ESP32 -> Pi   "online" / "offline" (retained, last will)
 *   petfeeder/feeder01/cmd        Pi -> ESP32   commands from the app
 *   petfeeder/feeder01/config     Pi -> ESP32   settings from the app (retained)
 *
 * Libraries: PubSubClient, ArduinoJson 7, DHT sensor library (Adafruit),
 *            HX711 (bogde), ESP32Servo
 * Board: ESP32 Dev Module
 *
 * Serial monitor (115200 baud, Newline) test commands:
 *   help | w | tare A | cal A 100 | servo A 105 | feed A 30 | pump 3 | fan on/off/auto
 *   dist | water | wcal empty | wcal half | wcal full | status
 */

#include <WiFi.h>
#include <ESPmDNS.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <DHT.h>
#include <HX711.h>
#include <ESP32Servo.h>

// --- Wi-Fi ---
const char* WIFI_SSID = "YOUR_WIFI_SSID";
const char* WIFI_PASS = "YOUR_WIFI_PASSWORD";

// --- MQTT (Mosquitto broker on the Raspberry Pi) ---
const char* MQTT_HOST = "172.20.10.12";   // IP of the Pi
const uint16_t MQTT_PORT = 1883;
const char* MQTT_USER = "YOUR_MQTT_USER";   // made with mosquitto_passwd
const char* MQTT_PASS = "YOUR_MQTT_PASSWORD";
const char* DEVICE_ID = "feeder01";

// --- Pins ---
#define PIN_DHT            4
#define PIN_HX_A_DT        16   // HX711 of bowl A
#define PIN_HX_A_SCK       17
#define PIN_HX_B_DT        18   // HX711 of bowl B
#define PIN_HX_B_SCK       19
#define PIN_US_FEED_TRIG   23   // HC-SR04 #1, in front of the food bowls
#define PIN_US_FEED_ECHO   34   //   ECHO through 12k / 24k divider (5 V -> 3.3 V)
#define PIN_US_WATER_TRIG  22   // HC-SR04 #2, at the water bowl
#define PIN_US_WATER_ECHO  35   //   ECHO through 12k / 24k divider
#define PIN_SERVO_A        13   // food gate A
#define PIN_SERVO_B        14   // food gate B
#define PIN_WATER_SIG      32   // water level sensor S (ADC1 works with Wi-Fi on)
#define PIN_WATER_PWR      33   // water level sensor +, only powered while reading
#define PIN_RELAY_PUMP     25   // relay IN1
#define PIN_RELAY_FAN      26   // relay IN2
#define PIN_LED            2    // LED on GPIO 2 = MQTT connected

// My relay board switches ON when IN is LOW.
#define RELAY_ACTIVE_LOW   true

// --- Food gates ---
// Each servo has its own angles because the horns are not mounted the same way.
// Test with "servo A 105" / "servo A 130" and "servo B 113" / "servo B 90".
const int   SERVO_A_CLOSED_DEG = 105;   // gate A closed (start position)
const int   SERVO_A_OPEN_DEG   = 130;   // gate A open
const int   SERVO_B_CLOSED_DEG = 113;   // gate B closed (start position)
const int   SERVO_B_OPEN_DEG   = 90;    // gate B open
const unsigned long GATE_OPEN_MS       = 200;   // gate open time for one pulse of food
const unsigned long GATE_OPEN_SHORT_MS = 120;   // shorter pulse when close to the target
const unsigned long SETTLE_MS          = 700;   // wait for the food to land before weighing
const int   MAX_PULSES         = 40;
const unsigned long DISPENSE_TIMEOUT_MS = 45000;
const float MAX_PORTION_G      = 400.0;

// --- Water ---
// Default calibration only. Calibrate from the app (Feeder > Calibrate water sensor)
// or with "wcal empty" / "wcal full" in the Serial monitor. Saved in flash.
const int   WATER_RAW_DRY      = 0;     // reading with an empty bowl
const int   WATER_RAW_FULL     = 1650;  // reading with a full bowl
const int   WATER_LOW_PCT      = 30;    // refill below this
const int   WATER_FULL_PCT     = 75;    // stop the pump at this
const unsigned long PUMP_MAX_AUTO_MS = 6000;    // max pump ON time for one refill
const unsigned long PUMP_MAX_FILL_MS = 10000;   // max pump ON time for "Fill to full"
// The pump runs in short pulses and the level is checked after the water
// settles, so the bowl does not overshoot.
const unsigned long PUMP_PULSE_MS    = 500;     // pump ON
const unsigned long PUMP_SETTLE_MS   = 1000;    // pump OFF, then measure
const unsigned long PUMP_COOLDOWN_MS = 15000;   // rest time between refills
const unsigned long RESERVOIR_RETRY_MS = 10UL * 60UL * 1000UL;   // tank empty: try again after 10 min
// A pet has to be seen for 10 readings in a row (about 2 s) before it counts,
// so a hand passing by does not trigger anything.
const int   PRESENCE_CONFIRM_READS = 10;
const long  WATER_PRESENCE_CM = 8;      // pet at the water bowl when closer than this (empty bowl reads 9 cm)
const bool  WATER_SENSOR_INSTALLED = true;

// --- Fan and telemetry ---
const float FAN_HYSTERESIS_C   = 1.0;   // fan turns off 1 C below the limit
const unsigned long TELEMETRY_MS = 5000;

// ==================== Global variables ====================
WiFiClient   net;
PubSubClient mqtt(net);
Preferences  prefs;
DHT          dht(PIN_DHT, DHT22);
HX711        scaleA, scaleB;
Servo        servoA, servoB;

String TOPIC_TELEMETRY, TOPIC_EVENT, TOPIC_STATUS, TOPIC_CMD, TOPIC_CONFIG;

// Settings from the app (saved in flash)
float  tempThreshold = 30.0;
String fanMode       = "auto";   // auto | on | off
bool   waterAuto     = true;     // refill when the water level is low
bool   petTopUp      = true;     // top up when a pet is at the water bowl
int    waterRawDry   = WATER_RAW_DRY;    // water sensor calibration
int    waterRawHalf  = -1;               // optional HALF point (-1 = not set)
int    waterRawFull  = WATER_RAW_FULL;
bool   topUpUsed     = false;            // only one top-up per visit
int    presenceCm    = 25;
int    wakeCm        = 30;      // wake the Pi camera when something is this close

// Current readings
float lastTemp = NAN, lastHum = NAN;
float weightA = 0, weightB = 0;
int   waterRaw = 0, waterPct = 0;
bool  fanOn = false, pumpOn = false;
bool  feederPresent = false, waterPresent = false;
long  distFeed = 999, distWater = 999;
bool  reservoirEmpty = false;
unsigned long reservoirFlagAt = 0;

// Pump
unsigned long pumpStartedAt = 0, pumpLimitMs = 0, pumpStoppedAt = 0;
unsigned long pumpRunMs = 0, pumpPhaseAt = 0;   // for the pulses
bool pumpPhaseOn = false;
int    pumpStartPct = 0;
String pumpReason = "";

// Presence counters
int feedNearCount = 0, feedFarCount = 0, waterNearCount = 0, waterFarCount = 0;
int wakeNearCount = 0;
unsigned long lastMotionEvent = 0;

// Feeding state machine
enum DispenseState { DS_IDLE, DS_GATE_OPEN, DS_SETTLE };
struct Dispense {
  DispenseState state = DS_IDLE;
  char   comp = 'A';
  float  targetG = 0;
  float  startG = 0;
  float  lastG = 0;
  int    pulses = 0;
  int    noGain = 0;
  unsigned long startedAt = 0;
  unsigned long stateAt = 0;
  String requestId;
  String source;
} disp;

unsigned long lastTelemetry = 0, lastDht = 0, lastScales = 0, lastWater = 0,
              lastFeedPing = 0, lastWaterPing = 0, lastMqttTry = 0;

// ==================== Helpers ====================
void relayWrite(int pin, bool on) {
  digitalWrite(pin, (on ^ RELAY_ACTIVE_LOW) ? HIGH : LOW);
}

HX711& scaleFor(char c) { return c == 'B' ? scaleB : scaleA; }
Servo& servoFor(char c) { return c == 'B' ? servoB : servoA; }
int closedDeg(char c) { return c == 'B' ? SERVO_B_CLOSED_DEG : SERVO_A_CLOSED_DEG; }
int openDeg(char c)   { return c == 'B' ? SERVO_B_OPEN_DEG   : SERVO_A_OPEN_DEG; }

// Average of a few readings. Does not hang if the HX711 is unplugged.
bool readScale(HX711& s, float& out, int samples) {
  float sum = 0;
  int ok = 0;
  for (int i = 0; i < samples; i++) {
    if (s.wait_ready_timeout(250)) {
      sum += s.get_units(1);
      ok++;
    }
  }
  if (ok == 0) return false;
  out = sum / ok;
  return true;
}

long readDistanceCm(int trig, int echo) {
  digitalWrite(trig, LOW);
  delayMicroseconds(3);
  digitalWrite(trig, HIGH);
  delayMicroseconds(10);
  digitalWrite(trig, LOW);
  unsigned long us = pulseIn(echo, HIGH, 25000UL);   // about 4 m max
  if (us == 0) return 999;                            // no echo
  return (long)(us * 0.0343 / 2.0);
}

int readWaterRaw() {
  digitalWrite(PIN_WATER_PWR, HIGH);
  delay(10);
  long sum = 0;
  for (int i = 0; i < 8; i++) { sum += analogRead(PIN_WATER_SIG); delay(2); }
  digitalWrite(PIN_WATER_PWR, LOW);   // off between readings = less corrosion
  return (int)(sum / 8);
}

// Raw reading -> 0-100 %. The sensor is not linear (the reading rises fast when
// the water first touches it and slowly near the top), so when a HALF point is
// saved it uses two straight lines: empty-half and half-full.
int rawToPct(int raw) {
  if (waterRawFull == waterRawDry) return 0;
  long pct;
  bool halfOk = waterRawHalf >= 0 &&
                (long)(waterRawHalf - waterRawDry) * (long)(waterRawFull - waterRawHalf) > 0;
  if (halfOk) {
    bool lowerPart = (waterRawFull > waterRawDry) ? raw <= waterRawHalf : raw >= waterRawHalf;
    pct = lowerPart ? map(raw, waterRawDry, waterRawHalf, 0, 50)
                    : map(raw, waterRawHalf, waterRawFull, 50, 100);
  } else {
    pct = map(raw, waterRawDry, waterRawFull, 0, 100);
  }
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  return (int)pct;
}

void publishJson(const String& topic, JsonDocument& doc, bool retain) {
  if (!mqtt.connected()) return;
  char buf[768];
  size_t n = serializeJson(doc, buf, sizeof(buf));
  mqtt.publish(topic.c_str(), (const uint8_t*)buf, n, retain);
}

void publishEvent(JsonDocument& doc) {
  doc["ts"] = millis();
  publishJson(TOPIC_EVENT, doc, false);
}

void saveSettings() {
  prefs.putFloat("thr", tempThreshold);
  prefs.putString("fanMode", fanMode);
  prefs.putBool("waterAuto", waterAuto);
  prefs.putBool("petTopUp", petTopUp);
  prefs.putInt("presCm", presenceCm);
  prefs.putInt("wakeCm", wakeCm);
}

void loadSettings() {
  tempThreshold = prefs.getFloat("thr", 30.0);
  fanMode       = prefs.getString("fanMode", "auto");
  waterAuto     = prefs.getBool("waterAuto", true);
  petTopUp      = prefs.getBool("petTopUp", true);
  waterRawDry   = prefs.getInt("wDry", WATER_RAW_DRY);
  waterRawFull  = prefs.getInt("wFull", WATER_RAW_FULL);
  waterRawHalf  = prefs.getInt("wHalf", -1);
  presenceCm    = prefs.getInt("presCm", 25);
  wakeCm        = prefs.getInt("wakeCm", 30);
}

void setupScale(HX711& s, int dt, int sck, const char* calKey, const char* offKey) {
  s.begin(dt, sck);
  float cal = prefs.getFloat(calKey, 420.0);   // default, calibrate with "cal A 100"
  s.set_scale(cal);
  if (prefs.isKey(offKey)) {
    s.set_offset(prefs.getLong(offKey, 0));     // keep the zero point after a restart
  } else if (s.wait_ready_timeout(1000)) {
    s.tare(15);                                 // first start: the bowl must be empty
    prefs.putLong(offKey, s.get_offset());
  } else {
    Serial.printf("WARNING: HX711 on DT=%d not responding\n", dt);
  }
}

bool tareScale(char c) {
  HX711& s = scaleFor(c);
  if (!s.wait_ready_timeout(1000)) return false;
  s.tare(15);
  prefs.putLong(c == 'B' ? "offB" : "offA", s.get_offset());
  if (c == 'B') weightB = 0; else weightA = 0;
  return true;
}

// ==================== Fan and water pump ====================
void setFan(bool on, const char* reason) {
  if (on == fanOn) return;
  fanOn = on;
  relayWrite(PIN_RELAY_FAN, on);
  Serial.printf("[FAN] %s (%s)\n", on ? "ON" : "OFF", reason);
  JsonDocument ev;
  ev["type"] = "fan";
  ev["on"] = on;
  ev["reason"] = reason;
  if (!isnan(lastTemp)) ev["temperature"] = lastTemp;
  publishEvent(ev);
}

// Saves the current water sensor reading as the EMPTY, HALF or FULL point.
bool calibrateWater(const String& point) {
  long sum = 0;
  for (int i = 0; i < 3; i++) { sum += readWaterRaw(); delay(20); }
  int raw = (int)(sum / 3);
  bool ok = true;
  if (point == "empty" || point == "dry") {
    waterRawDry = raw;
    prefs.putInt("wDry", raw);
  } else if (point == "half") {
    if (abs(raw - waterRawDry) < 50) ok = false;      // sensor not in water
    else { waterRawHalf = raw; prefs.putInt("wHalf", raw); }
  } else if (point == "full") {
    if (abs(raw - waterRawDry) < 100) ok = false;     // sensor not in water / wiring
    else { waterRawFull = raw; prefs.putInt("wFull", raw); }
  } else {
    ok = false;
  }
  waterRaw = raw;
  waterPct = rawToPct(raw);
  Serial.printf("[WATER] calibrate %s: raw %d %s (empty=%d half=%d full=%d)\n", point.c_str(), raw,
                ok ? "saved" : "REJECTED", waterRawDry, waterRawHalf, waterRawFull);
  JsonDocument ev;
  ev["type"] = "water_cal";
  ev["point"] = point;
  ev["raw"] = raw;
  ev["ok"] = ok;
  ev["empty"] = waterRawDry;
  ev["half"] = waterRawHalf;
  ev["full"] = waterRawFull;
  publishEvent(ev);
  return ok;
}

void startPump(unsigned long ms, const char* reason) {
  if (pumpOn) return;
  pumpOn = true;
  pumpStartedAt = millis();
  pumpLimitMs = ms;
  pumpStartPct = waterPct;
  pumpReason = reason;
  pumpRunMs = 0;
  pumpPhaseOn = true;
  pumpPhaseAt = pumpStartedAt;
  relayWrite(PIN_RELAY_PUMP, true);
  Serial.printf("[PUMP] start, max %lu ms pumping in pulses (%s)\n", ms, reason);
}

void stopPump(const char* why) {
  if (!pumpOn) return;
  relayWrite(PIN_RELAY_PUMP, false);
  pumpOn = false;
  pumpStoppedAt = millis();
  if (pumpPhaseOn) pumpRunMs += pumpStoppedAt - pumpPhaseAt;
  pumpPhaseOn = false;
  unsigned long ran = pumpRunMs;            // time the pump was really ON
  Serial.printf("[PUMP] OFF after %lu ms (%s)\n", ran, why);

  JsonDocument ev;
  ev["type"] = "water";
  ev["reason"] = pumpReason;
  ev["stop"] = why;
  ev["seconds"] = ran / 1000.0;
  ev["levelBefore"] = pumpStartPct;
  ev["levelAfter"] = waterPct;

  // Pump ran the full time but the level hardly changed -> the tank is empty.
  if (WATER_SENSOR_INSTALLED && pumpReason != "manual" &&
      strcmp(why, "max_time") == 0 && (waterPct - pumpStartPct) < 5) {
    reservoirEmpty = true;
    reservoirFlagAt = millis();
    ev["reservoirEmpty"] = true;
  }
  publishEvent(ev);
}

// ==================== Food dispensing ====================
// Food comes out in pulses: open the gate (200 ms), close it, wait for the food
// to land, weigh the bowl, and repeat until 95 % of the target is in the bowl.
// It stops early when the hopper is empty (6 pulses in a row with no weight gain).

void finishDispense(bool ok, const char* reason) {
  servoFor(disp.comp).write(closedDeg(disp.comp));
  float w = disp.lastG;
  float dispensed = w - disp.startG;
  if (dispensed < 0) dispensed = 0;

  Serial.printf("[FEED] %c done: %.1f / %.1f g (%s), %d pulses, %.1f s\n", disp.comp, dispensed,
                disp.targetG, reason, disp.pulses, (millis() - disp.startedAt) / 1000.0);

  JsonDocument ev;
  ev["type"] = "dispense_done";
  ev["requestId"] = disp.requestId;
  ev["compartment"] = String(disp.comp);
  ev["targetG"] = disp.targetG;
  ev["dispensedG"] = round(dispensed * 10) / 10.0;
  ev["bowlAfterG"] = round(w * 10) / 10.0;
  ev["pulses"] = disp.pulses;
  ev["ok"] = ok;
  ev["reason"] = reason;
  ev["source"] = disp.source;
  publishEvent(ev);
  disp.state = DS_IDLE;
}

void startDispense(char comp, float grams, const String& requestId, const String& source) {
  if (disp.state != DS_IDLE) {
    JsonDocument ev;
    ev["type"] = "dispense_done";
    ev["requestId"] = requestId;
    ev["compartment"] = String(comp);
    ev["targetG"] = grams;
    ev["dispensedG"] = 0;
    ev["ok"] = false;
    ev["reason"] = "busy";
    ev["source"] = source;
    publishEvent(ev);
    return;
  }
  if (grams <= 0 || grams > MAX_PORTION_G) grams = constrain(grams, 1.0f, MAX_PORTION_G);

  float start;
  if (!readScale(scaleFor(comp), start, 5)) {
    disp.comp = comp; disp.targetG = grams; disp.startG = 0; disp.lastG = 0;
    disp.requestId = requestId; disp.source = source; disp.pulses = 0;
    finishDispense(false, "scale_error");
    return;
  }
  disp.comp = comp;
  disp.targetG = grams;
  disp.startG = start;
  disp.lastG = start;
  disp.pulses = 0;
  disp.noGain = 0;
  disp.requestId = requestId;
  disp.source = source;
  disp.startedAt = millis();
  Serial.printf("[FEED] %c target %.1f g, bowl starts at %.1f g\n", comp, grams, start);

  servoFor(comp).write(openDeg(comp));
  disp.pulses = 1;
  disp.state = DS_GATE_OPEN;
  disp.stateAt = millis();
}

void updateDispense() {
  if (disp.state == DS_IDLE) return;
  unsigned long now = millis();
  float soFar = disp.lastG - disp.startG;
  float remaining = disp.targetG - soFar;
  unsigned long openMs = (remaining < disp.targetG * 0.3f) ? GATE_OPEN_SHORT_MS : GATE_OPEN_MS;

  if (disp.state == DS_GATE_OPEN && now - disp.stateAt >= openMs) {
    servoFor(disp.comp).write(closedDeg(disp.comp));
    disp.state = DS_SETTLE;
    disp.stateAt = now;
    return;
  }

  if (disp.state == DS_SETTLE && now - disp.stateAt >= SETTLE_MS) {
    float w;
    if (!readScale(scaleFor(disp.comp), w, 3)) { finishDispense(false, "scale_error"); return; }
    if (w - disp.lastG < 0.5f) disp.noGain++; else disp.noGain = 0;
    disp.lastG = w;
    if (disp.comp == 'B') weightB = w; else weightA = w;

    float dispensed = w - disp.startG;
    if (dispensed >= disp.targetG * 0.95f)            { finishDispense(true,  "target_reached"); return; }
    if (disp.noGain >= 6)                             { finishDispense(dispensed > 2, dispensed > 2 ? "partial_hopper_empty" : "hopper_empty"); return; }
    if (disp.pulses >= MAX_PULSES)                    { finishDispense(dispensed > 2, "max_pulses"); return; }
    if (now - disp.startedAt > DISPENSE_TIMEOUT_MS)   { finishDispense(dispensed > 2, "timeout"); return; }

    servoFor(disp.comp).write(openDeg(disp.comp));   // next pulse
    disp.pulses++;
    disp.state = DS_GATE_OPEN;
    disp.stateAt = now;
  }
}

// ==================== MQTT ====================
void applyConfig(JsonDocument& doc) {
  bool changed = false;
  if (doc["tempThreshold"].is<float>() || doc["tempThreshold"].is<int>()) {
    tempThreshold = doc["tempThreshold"].as<float>(); changed = true;
  }
  if (doc["fanMode"].is<const char*>()) {
    String m = doc["fanMode"].as<String>();
    if (m == "auto" || m == "on" || m == "off") { fanMode = m; changed = true; }
  }
  if (doc["waterAuto"].is<bool>()) { waterAuto = doc["waterAuto"].as<bool>(); changed = true; }
  if (doc["petTopUp"].is<bool>())  { petTopUp  = doc["petTopUp"].as<bool>();  changed = true; }
  if (doc["presenceCm"].is<int>()) {
    presenceCm = constrain(doc["presenceCm"].as<int>(), 5, 150); changed = true;
  }
  if (doc["wakeCm"].is<int>()) {
    wakeCm = constrain(doc["wakeCm"].as<int>(), 10, 150); changed = true;
  }
  if (changed) {
    saveSettings();
    Serial.printf("[CFG] thr=%.1f fan=%s waterAuto=%d presence=%dcm wake=%dcm\n",
                  tempThreshold, fanMode.c_str(), waterAuto, presenceCm, wakeCm);
  }
}

void handleCommand(JsonDocument& doc) {
  String action = doc["action"] | "";
  Serial.printf("[CMD] %s\n", action.c_str());

  if (action == "dispense") {
    String c = doc["compartment"] | "A";
    float g = doc["grams"] | 20.0f;
    startDispense(c == "B" ? 'B' : 'A', g, doc["requestId"] | "", doc["source"] | "auto");
  } else if (action == "water") {
    reservoirEmpty = false;                 // owner asked, so try again
    String mode = doc["mode"] | "";
    if (mode == "fill") {
      // "Fill to full": pump in pulses until the level reaches WATER_FULL_PCT
      if (waterPct >= WATER_FULL_PCT) {
        JsonDocument ev;
        ev["type"] = "water";
        ev["reason"] = "fill";
        ev["stop"] = "already_full";
        ev["seconds"] = 0;
        ev["levelBefore"] = waterPct;
        ev["levelAfter"] = waterPct;
        publishEvent(ev);
      } else {
        startPump(PUMP_MAX_FILL_MS, "fill");
      }
    } else {
      int s = doc["seconds"] | 3;
      s = constrain(s, 1, 15);
      startPump((unsigned long)s * 1000UL, "manual");
    }
  } else if (action == "water_cal") {
    String point = doc["point"] | "";
    calibrateWater(point);
  } else if (action == "tare") {
    String c = doc["compartment"] | "A";
    bool ok = tareScale(c == "B" ? 'B' : 'A');
    JsonDocument ev;
    ev["type"] = "tare";
    ev["compartment"] = c;
    ev["ok"] = ok;
    publishEvent(ev);
  } else if (action == "fan") {             // fan mode (also sent in config)
    String m = doc["mode"] | "auto";
    if (m == "auto" || m == "on" || m == "off") { fanMode = m; saveSettings(); }
  } else if (action == "servo") {           // servo test
    String s = doc["servo"] | "A";
    int angle = constrain((int)(doc["angle"] | 0), 0, 180);
    servoFor(s == "B" ? 'B' : 'A').write(angle);
  } else if (action == "reboot") {
    ESP.restart();
  }
}

void onMqttMessage(char* topic, byte* payload, unsigned int length) {
  JsonDocument doc;
  // const, so ArduinoJson copies the strings (PubSubClient reuses the buffer)
  DeserializationError err = deserializeJson(doc, (const byte*)payload, length);
  if (err) {
    Serial.printf("[MQTT] bad JSON on %s: %s\n", topic, err.c_str());
    return;
  }
  if (TOPIC_CONFIG == topic) applyConfig(doc);
  else if (TOPIC_CMD == topic) handleCommand(doc);
}

// MQTT_HOST can be an IP address or a name like raspberrypi.local
IPAddress resolveBroker() {
  String host = MQTT_HOST;
  IPAddress ip;
  if (ip.fromString(host)) return ip;
  if (host.endsWith(".local")) {
    host.remove(host.length() - 6);
    ip = MDNS.queryHost(host.c_str(), 2000);
    return ip;
  }
  WiFi.hostByName(MQTT_HOST, ip);
  return ip;
}

// Keeps retrying Wi-Fi, also when the first connect at boot failed.
// Offline for 5 minutes -> restart, but never while pumping or feeding.
void ensureWifi() {
  static unsigned long lostAt = 0, lastTry = 0;
  if (WiFi.status() == WL_CONNECTED) { lostAt = 0; return; }
  unsigned long t = millis();
  if (lostAt == 0) lostAt = t;
  if (t - lastTry >= 20000) {
    lastTry = t;
    // status 1 = network not found (hotspot off / 5 GHz), 4 = wrong password,
    //        6 = disconnected, 0 or 7 = still trying
    Serial.printf("[WIFI] not connected (status %d) - retrying\n", (int)WiFi.status());
    WiFi.disconnect();
    WiFi.begin(WIFI_SSID, WIFI_PASS);
  }
  if (t - lostAt >= 5UL * 60UL * 1000UL && !pumpOn && disp.state == DS_IDLE) {
    Serial.println("[WIFI] offline for 5 min - restarting");
    delay(100);
    ESP.restart();
  }
}

void ensureMqtt() {
  static bool mdnsStarted = false;
  if (WiFi.status() != WL_CONNECTED || mqtt.connected()) return;
  unsigned long now = millis();
  if (now - lastMqttTry < 5000) return;
  lastMqttTry = now;
  if (!mdnsStarted) mdnsStarted = MDNS.begin((String("petfeeder-") + DEVICE_ID).c_str());

  IPAddress ip = resolveBroker();
  if (ip == IPAddress(0, 0, 0, 0)) {
    Serial.println("[MQTT] cannot resolve broker host");
    return;
  }
  mqtt.setServer(ip, MQTT_PORT);
  String clientId = String("petfeeder-") + DEVICE_ID;
  bool ok = (strlen(MQTT_USER) > 0)
      ? mqtt.connect(clientId.c_str(), MQTT_USER, MQTT_PASS, TOPIC_STATUS.c_str(), 1, true, "offline")
      : mqtt.connect(clientId.c_str(), nullptr, nullptr, TOPIC_STATUS.c_str(), 1, true, "offline");
  if (!ok) {
    Serial.printf("[MQTT] connect failed, state=%d\n", mqtt.state());
    return;
  }
  Serial.println("[MQTT] connected");
  mqtt.publish(TOPIC_STATUS.c_str(), "online", true);
  mqtt.subscribe(TOPIC_CMD.c_str(), 1);
  mqtt.subscribe(TOPIC_CONFIG.c_str(), 1);

  JsonDocument ev;
  ev["type"] = "boot";
  ev["fw"] = "2.1";
  ev["ip"] = WiFi.localIP().toString();
  publishEvent(ev);
}

void publishTelemetry() {
  JsonDocument doc;
  if (isnan(lastTemp)) doc["temperature"] = nullptr; else doc["temperature"] = round(lastTemp * 10) / 10.0;
  if (isnan(lastHum))  doc["humidity"]    = nullptr; else doc["humidity"]    = round(lastHum * 10) / 10.0;
  doc["bowlA"] = round(weightA * 10) / 10.0;
  doc["bowlB"] = round(weightB * 10) / 10.0;
  doc["waterPct"] = waterPct;
  doc["waterRaw"] = waterRaw;
  doc["waterLow"] = waterPct < WATER_LOW_PCT;
  doc["reservoirEmpty"] = reservoirEmpty;
  doc["pumpOn"] = pumpOn;
  doc["fanOn"] = fanOn;
  doc["fanMode"] = fanMode;
  doc["tempThreshold"] = tempThreshold;
  doc["waterAuto"] = waterAuto;
  doc["petTopUp"] = petTopUp;
  doc["waterCalEmpty"] = waterRawDry;
  doc["waterCalFull"] = waterRawFull;
  doc["waterCalHalf"] = waterRawHalf;
  doc["feederPresence"] = feederPresent;
  doc["waterPresence"] = waterPresent;
  doc["feederDistCm"] = distFeed;
  doc["wakeCm"] = wakeCm;
  doc["waterDistCm"] = distWater;
  doc["dispensing"] = disp.state != DS_IDLE;
  doc["rssi"] = WiFi.RSSI();
  doc["uptimeS"] = millis() / 1000;
  publishJson(TOPIC_TELEMETRY, doc, false);
}

// ==================== Tasks called from loop() ====================
void taskClimate(unsigned long now) {
  if (now - lastDht < 2500) return;
  lastDht = now;
  float t = dht.readTemperature();
  float h = dht.readHumidity();
  if (!isnan(t)) lastTemp = t;
  if (!isnan(h)) lastHum = h;

  if (fanMode == "on")       setFan(true, "manual");
  else if (fanMode == "off") setFan(false, "manual");
  else if (!isnan(lastTemp)) {
    if (lastTemp >= tempThreshold) setFan(true, "auto");
    else if (lastTemp <= tempThreshold - FAN_HYSTERESIS_C) setFan(false, "auto");
  }
}

void taskScales(unsigned long now) {
  if (disp.state != DS_IDLE) return;          // the feeder is using the scale
  if (now - lastScales < 1500) return;
  lastScales = now;
  float w;
  if (readScale(scaleA, w, 2)) weightA = w;
  if (readScale(scaleB, w, 2)) weightB = w;
}

void presenceEdge(const char* zone, bool present, long dist) {
  Serial.printf("[PRESENCE] %s %s (%ld cm)\n", zone, present ? "ARRIVED" : "LEFT", dist);
  JsonDocument ev;
  ev["type"] = "presence";
  ev["zone"] = zone;
  ev["present"] = present;
  ev["distCm"] = dist;
  publishEvent(ev);
}

void taskPresence(unsigned long now) {
  if (now - lastFeedPing >= 200) {
    lastFeedPing = now;
    distFeed = readDistanceCm(PIN_US_FEED_TRIG, PIN_US_FEED_ECHO);
    if (distFeed < presenceCm) { feedNearCount++; feedFarCount = 0; }
    else if (distFeed > presenceCm + 5) { feedFarCount++; feedNearCount = 0; }
    if (!feederPresent && feedNearCount >= PRESENCE_CONFIRM_READS) { feederPresent = true; presenceEdge("feeder", true, distFeed); }
    if (feederPresent && feedFarCount >= 10)  { feederPresent = false; presenceEdge("feeder", false, distFeed); }

    // "motion" event so the Pi can start its camera before the pet reaches the
    // bowl (the camera needs about 2 s). The wake distance is always at least
    // 5 cm further than the presence distance. Max one event every 5 s.
    int wakeAt = max(wakeCm, presenceCm + 5);
    if (distFeed < wakeAt) wakeNearCount++; else wakeNearCount = 0;
    if (wakeNearCount >= 2 && now - lastMotionEvent >= 5000) {
      lastMotionEvent = now;
      JsonDocument ev;
      ev["type"] = "motion";
      ev["zone"] = "feeder";
      ev["distCm"] = distFeed;
      publishEvent(ev);
    }
  }
  if (now - lastWaterPing >= 300) {
    lastWaterPing = now;
    distWater = readDistanceCm(PIN_US_WATER_TRIG, PIN_US_WATER_ECHO);
    if (distWater < WATER_PRESENCE_CM) { waterNearCount++; waterFarCount = 0; }
    else if (distWater > WATER_PRESENCE_CM + 1) { waterFarCount++; waterNearCount = 0; }   // empty bowl reads 9 cm
    if (!waterPresent && waterNearCount >= PRESENCE_CONFIRM_READS) { waterPresent = true; presenceEdge("water", true, distWater); }
    if (waterPresent && waterFarCount >= 10)  { waterPresent = false; topUpUsed = false; presenceEdge("water", false, distWater); }
  }
}

void taskWater(unsigned long now) {
  // Check the level more often while the pump is running.
  unsigned long period = pumpOn ? 250 : 2000;
  if (now - lastWater >= period) {
    lastWater = now;
    waterRaw = readWaterRaw();
    waterPct = rawToPct(waterRaw);
  }

  if (pumpOn) {
    // Stop at full for every reason, also a manual "Add water", so it cannot overflow.
    if (WATER_SENSOR_INSTALLED && waterPct >= WATER_FULL_PCT) { stopPump("full"); return; }
    unsigned long t = millis();
    if (pumpPhaseOn && t - pumpPhaseAt >= PUMP_PULSE_MS) {
      relayWrite(PIN_RELAY_PUMP, false);      // pulse done, let the water settle
      pumpRunMs += t - pumpPhaseAt;
      pumpPhaseOn = false;
      pumpPhaseAt = t;
    } else if (!pumpPhaseOn && t - pumpPhaseAt >= PUMP_SETTLE_MS) {
      if (pumpRunMs >= pumpLimitMs) { stopPump("max_time"); return; }
      relayWrite(PIN_RELAY_PUMP, true);       // still below full, next pulse
      pumpPhaseOn = true;
      pumpPhaseAt = t;
    }
    return;
  }

  if (reservoirEmpty && waterPct >= WATER_LOW_PCT) reservoirEmpty = false;   // tank was refilled
  if (!WATER_SENSOR_INSTALLED) return;
  unsigned long t2 = millis();
  if (pumpStoppedAt != 0 && t2 - pumpStoppedAt < PUMP_COOLDOWN_MS) return;
  if (reservoirEmpty && t2 - reservoirFlagAt < RESERVOIR_RETRY_MS) return;

  // Two separate rules, each one has its own switch in the app:
  if (waterAuto && waterPct < WATER_LOW_PCT) startPump(PUMP_MAX_AUTO_MS, "low_level");
  else if (petTopUp && waterPresent && !topUpUsed && waterPct < WATER_FULL_PCT - 10) {
    topUpUsed = true;            // once per visit, the pet must leave and come back
    startPump(PUMP_MAX_AUTO_MS, "pet_present");
  }
}

// ==================== Serial commands (testing without the Pi) ====================
void handleSerial() {
  if (!Serial.available()) return;
  String line = Serial.readStringUntil('\n');
  line.trim();
  if (line.isEmpty()) return;
  char c = line.length() > 5 ? toupper(line.charAt(5)) : 'A';

  if (line == "help") {
    Serial.println("w | tare A | cal A 100 | servo A 105 | feed A 30 | pump 3 | fan on|off|auto | dist | water | wcal empty | wcal half | wcal full | status");
  } else if (line == "w") {
    float a = 0, b = 0;
    bool okA = readScale(scaleA, a, 5), okB = readScale(scaleB, b, 5);
    Serial.printf("A: %s %.1f g | B: %s %.1f g\n", okA ? "" : "(ERR)", a, okB ? "" : "(ERR)", b);
  } else if (line.startsWith("tare ")) {
    Serial.printf("Tare %c: %s\n", c, tareScale(c) ? "OK" : "FAILED");
  } else if (line.startsWith("cal ")) {
    // cal A 100 -> tare first, then put a 100 g weight on bowl A
    char comp = toupper(line.charAt(4));
    float known = line.substring(6).toFloat();
    HX711& s = scaleFor(comp);
    if (known <= 0 || !s.wait_ready_timeout(1000)) { Serial.println("usage: cal A 100"); return; }
    long raw = s.read_average(20) - s.get_offset();
    float factor = raw / known;
    s.set_scale(factor);
    prefs.putFloat(comp == 'B' ? "calB" : "calA", factor);
    Serial.printf("Scale %c factor = %.3f (saved)\n", comp, factor);
  } else if (line.startsWith("servo ")) {
    char sv = toupper(line.charAt(6));
    int angle = line.substring(8).toInt();
    if (sv != 'A' && sv != 'B') { Serial.println("usage: servo A 105"); return; }
    servoFor(sv).write(angle);
    Serial.printf("Servo %c -> %d deg\n", sv, angle);
  } else if (line.startsWith("feed ")) {
    // feed A 30 -> give 30 g from hopper A
    char comp = toupper(line.charAt(5));
    float g = line.substring(7).toFloat();
    if (g <= 0) { Serial.println("usage: feed A 30"); return; }
    startDispense(comp == 'B' ? 'B' : 'A', g, "serial", "manual");
  } else if (line.startsWith("pump ")) {
    startPump(constrain(line.substring(5).toInt(), 1, 15) * 1000UL, "manual");
  } else if (line.startsWith("fan ")) {
    String m = line.substring(4);
    if (m != "auto" && m != "on" && m != "off") { Serial.println("usage: fan on|off|auto"); return; }
    fanMode = m;
    saveSettings();
    Serial.printf("Fan mode %s\n", fanMode.c_str());
  } else if (line == "dist") {
    Serial.printf("Feeder %ld cm | Water %ld cm\n",
                  readDistanceCm(PIN_US_FEED_TRIG, PIN_US_FEED_ECHO),
                  readDistanceCm(PIN_US_WATER_TRIG, PIN_US_WATER_ECHO));
  } else if (line == "wcal empty" || line == "wcal half" || line == "wcal full") {
    calibrateWater(line.substring(5));
  } else if (line == "water") {
    int raw = readWaterRaw();
    Serial.printf("Water raw %d -> %d %%\n", raw, rawToPct(raw));
  } else if (line == "status") {
    Serial.printf("WiFi %s (%d dBm) MQTT %s | T=%.1f H=%.1f | A=%.1f B=%.1f | water %d%% | fan %d pump %d\n",
                  WiFi.isConnected() ? "OK" : "DOWN", WiFi.RSSI(), mqtt.connected() ? "OK" : "DOWN",
                  lastTemp, lastHum, weightA, weightB, waterPct, fanOn, pumpOn);
  } else {
    Serial.println("Unknown command - type: help");
  }
}

// ==================== setup / loop ====================
void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("\n=== Smart Pet Feeder ESP32 ===");

  // Relay pins first, so the pump and fan do not switch on at boot.
  pinMode(PIN_RELAY_PUMP, OUTPUT);
  pinMode(PIN_RELAY_FAN, OUTPUT);
  relayWrite(PIN_RELAY_PUMP, false);
  relayWrite(PIN_RELAY_FAN, false);
  pinMode(PIN_LED, OUTPUT);
  pinMode(PIN_WATER_PWR, OUTPUT);
  digitalWrite(PIN_WATER_PWR, LOW);
  pinMode(PIN_US_FEED_TRIG, OUTPUT);
  pinMode(PIN_US_FEED_ECHO, INPUT);
  pinMode(PIN_US_WATER_TRIG, OUTPUT);
  pinMode(PIN_US_WATER_ECHO, INPUT);
  analogReadResolution(12);

  prefs.begin("petfeeder", false);
  loadSettings();

  ESP32PWM::allocateTimer(0);
  ESP32PWM::allocateTimer(1);
  ESP32PWM::allocateTimer(2);
  ESP32PWM::allocateTimer(3);
  servoA.setPeriodHertz(50);
  servoB.setPeriodHertz(50);
  servoA.attach(PIN_SERVO_A, 500, 2400);
  servoB.attach(PIN_SERVO_B, 500, 2400);
  servoA.write(SERVO_A_CLOSED_DEG);
  servoB.write(SERVO_B_CLOSED_DEG);

  dht.begin();
  setupScale(scaleA, PIN_HX_A_DT, PIN_HX_A_SCK, "calA", "offA");
  setupScale(scaleB, PIN_HX_B_DT, PIN_HX_B_SCK, "calB", "offB");

  String base = String("petfeeder/") + DEVICE_ID + "/";
  TOPIC_TELEMETRY = base + "telemetry";
  TOPIC_EVENT     = base + "event";
  TOPIC_STATUS    = base + "status";
  TOPIC_CMD       = base + "cmd";
  TOPIC_CONFIG    = base + "config";

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);                  // more stable on a phone hotspot
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.printf("Connecting to Wi-Fi %s", WIFI_SSID);
  unsigned long t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 15000) { delay(400); Serial.print("."); }
  if (WiFi.isConnected()) {
    Serial.print("\nWi-Fi OK, IP ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println("\nWi-Fi not connected yet - running offline, will retry");
  }

  mqtt.setBufferSize(1024);
  mqtt.setKeepAlive(30);
  mqtt.setCallback(onMqttMessage);

  Serial.println("Type 'help' for serial commands.");
}

void loop() {
  unsigned long now = millis();

  ensureWifi();
  ensureMqtt();
  mqtt.loop();
  digitalWrite(PIN_LED, mqtt.connected() ? HIGH : LOW);

  updateDispense();
  taskPresence(now);
  taskWater(now);
  taskClimate(now);
  taskScales(now);

  if (now - lastTelemetry >= TELEMETRY_MS) {
    lastTelemetry = now;
    publishTelemetry();
  }

  handleSerial();
  delay(5);
}
