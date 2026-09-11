"""Geometric Calibration (§6-11)。

Calibration Pattern (60 タグ) から Camera -> Display (800x480) の Homography を
求め、品質評価して calibration.json に保存する。Experiment 中は固定 (§10)。
"""
import json

import cv2
import numpy as np

from . import layout


class CalibrationError(Exception):
    pass


def validate_layout(dets: dict):
    """§6 の成功条件チェック。dets = tags.detect() の結果 (カメラ座標)。"""
    ids = sorted(dets)
    expected = set(layout.stage_ids("calibration"))
    got = set(ids)
    if got - expected:
        raise CalibrationError(f"calibration 以外の ID を検出: {sorted(got - expected)}")
    if expected - got:
        raise CalibrationError(
            f"タグ不足 {len(got)}/60、missing={sorted(expected - got)}")

    # 並び: 同一行では x が列順に増え、同一列では y が行順に増えること
    for row in range(layout.GRID_ROWS):
        xs = [dets[layout.tag_id('calibration', row, c)]["center"][0]
              for c in range(layout.GRID_COLS)]
        if any(b <= a for a, b in zip(xs, xs[1:])):
            raise CalibrationError(f"row {row} の列順が単調でない (回転/鏡像?)")
    for col in range(layout.GRID_COLS):
        ys = [dets[layout.tag_id('calibration', r, col)]["center"][1]
              for r in range(layout.GRID_ROWS)]
        if any(b <= a for a, b in zip(ys, ys[1:])):
            raise CalibrationError(f"col {col} の行順が単調でない (回転/鏡像?)")

    # 向き: 各タグの corner0->corner1 (タグ上辺) がカメラ画像でも概ね +x
    bad = [t for t, d in dets.items()
           if (d["corners"][1] - d["corners"][0])[0] <= 0]
    if len(bad) > len(dets) // 4:
        raise CalibrationError(f"タグ上辺の向きが +x でない: {len(bad)} 個 (上下逆?)")


def compute_homography(dets: dict):
    """カメラ座標 -> ディスプレイ座標の H。全タグ + RANSAC (§7)。"""
    cam = []
    disp = []
    for tid, d in dets.items():
        st = layout.decode_tag(tid)
        if st is None:
            continue
        _stage, row, col = st
        cam.append(d["center"])
        disp.append(layout.expected_center(row, col))
    cam = np.array(cam, dtype=np.float64)
    disp = np.array(disp, dtype=np.float64)
    H, mask = cv2.findHomography(cam, disp, cv2.RANSAC, 3.0)
    if H is None:
        raise CalibrationError("findHomography 失敗")
    return H, int(mask.sum())


def project(H, points):
    """カメラ座標列を H でディスプレイ座標へ。"""
    pts = np.array(points, dtype=np.float64).reshape(-1, 1, 2)
    return cv2.perspectiveTransform(pts, H).reshape(-1, 2)


def quality(H, dets: dict):
    """§8: 各タグの dx/dy/error と mean/RMS/max。"""
    per_tag = {}
    errs = []
    for tid, d in dets.items():
        st = layout.decode_tag(tid)
        if st is None:
            continue
        _stage, row, col = st
        est = project(H, [d["center"]])[0]
        ex, ey = layout.expected_center(row, col)
        dx, dy = float(est[0] - ex), float(est[1] - ey)
        err = float(np.hypot(dx, dy))
        per_tag[tid] = {"dx": dx, "dy": dy, "error": err}
        errs.append(err)
    errs = np.array(errs)
    return per_tag, {
        "mean_error": float(errs.mean()),
        "rms_error": float(np.sqrt((errs ** 2).mean())),
        "max_error": float(errs.max()),
    }


def rectify(frame, H):
    """§18: Homography を適用して 800x480 の Rectified Image を得る。"""
    return cv2.warpPerspective(
        frame, H, (layout.DISPLAY_W, layout.DISPLAY_H))


def save(path, H, stats, per_tag, dets, camera_info, camera_controls,
         lum_stats):
    data = {
        "camera": camera_info,
        "camera_controls": camera_controls,
        "luminance": lum_stats,
        "homography": np.asarray(H).tolist(),
        "quality": stats,
        "tags": {
            str(t): {
                "camera_xy": [float(v) for v in dets[t]["center"]],
                **per_tag[t],
            } for t in sorted(dets)
        },
    }
    with open(path, "w") as f:
        json.dump(data, f, indent=1)


def load(path):
    with open(path) as f:
        data = json.load(f)
    data["homography"] = np.array(data["homography"], dtype=np.float64)
    return data
