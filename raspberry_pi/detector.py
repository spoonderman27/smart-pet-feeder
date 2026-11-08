"""
Pet detector for the Roboflow-trained YOLOv11 model (10 classes).

PetDetector.detect() takes one camera frame and returns the pets found in it
(class, confidence, box). The backend is chosen in config.py (DETECTOR_BACKEND).
"""
import os
import re
from dataclasses import dataclass
from typing import List, Optional, Tuple

# The 10 model classes grouped by species (same table as the Flutter app).
BREEDS_BY_SPECIES = {
    "Cat": ["Persian", "Siamese", "Tabby", "Other_Cat"],
    "Dog": ["Chihuahua", "German_Shepherd", "Labrador", "Other_Dog"],
    "Hamster": ["Syrian", "Other_Hamster"],
}
ALL_CLASSES = [c for v in BREEDS_BY_SPECIES.values() for c in v]
# Roboflow exports class names in alphabetical order - this is the usual model order.
DEFAULT_MODEL_ORDER = sorted(ALL_CLASSES)
_LOOKUP = {c.lower(): c for c in ALL_CLASSES}


def normalise_label(raw: str) -> Optional[str]:
    """'german shepherd' / 'German-Shepherd' / 'German_Shepherd' -> 'German_Shepherd'."""
    key = raw.strip().replace(" ", "_").replace("-", "_").lower()
    return _LOOKUP.get(key)


def species_of(label: Optional[str]) -> str:
    if not label:
        return "Unknown"
    for species, breeds in BREEDS_BY_SPECIES.items():
        if label in breeds:
            return species
    return "Unknown"


@dataclass
class Detection:
    label: str                      # one of ALL_CLASSES
    confidence: float
    box: Tuple[int, int, int, int]  # x1, y1, x2, y2 in pixels


class PetDetector:
    def __init__(self, backend: str, model_path: str = "", imgsz: int = 320,
                 roboflow_model_id: str = "", roboflow_api_key: str = "",
                 class_names: Optional[List[str]] = None, conf: float = 0.25,
                 workflow_url: str = ""):
        self.backend = backend
        self.imgsz = imgsz
        self.model_id = roboflow_model_id
        self.conf = conf
        self.api_key = roboflow_api_key
        self.workflow_url = workflow_url
        if backend == "roboflow_workflow":
            import requests
            self.http = requests.Session()
        elif backend == "tflite":
            self._init_tflite(model_path, class_names)
        elif backend == "ultralytics":
            from ultralytics import YOLO
            self.model = YOLO(model_path, task="detect")
        elif backend == "roboflow_local":
            from inference import get_model
            self.model = get_model(model_id=roboflow_model_id, api_key=roboflow_api_key)
        elif backend == "roboflow_hosted":
            from inference_sdk import InferenceHTTPClient
            self.model = InferenceHTTPClient(api_url="https://detect.roboflow.com",
                                             api_key=roboflow_api_key)
        else:
            raise ValueError(f"Unknown DETECTOR_BACKEND '{backend}'")

    def detect(self, frame_bgr) -> List[Detection]:
        """Run the model on one BGR frame and return pet detections."""
        out: List[Detection] = []

        if self.backend == "roboflow_workflow":
            out = self._detect_workflow(frame_bgr)

        elif self.backend == "tflite":
            out = self._detect_tflite(frame_bgr)

        elif self.backend == "ultralytics":
            result = self.model.predict(frame_bgr, imgsz=self.imgsz, conf=0.25, verbose=False)[0]
            names = result.names
            for b in result.boxes:
                label = normalise_label(str(names[int(b.cls[0])]))
                if label is None:
                    continue
                x1, y1, x2, y2 = [int(v) for v in b.xyxy[0].tolist()]
                out.append(Detection(label, float(b.conf[0]), (x1, y1, x2, y2)))

        elif self.backend == "roboflow_local":
            result = self.model.infer(frame_bgr)[0]
            for p in result.predictions:
                label = normalise_label(p.class_name)
                if label is None:
                    continue
                out.append(Detection(label, float(p.confidence), _center_box(p.x, p.y, p.width, p.height)))

        else:  # roboflow_hosted
            result = self.model.infer(frame_bgr, model_id=self.model_id)
            for p in result.get("predictions", []):
                label = normalise_label(p["class"])
                if label is None:
                    continue
                out.append(Detection(label, float(p["confidence"]),
                                     _center_box(p["x"], p["y"], p["width"], p["height"])))

        out.sort(key=lambda d: d.confidence, reverse=True)
        return out

    # --- Roboflow workflow ---
    # Cloud model on serverless.roboflow.com (same model as the laptop test detect.py).
    # Needs internet (hotspot mobile data), about 30-50 KB per frame.
    def _detect_workflow(self, frame_bgr) -> List[Detection]:
        import base64
        import cv2

        h0, w0 = frame_bgr.shape[:2]
        scale = min(1.0, 640.0 / max(w0, h0))
        img = cv2.resize(frame_bgr, (int(w0 * scale), int(h0 * scale))) if scale < 1.0 else frame_bgr
        ok, buf = cv2.imencode(".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
        if not ok:
            return []
        payload = {"api_key": self.api_key,
                   "inputs": {"image": {"type": "base64",
                                        "value": base64.b64encode(buf).decode("ascii")}}}
        try:
            r = self.http.post(self.workflow_url, json=payload, timeout=8,
                               headers={"Authorization": f"Bearer {self.api_key}"})
        except Exception as e:                       # no internet, timeout...
            print(f"[detector] Roboflow request failed: {e}")
            return []
        if r.status_code != 200:
            print(f"[detector] Roboflow HTTP {r.status_code}: {r.text[:200]}")
            return []
        preds = _find_predictions(r.json())
        out: List[Detection] = []
        for p in preds:
            label = normalise_label(str(p.get("class", "")))
            if label is None:
                continue
            x1, y1, x2, y2 = _center_box(p["x"], p["y"], p["width"], p["height"])
            out.append(Detection(label, float(p.get("confidence", 0.0)),
                                 (int(x1 / scale), int(y1 / scale), int(x2 / scale), int(y2 / scale))))
        return out

    # --- TFLite ---
    # For 32-bit Raspberry Pi OS (armv7l), where Ultralytics / PyTorch cannot be
    # installed. Export on the laptop:  yolo export model=best.pt format=tflite imgsz=320
    def _init_tflite(self, model_path, class_names):
        try:
            from tflite_runtime.interpreter import Interpreter
        except ImportError:
            try:
                from ai_edge_litert.interpreter import Interpreter
            except ImportError:
                import tensorflow as tf
                Interpreter = tf.lite.Interpreter
        try:
            self.interp = Interpreter(model_path=model_path, num_threads=4)
        except TypeError:
            self.interp = Interpreter(model_path=model_path)
        self.interp.allocate_tensors()
        inp = self.interp.get_input_details()[0]
        out = self.interp.get_output_details()[0]
        self.in_idx, self.in_dtype = inp["index"], inp["dtype"]
        self.in_q = inp.get("quantization", (0.0, 0))
        self.in_h, self.in_w = int(inp["shape"][1]), int(inp["shape"][2])
        self.out_idx = out["index"]
        self.out_q = out.get("quantization", (0.0, 0))
        self.names = (_names_from_metadata(model_path)
                      or (list(class_names) if class_names else None)
                      or DEFAULT_MODEL_ORDER)

    def _detect_tflite(self, frame_bgr) -> List[Detection]:
        import cv2
        import numpy as np

        h0, w0 = frame_bgr.shape[:2]
        r = min(self.in_w / w0, self.in_h / h0)
        nw, nh = int(round(w0 * r)), int(round(h0 * r))
        dx, dy = (self.in_w - nw) // 2, (self.in_h - nh) // 2
        canvas = np.full((self.in_h, self.in_w, 3), 114, dtype=np.uint8)
        canvas[dy:dy + nh, dx:dx + nw] = cv2.resize(frame_bgr, (nw, nh))
        x = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
        if self.in_dtype in (np.int8, np.uint8):
            scale, zp = self.in_q
            info = np.iinfo(self.in_dtype)
            x = np.clip(np.round(x / scale + zp), info.min, info.max).astype(self.in_dtype)
        self.interp.set_tensor(self.in_idx, x[None])
        self.interp.invoke()
        y = self.interp.get_tensor(self.out_idx)[0]
        if y.dtype in (np.int8, np.uint8):
            scale, zp = self.out_q
            y = (y.astype(np.float32) - zp) * scale

        n = 4 + len(self.names)
        if y.shape[0] == n:
            y = y.T
        if y.shape[1] != n:
            raise ValueError(f"Model output {y.shape} does not match {len(self.names)} classes - "
                             "check CLASS_NAMES in config.py")
        scores = y[:, 4:]
        cls = scores.argmax(1)
        conf = scores.max(1)
        keep = conf >= self.conf
        if not keep.any():
            return []
        boxes, cls, conf = y[keep, :4].copy(), cls[keep], conf[keep]
        if boxes.max() <= 2.0:              # TFLite exports give 0-1 coordinates
            boxes[:, [0, 2]] *= self.in_w
            boxes[:, [1, 3]] *= self.in_h
        xywh = [[float(cx - w / 2), float(cy - h / 2), float(w), float(h)] for cx, cy, w, h in boxes]
        idx = cv2.dnn.NMSBoxes(xywh, conf.astype(float).tolist(), self.conf, 0.45)
        out: List[Detection] = []
        for i in np.array(idx).reshape(-1):
            label = normalise_label(self.names[int(cls[i])])
            if label is None:
                continue
            bx, by, bw, bh = xywh[i]
            x1 = int(max(0, min(w0, (bx - dx) / r)))
            y1 = int(max(0, min(h0, (by - dy) / r)))
            x2 = int(max(0, min(w0, (bx + bw - dx) / r)))
            y2 = int(max(0, min(h0, (by + bh - dy) / r)))
            out.append(Detection(label, float(conf[i]), (x1, y1, x2, y2)))
        return out


def _find_predictions(data):
    """Pull the prediction list out of a Roboflow workflow response."""
    try:
        return data["outputs"][0]["predictions"]["predictions"]
    except (KeyError, IndexError, TypeError):
        pass
    # Fallback: search the response for the first list of boxes with a class.
    stack = [data]
    while stack:
        cur = stack.pop()
        if isinstance(cur, list):
            if cur and isinstance(cur[0], dict) and "class" in cur[0] and "x" in cur[0]:
                return cur
            stack.extend(cur)
        elif isinstance(cur, dict):
            stack.extend(cur.values())
    return []


def _names_from_metadata(model_path: str) -> Optional[List[str]]:
    """Read class names from the metadata.yaml that Ultralytics writes next to the model."""
    path = os.path.join(os.path.dirname(model_path), "metadata.yaml")
    if not os.path.exists(path):
        return None
    names, inside = {}, False
    for line in open(path, encoding="utf-8"):
        if line.startswith("names:"):
            inside = True
            continue
        if inside:
            m = re.match(r"\s+(\d+):\s*['\"]?([^'\"\n]+)", line)
            if not m:
                break
            names[int(m.group(1))] = m.group(2).strip()
    return [names[i] for i in sorted(names)] or None


def _center_box(x, y, w, h):
    return (int(x - w / 2), int(y - h / 2), int(x + w / 2), int(y + h / 2))
