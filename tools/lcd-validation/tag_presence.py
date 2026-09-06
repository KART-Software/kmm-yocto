#!/usr/bin/env python3
"""AprilTag presence judge (calibration-free).

skill の確定カメラ設定 (1920x1080/MJPG, exposure 250, gain 32, focus 35) を
Camera.setup() の正しい順序 (streamon 後に適用) で使い、1 判定 = タグ検出数を
出力する。ffmpeg ワンショット撮影は streamon リセットで露出が飛ぶため禁止。

usage: tag_presence.py [--save FILE]   -> prints tag count
"""
import sys

import cv2

from lcdval.camera import Camera

SETTINGS = {
    "exposure_time_absolute": 250,
    "gain": 32,
    "exposure_dynamic_framerate": 0,
    "focus_absolute": 35,
    "zoom_absolute": 100,
}


def main():
    save = None
    if "--save" in sys.argv:
        save = sys.argv[sys.argv.index("--save") + 1]

    cam = Camera("/dev/kart-debix-cam", width=1920, height=1080)
    cam.setup(SETTINGS)
    _, frame = cam.read()
    cam.release()
    if frame is None:
        print(-1)
        return 1

    if save:
        cv2.imwrite(save, frame)

    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    d = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_APRILTAG_36h11)
    det = cv2.aruco.ArucoDetector(d, cv2.aruco.DetectorParameters())
    _, ids, _ = det.detectMarkers(gray)
    print(0 if ids is None else len(ids))
    return 0


if __name__ == "__main__":
    sys.exit(main())
