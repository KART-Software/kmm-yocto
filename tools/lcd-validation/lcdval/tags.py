"""AprilTag (36h11) の生成と検出。OpenCV aruco モジュールを使用 (ML 不使用)。"""
import cv2
import numpy as np

DICT = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_APRILTAG_36h11)


def make_detector():
    params = cv2.aruco.DetectorParameters()
    # LCD 撮影 (低コントラスト設定もあり得る) 向け: 適応閾値の窓を広めに振る
    params.adaptiveThreshWinSizeMin = 3
    params.adaptiveThreshWinSizeMax = 45
    params.adaptiveThreshWinSizeStep = 6
    return cv2.aruco.ArucoDetector(DICT, params)


def generate_marker(tid: int, size: int) -> np.ndarray:
    """0/255 のタグ画像 (黒モジュール + 白モジュール、外周は黒枠込み)。"""
    return cv2.aruco.generateImageMarker(DICT, tid, size)


def detect(gray, detector=None):
    """gray 画像からタグを検出。

    Returns: dict {tag_id: {"center": (x, y), "corners": 4x2 ndarray}}
    corners は aruco の順序 (タグ左上から時計回り) — 向き判定に使う。
    """
    if detector is None:
        detector = make_detector()
    corners, ids, _rej = detector.detectMarkers(gray)
    out = {}
    if ids is None:
        return out
    for c, i in zip(corners, ids.flatten()):
        pts = c.reshape(4, 2)
        out[int(i)] = {"center": tuple(pts.mean(axis=0)), "corners": pts}
    return out
