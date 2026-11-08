#!/usr/bin/env python3
"""
Smart Pet Care and Monitoring System - Raspberry Pi bridge

Runs on the Raspberry Pi 3 and links the ESP32 with Firebase and the app:

   ESP32 <--MQTT--> pi_bridge.py <--Firebase--> Flutter app

What it does:
  1. Sends the ESP32 sensor data (temperature, bowl weights, water level...) to Firebase.
  2. Sends commands and settings from the app (feed, water, fan...) to the ESP32.
  3. When the ESP32 sees a pet at the feeder, runs the YOLOv11 model on the camera,
     finds which pet it is, checks its meal plan and tells the ESP32 how much food
     to give from which hopper. Unknown animal / no profile / meal limit -> no food.
  4. Saves feedings, how much was eaten, logs and alerts.
  5. Camera mode from the app (auto / on / off) and the live view.

Run:  python3 pi_bridge.py      (Ctrl+C, or 'q' in the preview window, to stop)
"""
import base64
import json
import logging
import os
import queue
import signal
import threading
import time
import uuid
from collections import defaultdict
from datetime import datetime

# Show the preview on the Pi's own screen even when started over SSH.
os.environ.setdefault("DISPLAY", ":0")

import cv2
import firebase_admin
import numpy as np
import paho.mqtt.client as mqtt
from firebase_admin import credentials, db

import config as C
from detector import PetDetector, species_of

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                    datefmt="%H:%M:%S")
log = logging.getLogger("bridge")

BASE_TOPIC = f"petfeeder/{C.DEVICE_ID}"
T_TELEMETRY = f"{BASE_TOPIC}/telemetry"
T_EVENT = f"{BASE_TOPIC}/event"
T_STATUS = f"{BASE_TOPIC}/status"
T_CMD = f"{BASE_TOPIC}/cmd"
T_CONFIG = f"{BASE_TOPIC}/config"
DEVICE_PATH = f"devices/{C.DEVICE_ID}"


def now_ms() -> int:
    return int(time.time() * 1000)


def today_key() -> str:
    return datetime.now().strftime("%Y-%m-%d")


# --- Firebase ---
# All writes go through one worker thread, so slow internet never blocks MQTT or the camera.
class Cloud:
    def __init__(self):
        cred = credentials.Certificate(C.SERVICE_ACCOUNT_FILE)
        firebase_admin.initialize_app(cred, {"databaseURL": C.DATABASE_URL})
        self.root = db.reference(DEVICE_PATH)
        self._q: "queue.Queue" = queue.Queue(maxsize=500)
        threading.Thread(target=self._worker, daemon=True, name="rtdb-writer").start()
        self._alert_last = {}

    def ref(self, path: str):
        return self.root.child(path)

    def _worker(self):
        while True:
            fn, args = self._q.get()
            try:
                fn(*args)
            except Exception as e:   # keep the bridge running
                log.warning("Firebase write failed: %s", e)

    def submit(self, fn, *args):
        try:
            self._q.put_nowait((fn, args))
        except queue.Full:
            log.warning("Firebase queue full - dropping a write (no internet?)")

    # short helpers
    def update(self, path: str, data: dict):
        self.submit(lambda p, d: self.ref(p).update(d), path, data)

    def set(self, path: str, value):
        self.submit(lambda p, v: self.ref(p).set(v), path, value)

    def push(self, path: str, data: dict):
        self.submit(lambda p, d: self.ref(p).push(d), path, data)

    def log(self, kind: str, message: str, level: str = "info"):
        log.info("[%s] %s", kind, message)
        self.push("logs", {"ts": now_ms(), "type": kind, "level": level, "message": message})

    def alert(self, key: str, kind: str, title: str, message: str):
        """Raise an alert, at most once per ALERT_COOLDOWN_S for the same key."""
        last = self._alert_last.get(key, 0)
        if time.time() - last < C.ALERT_COOLDOWN_S:
            return
        self._alert_last[key] = time.time()
        log.warning("ALERT %s: %s", title, message)
        self.push("alerts", {"ts": now_ms(), "type": kind, "title": title,
                             "message": message, "read": False})

    def prune(self):
        """Delete history/logs older than KEEP_HISTORY_DAYS (needs .indexOn ts)."""
        cutoff = now_ms() - C.KEEP_HISTORY_DAYS * 24 * 3600 * 1000
        for path in ("history/env", "logs"):
            try:
                old = self.ref(path).order_by_child("ts").end_at(cutoff).get() or {}
                if old:
                    self.ref(path).update({k: None for k in old.keys()})
                    log.info("Pruned %d old entries from %s", len(old), path)
            except Exception as e:
                log.warning("Prune of %s failed: %s", path, e)


# --- Bridge ---
_SCREEN = None


def screen_size():
    """Size of the Pi's desktop in pixels (the LCD may run a scaled desktop)."""
    global _SCREEN
    if _SCREEN is None:
        import re
        import subprocess
        _SCREEN = (480, 320)
        for cmd, pat in ((["xdpyinfo"], r"dimensions:\s+(\d+)x(\d+)"),
                         (["xrandr"], r"current (\d+) x (\d+)")):
            try:
                out = subprocess.run(cmd, capture_output=True, text=True, timeout=3).stdout
                m = re.search(pat, out)
                if m:
                    _SCREEN = (int(m.group(1)), int(m.group(2)))
                    break
            except Exception:
                pass
    return _SCREEN


class Camera:
    """Starts and stops the camera on demand, so it can rest between pets."""

    def __init__(self):
        self.cam = None          # Picamera2 object (created once)
        self.cap = None          # OpenCV VideoCapture (USB fallback)
        self.running = False

    def start(self) -> bool:
        if self.running:
            return True
        try:
            try:
                from picamera2 import Picamera2
            except ImportError:
                Picamera2 = None
            if Picamera2 is not None:
                if self.cam is None:
                    self.cam = Picamera2()
                    kwargs = {}
                    if getattr(C, "CAMERA_ROTATE_180", False):
                        from libcamera import Transform
                        kwargs["transform"] = Transform(hflip=1, vflip=1)
                    self.cam.configure(self.cam.create_preview_configuration(
                        main={"size": C.CAMERA_SIZE, "format": C.CAMERA_FORMAT}, **kwargs))
                self.cam.start()
            else:
                self.cap = cv2.VideoCapture(C.USB_CAMERA_INDEX)
                self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, C.CAMERA_SIZE[0])
                self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, C.CAMERA_SIZE[1])
            time.sleep(getattr(C, "CAMERA_WARMUP_S", 1.5))
            self.running = True
            log.info("Camera started")
            return True
        except Exception as e:   # ribbon loose, camera busy...
            log.error("Camera could not start: %s", e)
            self.running = False
            return False

    def grab(self):
        if not self.running:
            return None
        try:
            frame = self.cam.capture_array() if self.cam is not None else self.cap.read()[1]
        except Exception as e:
            log.warning("Camera read failed: %s", e)
            return None
        if frame is not None and frame.ndim == 3 and frame.shape[2] == 4:   # XRGB -> BGR
            frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)
        return frame

    def stop(self):
        if not self.running:
            return
        try:
            if self.cam is not None:
                self.cam.stop()
            if self.cap is not None:
                self.cap.release()
                self.cap = None
        except Exception as e:
            log.warning("Camera stop: %s", e)
        self.running = False
        log.info("Camera resting")

    def close(self):
        self.stop()
        if self.cam is not None:
            try:
                self.cam.close()
            except Exception:
                pass


class Bridge:
    def __init__(self):
        self.cloud = Cloud()
        self.lock = threading.RLock()
        self.running = True

        # caches of what the app configured
        self.config = {"compartments": {}, "tempThreshold": 30, "fanMode": "auto",
                       "waterAuto": True, "petTopUp": True, "presenceCm": 25, "wakeCm": 30,
                       "cameraMode": getattr(C, "DEFAULT_CAMERA_MODE", "auto"),
                       "minConfidence": C.DEFAULT_MIN_CONFIDENCE}
        self.pets = {}

        # live ESP32 state
        self.telemetry = {}
        self.esp_online = False
        self.esp_last_seen = 0.0
        self.last_env_saved = 0.0
        self.fan_on = None                # cooling fan state, None = not known yet
        self.fan_on_since = 0.0
        self.config_loaded = False

        # feeding bookkeeping
        self.pending = {}                 # requestId -> info about who asked
        self.last_feed_by_comp = {}       # comp -> {key, bowlAfter, ts, petName}
        self.processed_cmds = set()

        # camera verification request (set from MQTT thread, run by camera loop)
        self.verify_event = threading.Event()
        self.verify_feed = True
        self.last_verify_done = 0.0
        self.overlay = "Waiting for pet..."
        self.overlay_until = 0.0          # after this time the preview goes back to "Waiting"

        # camera power + live view
        self.camera = Camera()
        self.awake_until = 0.0            # auto mode: keep the camera on until this time
        self.live_until = 0.0             # live view requested until this time
        self.latest_frame = None
        self.latest_frame_ts = 0.0
        self.camera_reported = None       # last (mode, running) written to Firebase

        log.info("Loading detector (%s)...", C.DETECTOR_BACKEND)
        self.detector = PetDetector(C.DETECTOR_BACKEND, C.MODEL_PATH, C.IMG_SIZE,
                                    C.ROBOFLOW_MODEL_ID, C.ROBOFLOW_API_KEY,
                                    class_names=getattr(C, "CLASS_NAMES", None),
                                    workflow_url=getattr(C, "ROBOFLOW_WORKFLOW_URL", ""))

        self.mqtt = self._make_mqtt()

    # --- MQTT ---
    def _make_mqtt(self):
        client_id = f"pi-bridge-{C.DEVICE_ID}"
        try:  # paho-mqtt 2.x
            client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=client_id)
        except AttributeError:  # paho-mqtt 1.x
            client = mqtt.Client(client_id=client_id)
        if C.MQTT_USER:
            client.username_pw_set(C.MQTT_USER, C.MQTT_PASS)
        client.on_connect = self._on_connect
        client.on_disconnect = self._on_disconnect
        client.on_message = self._on_message
        client.reconnect_delay_set(min_delay=1, max_delay=30)
        return client

    def _on_connect(self, client, userdata, flags, rc, properties=None):
        failed = rc.is_failure if hasattr(rc, "is_failure") else rc != 0
        if failed:
            log.error("MQTT connect failed: %s (check user/password in config.py)", rc)
            return
        log.info("MQTT connected to %s:%s", C.MQTT_HOST, C.MQTT_PORT)
        client.subscribe([(T_TELEMETRY, 0), (T_EVENT, 1), (T_STATUS, 1)])
        self.publish_config()

    def _on_disconnect(self, client, userdata, *args):
        log.warning("MQTT disconnected - will retry")

    def send_cmd(self, payload: dict):
        log.info("-> ESP32 %s", payload)
        self.mqtt.publish(T_CMD, json.dumps(payload), qos=1)

    def publish_config(self):
        cfg = {k: self.config.get(k) for k in ("tempThreshold", "fanMode", "waterAuto", "petTopUp",
                                                "presenceCm", "wakeCm")}
        self.mqtt.publish(T_CONFIG, json.dumps(cfg), qos=1, retain=True)

    def _on_message(self, client, userdata, msg):
        try:
            if msg.topic == T_STATUS:
                self.on_status(msg.payload.decode())
                return
            data = json.loads(msg.payload.decode() or "{}")
            if msg.topic == T_TELEMETRY:
                self.on_telemetry(data)
            elif msg.topic == T_EVENT:
                self.on_event(data)
        except Exception as e:
            log.exception("Error handling %s: %s", msg.topic, e)

    # --- ESP32 -> Firebase ---
    def on_status(self, text: str):
        online = text.strip() == "online"
        if online == self.esp_online:
            return
        self.esp_online = online
        self.cloud.update("status", {"espOnline": online})
        if online:
            self.cloud.log("system", "Feeder (ESP32) connected")
        else:
            self.fan_on = None            # fan state unknown until the ESP32 is back
            self.cloud.update("status", {"fanOnSince": None})
            self.cloud.log("system", "Feeder (ESP32) went offline", "warn")
            self.cloud.alert("esp-offline", "device", "Feeder offline",
                             "The ESP32 lost its connection. Check power and Wi-Fi.")

    def on_telemetry(self, t: dict):
        with self.lock:
            self.telemetry = t
            self.esp_last_seen = time.time()
        self.esp_online = True
        status = {
            "espOnline": True,
            "espLastSeen": now_ms(),
            "temperature": t.get("temperature"),
            "humidity": t.get("humidity"),
            "bowls": {"A": t.get("bowlA"), "B": t.get("bowlB")},
            "waterPct": t.get("waterPct"),
            "waterRaw": t.get("waterRaw"),
            "waterCalEmpty": t.get("waterCalEmpty"),
            "waterCalFull": t.get("waterCalFull"),
            "waterCalHalf": t.get("waterCalHalf"),
            "waterLow": t.get("waterLow", False),
            "reservoirEmpty": t.get("reservoirEmpty", False),
            "pumpOn": t.get("pumpOn", False),
            "fanOn": t.get("fanOn", False),
            "fanMode": t.get("fanMode", "auto"),
            "feederPresence": t.get("feederPresence", False),
            "waterPresence": t.get("waterPresence", False),
            "dispensing": t.get("dispensing", False),
            "rssi": t.get("rssi"),
        }
        self.cloud.update("status", status)

        # The fan event can be missed (for example the fan turns on at boot before
        # MQTT is connected), so the fan state in the telemetry is checked too.
        self.fan_changed(bool(t.get("fanOn")), "auto" if t.get("fanMode", "auto") == "auto" else "manual",
                         t.get("temperature"))

        temp = t.get("temperature")
        if time.time() - self.last_env_saved >= C.ENV_HISTORY_EVERY_S and temp is not None:
            self.last_env_saved = time.time()
            self.cloud.push("history/env", {"ts": now_ms(), "temperature": temp,
                                            "humidity": t.get("humidity")})

        limit = float(self.config.get("tempThreshold") or 30)
        if temp is not None and temp >= limit + C.HIGH_TEMP_MARGIN_C:
            fan = "running" if t.get("fanOn") else "OFF (manual mode!)"
            self.cloud.alert("high-temp", "temperature", "High temperature",
                             f"Room is {temp:.1f} °C (limit {limit:.0f} °C). Cooling fan is {fan}.")

    def on_event(self, e: dict):
        kind = e.get("type")
        if kind == "boot":
            self.cloud.log("system", f"Feeder booted (firmware {e.get('fw')}, IP {e.get('ip')})")
            self.publish_config()

        elif kind == "motion":
            # Something is moving in front of the feeder (wake distance, ~30 cm):
            # start the camera early so it is ready when the pet reaches the bowl.
            if e.get("zone") == "feeder" and self.camera_mode() == "auto":
                if not self.camera.running:
                    log.info("Movement at %s cm - waking camera", e.get("distCm"))
                self.wake_camera()

        elif kind == "presence":
            zone, present = e.get("zone"), bool(e.get("present"))
            if zone == "feeder" and present:
                self.request_verification(feed=True)
            elif zone == "feeder" and not present:
                threading.Timer(C.CONSUMPTION_DELAY_S, self.measure_consumption).start()
            elif zone == "water" and present:
                self.cloud.log("water", "A pet came to drink")

        elif kind == "dispense_done":
            self.on_dispense_done(e)

        elif kind == "water":
            secs = e.get("seconds", 0)
            reason = {"low_level": "bowl was low", "pet_present": "pet came to drink",
                      "manual": "requested from app",
                      "fill": "fill to full from app"}.get(e.get("reason"), e.get("reason"))
            if e.get("stop") == "already_full":
                self.cloud.log("water", f"Fill to full: bowl is already full ({e.get('levelAfter')}%)")
            else:
                self.cloud.log("water", f"Water pump ran {secs:.1f} s ({reason}), "
                                        f"level {e.get('levelBefore')}% -> {e.get('levelAfter')}%")
            if e.get("reservoirEmpty"):
                self.cloud.alert("reservoir", "water", "Water tank empty",
                                 "The pump ran but the bowl did not fill. Please refill the water tank.")

        elif kind == "fan":
            self.fan_changed(bool(e.get("on")), e.get("reason", "auto"), e.get("temperature"))

        elif kind == "water_cal":
            point = {"empty": "EMPTY", "dry": "EMPTY", "half": "HALF"}.get(e.get("point"), "FULL")
            if e.get("ok"):
                half = e.get("half")
                half_txt = f", half {half}" if isinstance(half, int) and half >= 0 else ""
                self.cloud.log("water", f"Water sensor {point} point saved (raw {e.get('raw')}). "
                                        f"Calibration: empty {e.get('empty')}{half_txt}, full {e.get('full')}")
            else:
                self.cloud.log("water", f"Water sensor {point} calibration rejected (raw {e.get('raw')}) - "
                                        "is the sensor in the water and wired correctly?", "warn")

        elif kind == "tare":
            ok = "done" if e.get("ok") else "FAILED (check load cell wiring)"
            self.cloud.log("system", f"Bowl {e.get('compartment')} tare {ok}")

    def fan_changed(self, on: bool, reason: str, temp=None):
        """Log the cooling fan turning on or off, once per change."""
        if on == self.fan_on:
            return
        first = self.fan_on is None
        self.fan_on = on
        if first and not on:              # bridge just started and the fan is off: nothing to log
            return
        t = f"{temp:.1f} °C" if isinstance(temp, (int, float)) else "-- °C"
        limit = float(self.config.get("tempThreshold") or 30)
        if on:
            self.fan_on_since = time.time()
            msg = (f"Cooling fan ON - room is {t} (limit {limit:.0f} °C)" if reason == "auto"
                   else f"Cooling fan ON - set to ON in the app (room {t})")
        else:
            secs = time.time() - self.fan_on_since if self.fan_on_since else 0
            ran = f", ran {secs / 60:.0f} min" if secs >= 60 else (f", ran {secs:.0f} s" if secs >= 1 else "")
            self.fan_on_since = 0.0
            msg = (f"Cooling fan OFF - room is {t} (limit {limit:.0f} °C){ran}" if reason == "auto"
                   else f"Cooling fan OFF - set to OFF in the app{ran}")
        self.cloud.log("fan", msg)
        self.cloud.update("status", {"fanOnSince": int(self.fan_on_since * 1000) if on else None})

    # --- App -> ESP32 ---
    def start_firebase_listeners(self):
        self.cloud.ref("config").listen(lambda ev: self.reload_config())
        self.cloud.ref("pets").listen(lambda ev: self.reload_pets())
        self.cloud.ref("commands").listen(lambda ev: self.process_commands())

    def reload_config(self):
        cfg = self.cloud.ref("config").get() or {}
        old_mode = self.camera_mode()
        with self.lock:
            old_fan = (self.config.get("fanMode"), self.config.get("tempThreshold"))
            self.config.update(cfg)
            new_fan = (self.config.get("fanMode"), self.config.get("tempThreshold"))
        new_mode = self.camera_mode()
        first = not self.config_loaded
        self.config_loaded = True
        # ON / OFF from the app is logged when the fan really switches (fan_changed)
        if not first and new_fan[0] != old_fan[0] and str(new_fan[0]).lower() == "auto":
            self.cloud.log("fan", f"Fan set to AUTO from the app (turns on at {float(new_fan[1] or 30):.0f} °C)")
        elif not first and new_fan[1] != old_fan[1]:
            self.cloud.log("fan", f"Fan temperature limit set to {float(new_fan[1] or 30):.0f} °C")
        demo = bool(self.config.get("demoMode"))
        if demo != getattr(self, "_demo_logged", False):
            self._demo_logged = demo
            self.cloud.log("system", "Demo mode ON - meal limits ignored" if demo else "Demo mode OFF",
                           "warn" if demo else "info")
        if new_mode != old_mode:
            if not first:
                self.cloud.log("camera", f"Camera mode set to {new_mode.upper()} from the app")
            if new_mode == "off":
                self.live_until = 0.0
            self.report_camera(force=True)
        log.info("Config: %s", {k: v for k, v in self.config.items()})
        self.publish_config()

    def reload_pets(self):
        pets = self.cloud.ref("pets").get() or {}
        with self.lock:
            self.pets = pets if isinstance(pets, dict) else {}
        names = [p.get("name") for p in self.pets.values() if isinstance(p, dict)]
        log.info("Pets loaded: %s", names)

    def process_commands(self):
        cmds = self.cloud.ref("commands").get() or {}
        if not isinstance(cmds, dict):
            return
        for cid, cmd in cmds.items():
            if cid in self.processed_cmds or not isinstance(cmd, dict):
                continue
            self.processed_cmds.add(cid)
            try:
                self.handle_command(cid, cmd)
            finally:
                self.cloud.ref(f"commands/{cid}").delete()

    def handle_command(self, cid: str, cmd: dict):
        action = cmd.get("action")
        ts = cmd.get("ts") or now_ms()
        if now_ms() - int(ts) > 10 * 60 * 1000:
            self.cloud.log("command", f"Ignored old '{action}' command (queued while offline)", "warn")
            return
        if action == "dispense":
            comp = "B" if cmd.get("compartment") == "B" else "A"
            grams = float(cmd.get("grams") or 20)
            species = (self.config.get("compartments", {}).get(comp) or {}).get("species")
            self.pending[cid] = {"source": "manual", "petId": None, "petName": "Manual feed",
                                 "species": species or "-", "breed": None}
            self.send_cmd({"action": "dispense", "compartment": comp, "grams": grams,
                           "requestId": cid, "source": "manual"})
            self.cloud.log("command", f"Manual feed requested: {grams:.0f} g from compartment {comp}")
        elif action == "water":
            if cmd.get("mode") == "fill":
                self.send_cmd({"action": "water", "mode": "fill"})
                self.cloud.log("command", "Fill to full requested")
            else:
                secs = int(cmd.get("seconds") or 3)
                self.send_cmd({"action": "water", "seconds": secs})
                self.cloud.log("command", f"Manual water requested ({secs} s)")
        elif action == "water_cal":
            point = cmd.get("point") if cmd.get("point") in ("empty", "half", "full") else "empty"
            self.send_cmd({"action": "water_cal", "point": point})
            self.cloud.log("command", f"Water sensor calibration: save {point.upper()} point")
        elif action == "tare":
            self.send_cmd({"action": "tare", "compartment": cmd.get("compartment", "A")})
        elif action == "identify":
            if self.camera_mode() == "off":
                self.cloud.log("command", "Camera check refused - camera is OFF in the app", "warn")
                return
            self.request_verification(feed=False, force=True)
            self.cloud.log("command", "Camera check requested from the app")
        elif action == "live":
            # The app repeats this every ~15 s while the Live view page is open,
            # and sends seconds = 0 when the page closes.
            secs = max(0, min(int(cmd.get("seconds") or 0), getattr(C, "LIVE_MAX_S", 120)))
            if secs == 0:
                self.live_until = 0.0
                return
            if self.camera_mode() == "off":
                self.cloud.update("live", {"active": False, "state": "off", "ts": now_ms()})
                return
            if time.time() >= self.live_until:
                self.cloud.log("camera", "Live view opened in the app")
            self.live_until = time.time() + secs
            self.wake_camera(secs + 5)
        else:
            log.warning("Unknown command %s", cmd)

    # --- Camera power ---
    def camera_mode(self) -> str:
        mode = str(self.config.get("cameraMode") or "auto").lower()
        return mode if mode in ("auto", "on", "off") else "auto"

    def wake_camera(self, seconds: float = None):
        """Auto mode: keep the camera on for a while (extends, never shortens)."""
        secs = seconds if seconds is not None else getattr(C, "CAMERA_IDLE_S", 60)
        self.awake_until = max(self.awake_until, time.time() + secs)

    def camera_wanted(self) -> bool:
        mode = self.camera_mode()
        if mode == "on":
            return True
        if mode == "off":
            return False
        now = time.time()
        return now < self.awake_until or now < self.live_until or self.verify_event.is_set()

    def report_camera(self, force: bool = False):
        state = (self.camera_mode(), self.camera.running)
        if force or state != self.camera_reported:
            self.camera_reported = state
            self.cloud.update("status", {"cameraMode": state[0], "cameraOn": state[1]})

    def request_verification(self, feed: bool, force: bool = False):
        cooldown = 5 if self.config.get("demoMode") else C.VERIFY_COOLDOWN_S
        remaining = cooldown - (time.time() - self.last_verify_done)
        if not force and remaining > 0:
            # Another pet may have walked up right after the last one: check
            # again when the cooldown ends, if something is still there.
            log.info("Presence during cooldown - re-checking in %.0f s", remaining)
            def retry():
                if self.telemetry.get("feederPresence"):
                    self.request_verification(feed=feed, force=True)
            threading.Timer(remaining + 0.5, retry).start()
            return
        if self.verify_event.is_set():
            return
        if self.camera_mode() == "off":
            if feed:
                self.set_overlay("Pet at feeder - camera is OFF, no automatic feeding", 15)
                self.cloud.log("detect", "Pet at the feeder, but the camera is switched OFF in the app "
                                         "- no automatic feeding", "warn")
            return
        self.wake_camera()
        self.verify_feed = feed
        self.overlay = "Pet at feeder - identifying..."
        self.verify_event.set()

    def set_overlay(self, text: str, seconds: float = 15):
        """Show a message on the preview for a while, then go back to waiting."""
        self.overlay = text
        self.overlay_until = time.time() + seconds

    def match_pet(self, label: str, species: str):
        """Exact breed first, then any enabled pet of the same species."""
        with self.lock:
            pets = [(pid, p) for pid, p in self.pets.items()
                    if isinstance(p, dict) and p.get("enabled", True) and p.get("species") == species]
        for pid, p in pets:
            if p.get("breed") == label:
                return pid, p
        if pets:
            return sorted(pets, key=lambda x: str(x[1].get("name", "")))[0]
        return None, None

    def compartment_for(self, species: str):
        comps = self.config.get("compartments") or {}
        for cid in ("A", "B"):
            if (comps.get(cid) or {}).get("species") == species:
                return cid
        return None

    def decide(self, label, confidence, image_b64, feed: bool):
        """The core rule: right species, right compartment, right portion."""
        species = species_of(label)
        decision, message = "denied", ""
        demo = bool(self.config.get("demoMode"))   # app switch: ignore meal limits
        pet_id, pet = (None, None)

        if label is None:
            decision, message = "unknown", "No known pet recognised"
            if feed:
                self.cloud.alert("unknown-animal", "pet", "Unrecognised animal at the feeder",
                                 "Something triggered the feeder but the camera could not identify it. "
                                 "No food given.")
        else:
            pet_id, pet = self.match_pet(label, species)
            comp = self.compartment_for(species)
            stats = (pet or {}).get("stats") or {}
            meals_today = stats.get("mealsToday", 0) if stats.get("date") == today_key() else 0
            last_fed = (stats.get("lastFedAt") or 0) / 1000
            gap_s = int((pet or {}).get("minGapMinutes", 180)) * 60

            if pet is None:
                message = f"{species} ({label.replace('_', ' ')}) has no profile - no food given"
                self.cloud.alert(f"no-profile-{species}", "pet", f"Unregistered {species.lower()}",
                                 f"A {label.replace('_', ' ')} came to the feeder but has no pet profile.")
            elif comp is None:
                message = f"No compartment holds {species.lower()} food - no food given"
                self.cloud.alert(f"no-comp-{species}", "food", f"No {species.lower()} food loaded",
                                 f"{pet.get('name')} came to eat but no compartment is set to {species} food.")
            elif not feed:
                decision, message = "checked", f"Recognised {pet.get('name')} (test only, no food)"
            elif not self.esp_online:
                message = "Feeder offline"
            elif self.telemetry.get("dispensing"):
                message = "Feeder busy"
            elif not demo and meals_today >= int(pet.get("mealsPerDay", 2)):
                message = f"{pet.get('name')} already had all {pet.get('mealsPerDay')} meals today"
            elif not demo and last_fed and time.time() - last_fed < gap_s:
                wait_min = int((gap_s - (time.time() - last_fed)) / 60) + 1
                message = f"{pet.get('name')} ate recently - next meal in {wait_min} min"
            else:
                grams = float(pet.get("portionG") or 20)
                request_id = uuid.uuid4().hex[:12]
                self.pending[request_id] = {"source": "auto", "petId": pet_id, "petName": pet.get("name"),
                                            "species": species, "breed": label}
                self.send_cmd({"action": "dispense", "compartment": comp, "grams": grams,
                               "requestId": request_id, "source": "auto"})
                decision = "dispensed"
                message = f"Feeding {pet.get('name')} {grams:.0f} g from compartment {comp}"
                if demo:
                    message += " (demo mode)"

        self.set_overlay(message, 60 if decision == "dispensed" else 15)
        self.cloud.update("status", {"lastDetection": {
            "label": label or "-", "species": species, "confidence": round(confidence, 3),
            "ts": now_ms(), "decision": decision, "message": message, "image": image_b64,
            "petId": pet_id,
        }})
        level = "info" if decision in ("dispensed", "checked") else "warn"
        pretty = label.replace("_", " ") if label else "unknown"
        self.cloud.log("detect", f"Camera: {pretty} ({confidence * 100:.0f}%) - {message}", level)

        if decision == "denied" and feed:
            self.cloud.push("feedings", {
                "ts": now_ms(), "petId": pet_id, "petName": (pet or {}).get("name", pretty),
                "species": species, "breed": label, "compartment": "-", "targetG": 0,
                "dispensedG": 0, "ok": False, "reason": message, "source": "auto"})

    # --- Feeding results ---
    def on_dispense_done(self, e: dict):
        rid = e.get("requestId", "")
        info = self.pending.pop(rid, None) or {"source": e.get("source", "auto"), "petId": None,
                                               "petName": "Unknown", "species": "-", "breed": None}
        comp = e.get("compartment", "-")
        dispensed = float(e.get("dispensedG") or 0)
        ok = bool(e.get("ok"))
        reason = e.get("reason", "")
        ts = now_ms()

        record = {"ts": ts, "petId": info["petId"], "petName": info["petName"],
                  "species": info["species"], "breed": info["breed"], "compartment": comp,
                  "targetG": e.get("targetG"), "dispensedG": dispensed, "ok": ok,
                  "reason": reason, "source": info["source"]}

        def write_feeding():
            ref = self.cloud.ref("feedings").push(record)
            if ok and dispensed > 0:      # only measure eating when food actually came out
                self.last_feed_by_comp[comp] = {"key": ref.key, "bowlAfter": e.get("bowlAfterG"),
                                                "ts": time.time(), "petName": info["petName"]}
        self.cloud.submit(write_feeding)

        self.set_overlay(f"Fed {info['petName']} {dispensed:.0f} g from {comp}" if ok
                         else f"Feeding failed ({reason})", 15)
        if ok:
            self.cloud.log("feed", f"{info['petName']}: dispensed {dispensed:.0f} g "
                                   f"of {float(e.get('targetG') or 0):.0f} g from compartment {comp}")
            if info["petId"]:
                self.cloud.submit(self._bump_stats, info["petId"], dispensed)
        else:
            self.cloud.log("feed", f"Dispense from {comp} failed: {reason}", "error")
        if "hopper_empty" in reason or reason == "timeout":
            self.cloud.alert(f"hopper-{comp}", "food", f"Compartment {comp} may be empty",
                             f"Only {dispensed:.0f} g came out. Refill or check for a jam.")
        if reason == "scale_error":
            self.cloud.alert(f"scale-{comp}", "device", f"Load cell {comp} error",
                             "The HX711 did not respond. Check its wiring.")

    def _bump_stats(self, pet_id: str, grams: float):
        def tx(current):
            current = current or {}
            if current.get("date") != today_key():
                current = {"date": today_key(), "mealsToday": 0, "gramsToday": 0}
            current["mealsToday"] = int(current.get("mealsToday", 0)) + 1
            current["gramsToday"] = round(float(current.get("gramsToday", 0)) + grams, 1)
            current["lastFedAt"] = now_ms()
            return current
        self.cloud.ref(f"pets/{pet_id}/stats").transaction(tx)

    def measure_consumption(self):
        """After the pet walks away, compare bowl weight with right after feeding."""
        for comp, info in list(self.last_feed_by_comp.items()):
            if info.get("measured") or time.time() - info["ts"] > 30 * 60:
                continue
            after = info.get("bowlAfter")
            now_w = self.telemetry.get(f"bowl{comp}")
            if after is None or now_w is None:
                continue
            eaten = max(0.0, round(float(after) - float(now_w), 1))
            info["measured"] = True
            self.cloud.update(f"feedings/{info['key']}", {"eatenG": eaten, "leftoverG": now_w})
            self.cloud.log("feed", f"{info['petName']} ate about {eaten:.0f} g "
                                   f"({max(0.0, float(now_w)):.0f} g left in bowl {comp})")

    # --- Heartbeat ---
    def heartbeat_loop(self):
        last_prune = 0.0
        while self.running:
            self.cloud.update("status", {"piLastSeen": now_ms(), "piOnline": True})
            if self.esp_online and time.time() - self.esp_last_seen > C.ESP_OFFLINE_AFTER_S:
                self.on_status("offline")
            if time.time() - last_prune > 6 * 3600:
                last_prune = time.time()
                self.cloud.submit(self.cloud.prune)
            time.sleep(C.HEARTBEAT_S)

    # --- Camera and recognition ---
    @staticmethod
    def snapshot_b64(frame, det=None, width: int = 320, quality: int = 60, stamp: str = "") -> str:
        img = frame.copy()
        if det is not None:
            x1, y1, x2, y2 = det.box
            cv2.rectangle(img, (x1, y1), (x2, y2), (0, 200, 0), 3)
            cv2.putText(img, f"{det.label} {det.confidence:.2f}", (x1, max(20, y1 - 8)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 200, 0), 2)
        h, w = img.shape[:2]
        scale = width / float(w)
        img = cv2.resize(img, (width, int(h * scale)))
        if stamp:
            cv2.putText(img, stamp, (6, img.shape[0] - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.45,
                        (255, 255, 255), 1, cv2.LINE_AA)
        ok, jpg = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, quality])
        return base64.b64encode(jpg.tobytes()).decode() if ok else ""

    @staticmethod
    def filter_detections(dets, min_conf):
        """Per-class confidence limits (config.CLASS_MIN_CONF), then prefer a
        specific breed over an "Other_..." class seen in the same frame."""
        limits = getattr(C, "CLASS_MIN_CONF", {}) or {}
        keep = [d for d in dets if d.confidence >= limits.get(d.label, min_conf)]
        keep.sort(key=lambda d: (not d.label.startswith("Other_"), d.confidence), reverse=True)
        return keep

    def run_verification(self, grab):
        """Collect votes from several frames, then decide once."""
        min_conf = float(self.config.get("minConfidence") or C.DEFAULT_MIN_CONFIDENCE)
        votes = defaultdict(list)          # label -> [confidence...]
        best = {}                          # label -> (confidence, frame, det)
        started = time.time()
        last_frame = None
        while self.running and time.time() - started < C.VERIFY_SECONDS:
            frame = grab()
            if frame is None:
                time.sleep(0.05)
                continue
            last_frame = frame
            self.latest_frame, self.latest_frame_ts = frame, time.time()   # live view keeps working
            dets = self.filter_detections(self.detector.detect(frame), min_conf)
            if dets:
                d = dets[0]
                votes[d.label].append(d.confidence)
                if d.label not in best or d.confidence > best[d.label][0]:
                    best[d.label] = (d.confidence, frame, d)
                self.show(frame, f"Seeing {d.label} ({d.confidence:.2f}) {len(votes[d.label])}/{C.MIN_VOTES}", d)
                if len(votes[d.label]) >= C.MIN_VOTES:
                    break
            else:
                self.show(frame, "Identifying...")

        if votes:
            label = max(votes, key=lambda k: (len(votes[k]), sum(votes[k]) / len(votes[k])))
            conf = sum(votes[label]) / len(votes[label])
            if len(votes[label]) < 2:      # a single lucky frame is not enough
                label = None
        else:
            label, conf = None, 0.0

        if label:
            _, frame, det = best[label]
            image = self.snapshot_b64(frame, det)
        else:
            image = self.snapshot_b64(last_frame) if last_frame is not None else ""
        self.decide(label, conf, image, self.verify_feed)
        self.last_verify_done = time.time()
        self.wake_camera()          # auto mode: stay on a little longer after a decision

    # --- LCD text ---
    @staticmethod
    def _fit(text, max_w, scale, thick):
        """Shrink the font only if the text would not fit the screen width."""
        while scale > 0.35:
            (w, _), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, scale, thick)
            if w <= max_w:
                break
            scale -= 0.05
        return scale

    @staticmethod
    def _wrap(text, max_w, scale, thick, max_lines=2):
        """Split a long message over (at most) two lines."""
        words, lines, cur = text.split(), [], ""
        for word in words:
            test = (cur + " " + word).strip()
            (w, _), _ = cv2.getTextSize(test, cv2.FONT_HERSHEY_SIMPLEX, scale, thick)
            if w <= max_w or not cur:
                cur = test
            else:
                lines.append(cur)
                cur = word
        if cur:
            lines.append(cur)
        if len(lines) > max_lines:
            lines = lines[:max_lines]
            lines[-1] = lines[-1].rstrip(".") + "..."
        return lines

    def show(self, frame, status_text, det=None):
        if not C.SHOW_WINDOW or frame is None:
            return
        img = frame.copy()
        if det is not None:
            x1, y1, x2, y2 = det.box
            cv2.rectangle(img, (x1, y1), (x2, y2), (0, 255, 0), 3)
        if C.FULLSCREEN:
            sw, sh = screen_size()
            if (img.shape[1], img.shape[0]) != (sw, sh):
                img = cv2.resize(img, (sw, sh))
        h, w = img.shape[:2]
        k = w / 480.0                       # text sized for the 3.5" LCD (480 px wide)
        thick = max(2, int(round(2 * k)))
        font = cv2.FONT_HERSHEY_SIMPLEX
        margin = int(10 * k)

        t = self.telemetry
        temp = t.get("temperature")
        line1 = f"Temp: {temp:.1f}C" if isinstance(temp, (int, float)) else "Temp: --"
        line1 += f" | Water: {t.get('waterPct', '--')}% | Fan: {'ON' if t.get('fanOn') else 'off'}"
        s1 = self._fit(line1, w - 2 * margin, 0.72 * k, thick)
        s2 = 0.78 * k
        lines2 = self._wrap(status_text, w - 2 * margin, s2, thick) if status_text else []

        line_h1 = int(30 * s1 / 0.72) if k else 30
        line_h2 = int(32 * s2 / 0.78)
        band = margin + line_h1 + len(lines2) * line_h2 + margin // 2
        shade = img.copy()
        cv2.rectangle(shade, (0, 0), (w, band), (0, 0, 0), -1)
        cv2.addWeighted(shade, 0.5, img, 0.5, 0, img)      # dark band = readable text

        y = margin + int(22 * s1 / 0.72)
        cv2.putText(img, line1, (margin, y), font, s1, (255, 255, 255), thick, cv2.LINE_AA)
        for text in lines2:
            y += line_h2
            cv2.putText(img, text, (margin, y), font, s2, (80, 255, 80), thick, cv2.LINE_AA)

        cv2.imshow("Smart Pet Monitor", img)
        if C.FULLSCREEN and not getattr(self, "_placed", False):
            cv2.moveWindow("Smart Pet Monitor", 0, 0)
            cv2.setWindowProperty("Smart Pet Monitor", cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_FULLSCREEN)
            self._placed = True
        if cv2.waitKey(1) & 0xFF == ord("q"):
            self.running = False

    def resting_frame(self):
        """Dark screen for the LCD while the camera is not running."""
        sw, sh = screen_size() if C.FULLSCREEN else C.CAMERA_SIZE
        img = np.zeros((sh, sw, 3), dtype=np.uint8)
        k = sw / 480.0
        mode = self.camera_mode()
        title = "CAMERA OFF" if mode == "off" else "Camera resting"
        sub = ("App turned off, no automatic feeding" if mode == "off"
               else "Wakes up when a pet comes near")
        font = cv2.FONT_HERSHEY_SIMPLEX
        margin = int(20 * k)
        t_scale = self._fit(title, sw - 2 * margin, 1.4 * k, max(3, int(3 * k)))
        s_scale = self._fit(sub, sw - 2 * margin, t_scale / 2, max(2, int(2 * k)))   # half the title size
        (tw, th), _ = cv2.getTextSize(title, font, t_scale, max(3, int(3 * k)))
        (uw, uh), _ = cv2.getTextSize(sub, font, s_scale, max(2, int(2 * k)))
        y = sh // 2 + th // 2
        cv2.putText(img, title, ((sw - tw) // 2, y), font, t_scale, (220, 220, 220),
                    max(3, int(3 * k)), cv2.LINE_AA)
        cv2.putText(img, sub, ((sw - uw) // 2, y + uh + int(24 * k)), font, s_scale,
                    (180, 180, 180), max(2, int(2 * k)), cv2.LINE_AA)
        return img

    def camera_loop(self):
        if C.SHOW_WINDOW:
            cv2.namedWindow("Smart Pet Monitor", cv2.WINDOW_NORMAL)
            if C.FULLSCREEN:
                cv2.setWindowProperty("Smart Pet Monitor", cv2.WND_PROP_FULLSCREEN,
                                      cv2.WINDOW_FULLSCREEN)
        last_fail = 0.0
        try:
            while self.running:
                want = self.camera_wanted()
                if want and not self.camera.running and time.time() - last_fail > 10:
                    if C.SHOW_WINDOW:
                        self.show(self.resting_frame(), "Starting camera...")
                    if not self.camera.start():
                        last_fail = time.time()
                        if self.verify_event.is_set():
                            self.verify_event.clear()
                            self.set_overlay("Camera error - check the ribbon cable", 30)
                            self.cloud.alert("camera-error", "device", "Camera not working",
                                             "The Raspberry Pi could not start the camera. "
                                             "Check the ribbon cable.")
                elif not want and self.camera.running:
                    self.camera.stop()
                    self.latest_frame = None
                self.report_camera()

                if self.camera.running:
                    if self.verify_event.is_set():
                        try:
                            self.run_verification(self.camera.grab)
                        except Exception as e:
                            log.exception("Verification failed: %s", e)
                        finally:
                            self.verify_event.clear()
                        continue
                    frame = self.camera.grab()
                    if frame is not None:
                        self.latest_frame, self.latest_frame_ts = frame, time.time()
                    if self.overlay_until and time.time() > self.overlay_until:
                        self.overlay, self.overlay_until = "Waiting for pet...", 0.0
                    if C.SHOW_WINDOW:
                        self.show(frame, self.overlay)
                    else:
                        time.sleep(0.05)
                else:
                    if self.overlay_until and time.time() > self.overlay_until:
                        self.overlay, self.overlay_until = "Waiting for pet...", 0.0
                    if C.SHOW_WINDOW:
                        # In OFF mode show only real messages, not "Waiting for pet..."
                        msg = self.overlay if (self.overlay_until or self.camera_mode() != "off") else ""
                        self.show(self.resting_frame(), msg)
                    time.sleep(0.25)
        finally:
            self.camera.close()
            if C.SHOW_WINDOW:
                cv2.destroyAllWindows()

    # --- Live view ---
    def live_loop(self):
        """Upload one small picture per second while the app's Live view is open."""
        was_active = False
        last_sent = 0.0
        period = 1.0 / max(0.2, float(getattr(C, "LIVE_FPS", 1.0)))
        while self.running:
            now = time.time()
            active = now < self.live_until and self.camera_mode() != "off"
            if active:
                frame = self.latest_frame
                if frame is not None and now - last_sent >= period and now - self.latest_frame_ts < 3:
                    stamp = "LIVE " + datetime.now().strftime("%H:%M:%S")
                    img = self.snapshot_b64(frame, None, getattr(C, "LIVE_WIDTH", 320),
                                            getattr(C, "LIVE_JPEG_QUALITY", 55), stamp)
                    try:   # direct write (own thread): only the newest picture matters
                        self.cloud.ref("live").set({"active": True, "state": "streaming",
                                                    "ts": now_ms(), "image": img})
                        last_sent = now
                    except Exception as e:
                        log.warning("Live frame upload failed: %s", e)
                        time.sleep(2)
                elif frame is None and not was_active:
                    self.cloud.update("live", {"active": True, "state": "starting", "ts": now_ms()})
                was_active = True
            elif was_active:
                was_active = False
                self.cloud.update("live", {"active": False, "state": "stopped", "ts": now_ms()})
            time.sleep(0.1)

    # --- Run ---
    def run(self):
        self.reload_config()
        self.reload_pets()
        self.start_firebase_listeners()
        self.mqtt.connect_async(C.MQTT_HOST, C.MQTT_PORT, keepalive=30)
        self.mqtt.loop_start()
        threading.Thread(target=self.heartbeat_loop, daemon=True, name="heartbeat").start()
        threading.Thread(target=self.live_loop, daemon=True, name="live-view").start()
        self.report_camera(force=True)
        self.cloud.log("system", "Raspberry Pi bridge started")
        try:
            self.camera_loop()
        finally:
            self.running = False
            self.cloud.update("status", {"piOnline": False, "cameraOn": False})
            self.cloud.update("live", {"active": False, "state": "stopped", "ts": now_ms()})
            time.sleep(1)
            self.mqtt.loop_stop()
            self.mqtt.disconnect()


def main():
    bridge = Bridge()

    def stop(*_):
        if not bridge.running:            # second Ctrl+C: quit immediately
            os._exit(1)
        bridge.running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    bridge.run()
    log.info("Bridge stopped")
    # Firebase listener threads can keep Python alive after Ctrl+C - exit for real.
    os._exit(0)


if __name__ == "__main__":
    main()
