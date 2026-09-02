"""C930e (V4L2) のキャプチャとカメラ制御。

設計書 §12-15: Auto Exposure/WB/Focus を切って固定し、白飛びしない範囲で
できるだけ短い Exposure を使う。制御は v4l2-ctl 経由 (cv2 の CAP_PROP は
ドライバ差異が大きいため)。
"""
import subprocess
import time

import cv2
import numpy as np

# C930e (uvcvideo) の代表的なコントロール名。実機は
#   v4l2-ctl -d <dev> --list-ctrls
# で確認する (§12)。auto_exposure: 1=manual, 3=aperture priority。
MANUAL_CONTROLS = {
    "auto_exposure": 1,
    "white_balance_automatic": 0,
    "focus_automatic_continuous": 0,
}
FIXED_CONTROL_NAMES = [
    "exposure_time_absolute",
    "gain",
    "white_balance_temperature",
    "focus_absolute",
    # 幾何に効くデジタル制御も固定して再適用する (§11)。
    # C930e はズームが不揮発で残ることがある (ベンチで zoom=299 が残っていて
    # 画角が切れた実測 2026-09-02) — calibration.json の値で毎回上書きする
    "zoom_absolute",
    "pan_absolute",
    "tilt_absolute",
]


def v4l2_set(device: str, name: str, value) -> bool:
    try:
        r = subprocess.run(
            ["v4l2-ctl", "-d", device, f"--set-ctrl={name}={value}"],
            capture_output=True, text=True)
    except FileNotFoundError:
        print("warning: v4l2-ctl が無い (v4l-utils 未インストール) — "
              "カメラ制御をスキップ")
        return False
    return r.returncode == 0


def v4l2_get_all(device: str) -> dict:
    try:
        r = subprocess.run(["v4l2-ctl", "-d", device, "--list-ctrls"],
                           capture_output=True, text=True)
    except FileNotFoundError:
        return {}
    out = {}
    for line in r.stdout.splitlines():
        line = line.strip()
        if ":" not in line or "value=" not in line:
            continue
        name = line.split()[0]
        for tok in line.split(":", 1)[1].split():
            if tok.startswith("value="):
                try:
                    out[name] = int(tok.split("=", 1)[1])
                except ValueError:
                    pass
    return out


def apply_settings(device: str, settings: dict) -> dict:
    """manual 化 + 固定値適用。実際に効いた値を返す。"""
    applied = {}
    for name, val in {**MANUAL_CONTROLS, **settings}.items():
        if v4l2_set(device, name, val):
            applied[name] = val
    time.sleep(0.3)  # UVC は反映に数フレームかかる
    return applied


class Camera:
    def __init__(self, device: str, width=1280, height=720, fps=30,
                 fourcc="MJPG"):
        self.device = device
        self.cap = cv2.VideoCapture(device, cv2.CAP_V4L2)
        self.cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.cap.set(cv2.CAP_PROP_FPS, fps)
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 2)
        if not self.cap.isOpened():
            raise RuntimeError(f"camera open failed: {device}")
        self.width = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        self.height = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        self.fps = self.cap.get(cv2.CAP_PROP_FPS)
        self.fourcc = fourcc

    def read(self):
        """(timestamp_ns, frame) — timestamp は read 完了直後の monotonic。

        設計書 §21: 本来は V4L2 frame timestamp が望ましい。cv2 経由では
        取得できないため time.monotonic_ns() を代替使用 (誤差 ~1 フレーム)。
        """
        ok, frame = self.cap.read()
        ts = time.monotonic_ns()
        if not ok:
            return None, None
        return ts, frame

    def flush(self, n=5):
        for _ in range(n):
            self.cap.read()

    def setup(self, settings: dict) -> dict:
        """streamon 後にコントロールを適用する。

        cv2 は最初の read() で streamon し、その瞬間に UVC 側の設定が
        既定へ巻き戻る (C930e 実測 2026-09-02)。そのため
        「先に 1 フレーム読んでから設定 → 数フレーム流して安定」の順で
        適用する。calibrate/measure は必ずこれを使うこと。
        """
        self.flush(2)
        applied = apply_settings(self.device, settings)
        self.flush(10)
        return applied

    def release(self):
        self.cap.release()

    def info(self) -> dict:
        return {
            "device": self.device,
            "width": self.width,
            "height": self.height,
            "fps": self.fps,
            "pixel_format": self.fourcc,
        }


def luminance_stats(gray: np.ndarray) -> dict:
    """§13: min/max/mean 輝度と飽和率。"""
    return {
        "min": int(gray.min()),
        "max": int(gray.max()),
        "mean": float(gray.mean()),
        "saturation_ratio": float((gray >= 250).mean()),
    }
