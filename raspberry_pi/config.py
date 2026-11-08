"""
Settings for the Raspberry Pi bridge. Edit this file, not pi_bridge.py.
"""

import os
# ---------------------------------------------------------------- Firebase
DEVICE_ID = "feeder01"
DATABASE_URL = os.getenv("DATABASE_URL", "https://your-project-default-rtdb.firebaseio.com")
# Firebase console > Project settings > Service accounts > Generate new private key
# Save the downloaded file next to this script with this name. NEVER share it.
SERVICE_ACCOUNT_FILE = os.getenv("SERVICE_ACCOUNT_FILE", "serviceAccountKey.json")

# -------------------------------------------------------------------- MQTT
MQTT_HOST = "localhost"        # Mosquitto runs on this Pi
MQTT_PORT = 1883
MQTT_USER = os.getenv("MQTT_USER", "your-mqtt-user")          # same user the ESP32 uses (created with mosquitto_passwd)
MQTT_PASS = os.getenv("MQTT_PASS", "your-mqtt-password")        # that user's MQTT password

# --------------------------------------------------------------- Detection
# How the Roboflow-trained YOLOv11 model is run:
#   "roboflow_workflow" - Roboflow cloud workflow (same model as the laptop detect.py).
#                       Needs internet, no model file on the Pi.
#   "tflite"          - TensorFlow Lite export (works on 32-bit Raspberry Pi OS / armv7l)
#                       laptop: yolo export model=best.pt format=tflite imgsz=320
#   "ultralytics"     - best.pt or best_ncnn_model (needs 64-bit Raspberry Pi OS)
#   "roboflow_local"  - Roboflow `inference` package running on the Pi
#   "roboflow_hosted" - Roboflow cloud API (slowest, but needs no heavy libraries)
DETECTOR_BACKEND = "roboflow_workflow"
MODEL_PATH = "models/best_float32.tflite"
IMG_SIZE = 320                          # 320 is much faster than 640 on a Pi 3
# Class order of the model (tflite only). Copy metadata.yaml from the export
# folder into models/ and this list is ignored. Otherwise it must match the
# order in the Roboflow data.yaml (usually alphabetical, as below).
CLASS_NAMES = ["Chihuahua", "German_Shepherd", "Labrador", "Other_Cat", "Other_Dog",
               "Other_Hamster", "Persian", "Siamese", "Syrian", "Tabby"]
ROBOFLOW_MODEL_ID = os.getenv("ROBOFLOW_MODEL_ID", "your-model-id/1")    # only for roboflow_local / roboflow_hosted
ROBOFLOW_API_KEY = os.getenv("ROBOFLOW_API_KEY", "your-roboflow-api-key")     # Roboflow API key - keep it private
ROBOFLOW_WORKFLOW_URL = os.getenv("ROBOFLOW_WORKFLOW_URL", "your-roboflow-workflow-url")

# Per-class confidence limits (others use the app's minimum confidence).
# Same tuning as detect.py: the three demo dolls are accepted earlier,
# "Other_..." classes must be very sure. A specific breed always beats an
# "Other_..." class seen in the same frame.
CLASS_MIN_CONF = {
    "Labrador": 0.40, "Tabby": 0.40, "Syrian": 0.40,
    "Other_Dog": 0.90, "Other_Cat": 0.90, "Other_Hamster": 0.90,
}

# Recognition window after the ultrasonic sensor sees a pet
VERIFY_SECONDS = 12         # give up after this long (cloud detection ~1-2 s per frame)
MIN_VOTES = 2               # frames that must agree on the same class
DEFAULT_MIN_CONFIDENCE = 0.5  # overridden by the app (Feeder tab)
VERIFY_COOLDOWN_S = 20      # ignore new presence events for this long after a decision

# ------------------------------------------------------------------ Camera
CAMERA_SIZE = (640, 480)
# Picamera2 "RGB888" gives arrays in B,G,R order, which is what OpenCV expects.
# If the colours look wrong in the preview (blue cats), use "BGR888".
CAMERA_FORMAT = "RGB888"
# True if the picture is upside down (camera mounted with its ribbon coming out of the top)
CAMERA_ROTATE_180 = False
USB_CAMERA_INDEX = 0        # used only if Picamera2 is not installed
SHOW_WINDOW = True          # live preview on the Pi's LCD (False when headless/SSH)
FULLSCREEN = True

# Camera power mode is chosen in the app (Feeder tab): "auto", "on" or "off".
#   auto - camera rests, wakes when the ESP32 sees movement (wake distance,
#          default 30 cm), a pet at the bowl, a camera check or a live view.
#   on   - camera always running (live preview on the LCD all the time).
#   off  - camera stopped. No automatic feeding by camera, no live view.
DEFAULT_CAMERA_MODE = "auto"
CAMERA_IDLE_S = 10          # auto: rest again after this long with no movement
CAMERA_WARMUP_S = 1.5       # let exposure settle after starting the camera

# Live view in the app: the Pi uploads one small JPEG per second while the
# owner has the Live view page open (about 1 MB per minute of viewing).
LIVE_FPS = 1.0
LIVE_WIDTH = 320
LIVE_JPEG_QUALITY = 55
LIVE_MAX_S = 120            # one request keeps the live view going at most this long

# --------------------------------------------------------------- Housekeeping
ENV_HISTORY_EVERY_S = 300   # save a temperature point every 5 minutes
KEEP_HISTORY_DAYS = 7
HEARTBEAT_S = 30
ESP_OFFLINE_AFTER_S = 90
HIGH_TEMP_MARGIN_C = 2.0    # alert when temperature >= limit + this
ALERT_COOLDOWN_S = 30 * 60
CONSUMPTION_DELAY_S = 20    # wait after the pet leaves before weighing leftovers
