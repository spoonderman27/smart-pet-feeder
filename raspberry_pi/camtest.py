"""Live camera test on the Pi's LCD. Run inside petenv: python3 camtest.py  (Ctrl+C to stop)"""
import os
import re
import subprocess

os.environ.setdefault("DISPLAY", ":0")
import cv2
from picamera2 import Picamera2


def screen_size():
    for cmd, pat in ((["xdpyinfo"], r"dimensions:\s+(\d+)x(\d+)"),
                     (["xrandr"], r"current (\d+) x (\d+)")):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=3).stdout
            m = re.search(pat, out)
            if m:
                return int(m.group(1)), int(m.group(2))
        except Exception:
            pass
    return 480, 320


sw, sh = screen_size()
print(f"Screen is {sw}x{sh}")
cam = Picamera2()
import sys
from libcamera import Transform
flip = "flip" in sys.argv        # python3 camtest.py flip  -> turn the picture 180 degrees
cam.configure(cam.create_preview_configuration(
    main={"size": (640, 480), "format": "RGB888"},
    transform=Transform(hflip=1, vflip=1) if flip else Transform()))
cam.start()
cv2.namedWindow("cam", cv2.WINDOW_NORMAL)
placed = False
while True:
    cv2.imshow("cam", cv2.resize(cam.capture_array(), (sw, sh)))
    if not placed:
        cv2.moveWindow("cam", 0, 0)
        cv2.setWindowProperty("cam", cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_FULLSCREEN)
        placed = True
    if cv2.waitKey(1) == ord("q"):
        break
