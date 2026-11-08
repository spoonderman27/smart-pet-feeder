/*
 * ============================================================================
 *  ESP32 HARDWARE TEST - upload this FIRST, before the real firmware.
 * ============================================================================
 *  Wire ONE component at a time, then test it from the Serial Monitor
 *  (115200 baud, line ending "Newline"). When every component passes, upload
 *  esp32_pet_feeder.ino.
 *
 *  Menu:
 *    1  DHT22 temperature / humidity
 *    2  HX711 bowl A  - live weight (send any key to stop)
 *    3  HX711 bowl B  - live weight
 *    4  Calibrate a load cell (tare + known weight) -> prints factor
 *    5  HC-SR04 feeder distance (live)
 *    6  HC-SR04 water distance (live)
 *    7  Water level sensor raw value (live) - note DRY and FULL readings
 *    8  Servo A sweep 0 -> 70 -> 0
 *    9  Servo B sweep
 *    0  Servo C sweep
 *    p  Pump relay ON 2 s
 *    f  Fan relay ON 5 s
 *    i  I2C/pin summary
 *
 *  Uses the same pins as esp32_pet_feeder.ino. Libraries: DHT sensor library,
 *  HX711 (bogde), ESP32Servo.
 * ============================================================================
 */
#include <DHT.h>
#include <HX711.h>
#include <ESP32Servo.h>

#define PIN_DHT            4
#define PIN_HX_A_DT        16
#define PIN_HX_A_SCK       17
#define PIN_HX_B_DT        18
#define PIN_HX_B_SCK       19
#define PIN_US_FEED_TRIG   23
#define PIN_US_FEED_ECHO   34
#define PIN_US_WATER_TRIG  22
#define PIN_US_WATER_ECHO  35
#define PIN_SERVO_A        13
#define PIN_SERVO_B        14
#define PIN_SERVO_C        27
#define PIN_WATER_SIG      32
#define PIN_WATER_PWR      33
#define PIN_RELAY_PUMP     25
#define PIN_RELAY_FAN      26
#define RELAY_ACTIVE_LOW   true

DHT dht(PIN_DHT, DHT22);
HX711 scaleA, scaleB;
Servo servoA, servoB, servoC;

void relay(int pin, bool on) { digitalWrite(pin, (on ^ RELAY_ACTIVE_LOW) ? HIGH : LOW); }

bool stopRequested() {
  if (Serial.available()) {
    while (Serial.available()) Serial.read();
    return true;
  }
  return false;
}

long distanceCm(int trig, int echo) {
  digitalWrite(trig, LOW);  delayMicroseconds(3);
  digitalWrite(trig, HIGH); delayMicroseconds(10);
  digitalWrite(trig, LOW);
  unsigned long us = pulseIn(echo, HIGH, 25000UL);
  return us == 0 ? -1 : (long)(us * 0.0343 / 2.0);
}

int waterRaw() {
  digitalWrite(PIN_WATER_PWR, HIGH);
  delay(10);
  long sum = 0;
  for (int i = 0; i < 8; i++) { sum += analogRead(PIN_WATER_SIG); delay(2); }
  digitalWrite(PIN_WATER_PWR, LOW);
  return sum / 8;
}

void sweep(Servo& s, const char* name) {
  Serial.printf("Servo %s: 0 -> 70 -> 0 deg\n", name);
  s.write(0);  delay(600);
  s.write(70); delay(800);
  s.write(0);  delay(600);
  Serial.println("Done. Did it move smoothly? If it jitters, check the 5V supply + common GND.");
}

void liveScale(HX711& s, const char* name) {
  if (!s.wait_ready_timeout(1000)) {
    Serial.printf("HX711 %s NOT RESPONDING - check DT/SCK/VCC/GND wiring\n", name);
    return;
  }
  Serial.printf("Taring %s... keep the bowl EMPTY\n", name);
  s.set_scale(1.0);
  s.tare(15);
  Serial.println("Raw readings (no calibration). Press a key to stop.");
  while (!stopRequested()) {
    if (s.wait_ready_timeout(500)) Serial.printf("%s raw: %ld\n", name, (long)s.get_value(5));
    delay(300);
  }
}

String readLine() {
  while (!Serial.available()) delay(10);
  String l = Serial.readStringUntil('\n');
  l.trim();
  return l;
}

void calibrate() {
  Serial.println("Which load cell? (A/B)");
  String which = readLine();
  HX711& s = (which == "B" || which == "b") ? scaleB : scaleA;
  if (!s.wait_ready_timeout(1000)) { Serial.println("HX711 not responding"); return; }
  s.set_scale(1.0);
  Serial.println("Remove everything from the bowl, then press Enter");
  readLine();
  s.tare(20);
  Serial.println("Put a KNOWN weight on the bowl (e.g. a 100 g item weighed on a kitchen scale)");
  Serial.println("Type its weight in grams and press Enter:");
  float known = readLine().toFloat();
  if (known <= 0) { Serial.println("Invalid weight"); return; }
  float raw = s.get_value(20);
  float factor = raw / known;
  s.set_scale(factor);
  Serial.printf("\nCALIBRATION FACTOR = %.3f\n", factor);
  Serial.printf("Check: scale now reads %.1f g\n", s.get_units(10));
  Serial.println("The main firmware: type 'tare A' then 'cal A 100' in its serial monitor - it saves this automatically.");
}

void printMenu() {
  Serial.println("\n===== HARDWARE TEST =====");
  Serial.println("1 DHT22 | 2 Scale A | 3 Scale B | 4 Calibrate | 5 Dist feeder | 6 Dist water");
  Serial.println("7 Water level | 8 Servo A | 9 Servo B | 0 Servo C | p Pump | f Fan | i Pins");
}

void setup() {
  Serial.begin(115200);
  delay(500);
  pinMode(PIN_RELAY_PUMP, OUTPUT);
  pinMode(PIN_RELAY_FAN, OUTPUT);
  relay(PIN_RELAY_PUMP, false);
  relay(PIN_RELAY_FAN, false);
  pinMode(PIN_US_FEED_TRIG, OUTPUT);
  pinMode(PIN_US_FEED_ECHO, INPUT);
  pinMode(PIN_US_WATER_TRIG, OUTPUT);
  pinMode(PIN_US_WATER_ECHO, INPUT);
  pinMode(PIN_WATER_PWR, OUTPUT);
  digitalWrite(PIN_WATER_PWR, LOW);
  analogReadResolution(12);

  dht.begin();
  scaleA.begin(PIN_HX_A_DT, PIN_HX_A_SCK);
  scaleB.begin(PIN_HX_B_DT, PIN_HX_B_SCK);

  ESP32PWM::allocateTimer(0);
  ESP32PWM::allocateTimer(1);
  ESP32PWM::allocateTimer(2);
  ESP32PWM::allocateTimer(3);
  servoA.setPeriodHertz(50); servoA.attach(PIN_SERVO_A, 500, 2400); servoA.write(0);
  servoB.setPeriodHertz(50); servoB.attach(PIN_SERVO_B, 500, 2400); servoB.write(0);
  servoC.setPeriodHertz(50); servoC.attach(PIN_SERVO_C, 500, 2400); servoC.write(0);
  printMenu();
}

void loop() {
  if (!Serial.available()) { delay(20); return; }
  char c = Serial.read();
  while (Serial.available()) Serial.read();

  switch (c) {
    case '1': {
      delay(2000);
      float t = dht.readTemperature(), h = dht.readHumidity();
      if (isnan(t) || isnan(h)) Serial.println("DHT22 read FAILED - check DATA pin 4, 3.3V, GND, 10k pull-up");
      else Serial.printf("Temperature %.1f C, Humidity %.1f %%\n", t, h);
      break;
    }
    case '2': liveScale(scaleA, "A"); break;
    case '3': liveScale(scaleB, "B"); break;
    case '4': calibrate(); break;
    case '5':
    case '6': {
      bool feed = c == '5';
      Serial.println("Move your hand in front of the sensor. Press a key to stop.");
      while (!stopRequested()) {
        long d = feed ? distanceCm(PIN_US_FEED_TRIG, PIN_US_FEED_ECHO)
                      : distanceCm(PIN_US_WATER_TRIG, PIN_US_WATER_ECHO);
        if (d < 0) Serial.println("no echo (out of range or ECHO not wired)");
        else Serial.printf("%s: %ld cm\n", feed ? "Feeder" : "Water", d);
        delay(250);
      }
      break;
    }
    case '7':
      Serial.println("Write down the value DRY (in air) and FULL (water at the line you want).");
      Serial.println("Put them in WATER_RAW_DRY / WATER_RAW_FULL. Press a key to stop.");
      while (!stopRequested()) { Serial.printf("Water raw: %d\n", waterRaw()); delay(500); }
      break;
    case '8': sweep(servoA, "A"); break;
    case '9': sweep(servoB, "B"); break;
    case '0': sweep(servoC, "C"); break;
    case 'p':
      Serial.println("Pump ON 2 s (make sure the pump inlet is under water!)");
      relay(PIN_RELAY_PUMP, true); delay(2000); relay(PIN_RELAY_PUMP, false);
      Serial.println("Pump OFF. If the relay clicked but never released, see SETUP_GUIDE relay note.");
      break;
    case 'f':
      Serial.println("Fan ON 5 s");
      relay(PIN_RELAY_FAN, true); delay(5000); relay(PIN_RELAY_FAN, false);
      Serial.println("Fan OFF");
      break;
    case 'i':
      Serial.println("DHT 4 | HX-A 16/17 | HX-B 18/19 | US feed 23/34 | US water 22/35");
      Serial.println("Servo A 13, B 14, C 27 | Water S 32, + 33 | Relay pump 25, fan 26");
      break;
    default: break;
  }
  printMenu();
}
