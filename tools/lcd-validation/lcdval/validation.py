"""表示位置/スケール/クロップ/局所歪みの検証と PASS/FAIL (§22-27)。

入力はディスプレイ座標系 (Rectified) で検出済みのタグ位置。
"""
from dataclasses import dataclass, field, asdict

import numpy as np

from . import layout


@dataclass
class Thresholds:
    min_detected_tags: int = 54          # 90%
    max_mean_x_error: float = 3.0        # px
    max_mean_y_error: float = 3.0
    max_rms_error: float = 4.0
    max_single_tag_error: float = 8.0
    max_missing_tags: int = 6
    max_scale_error: float = 0.01        # |scale-1|
    crop_run_min: int = 3                # 端の連続欠落がこの数以上で CROP 候補
    local_distortion_error: float = 5.0  # 単タグ残差がこれ以上で記録


def analyze(stage: str, dets_display: dict, thresholds: Thresholds):
    """dets_display: {tag_id: (x, y)} (ディスプレイ座標)。

    Returns dict: metrics + flags + per-check pass + overall pass。
    """
    th = thresholds
    exp_ids = layout.stage_ids(stage)
    detected = {t: xy for t, xy in dets_display.items() if t in exp_ids}
    missing = sorted(set(exp_ids) - set(detected))

    res = {
        "stage": stage,
        "detected_count": len(detected),
        "missing_ids": missing,
        "flags": [],
    }

    if len(detected) < 4:
        res.update(mean_dx=None, mean_dy=None, rms_error=None,
                   max_error=None, scale_x=None, scale_y=None,
                   passed=False)
        res["flags"].append("TOO_FEW_TAGS")
        return res

    dxs, dys, errs = [], [], []
    per_tag = {}
    xs_c, xs_e, ys_c, ys_e = [], [], [], []
    for tid, (x, y) in detected.items():
        _s, row, col = layout.decode_tag(tid)
        ex, ey = layout.expected_center(row, col)
        dx, dy = x - ex, y - ey
        err = float(np.hypot(dx, dy))
        per_tag[tid] = {"dx": float(dx), "dy": float(dy), "error": err}
        dxs.append(dx); dys.append(dy); errs.append(err)
        xs_c.append(x); xs_e.append(ex); ys_c.append(y); ys_e.append(ey)

    errs_a = np.array(errs)
    mean_dx = float(np.mean(dxs))
    mean_dy = float(np.mean(dys))
    rms = float(np.sqrt((errs_a ** 2).mean()))
    mx = float(errs_a.max())

    # §24 スケール: 実測位置を理想位置に対して線形回帰した傾き (X/Y 独立)
    scale_x = _fit_scale(xs_e, xs_c)
    scale_y = _fit_scale(ys_e, ys_c)

    # §25 クロップ: 端の行/列の連続欠落
    crop = _crop_flags(missing, th.crop_run_min)
    res["flags"] += crop

    # §26 局所歪み: 全体平行移動を除いた残差が大きいタグ
    local = {t: v for t, v in per_tag.items()
             if np.hypot(v["dx"] - mean_dx, v["dy"] - mean_dy)
             >= th.local_distortion_error}
    if local:
        res["flags"].append("LOCAL_DISTORTION")

    checks = {
        "position": (abs(mean_dx) <= th.max_mean_x_error and
                     abs(mean_dy) <= th.max_mean_y_error and
                     rms <= th.max_rms_error and
                     mx <= th.max_single_tag_error),
        "scale": (abs(scale_x - 1) <= th.max_scale_error and
                  abs(scale_y - 1) <= th.max_scale_error),
        "crop": not crop,
        "detection": (len(detected) >= th.min_detected_tags and
                      len(missing) <= th.max_missing_tags),
        "distortion": not local,
    }

    res.update(
        mean_dx=mean_dx, mean_dy=mean_dy,
        rms_error=rms, max_error=mx,
        scale_x=scale_x, scale_y=scale_y,
        per_tag=per_tag,
        local_distortion={str(t): v for t, v in local.items()},
        checks=checks,
        passed=all(checks.values()),
    )
    return res


def _fit_scale(expected, actual):
    """expected -> actual の傾き (最小二乗)。"""
    e = np.array(expected, dtype=np.float64)
    a = np.array(actual, dtype=np.float64)
    e = e - e.mean()
    a = a - a.mean()
    denom = (e ** 2).sum()
    if denom == 0:
        return 1.0
    return float((e * a).sum() / denom)


def _crop_flags(missing_ids, run_min):
    """端の行/列がまとめて欠けていれば TOP/BOTTOM/LEFT/RIGHT_CROP。"""
    rc = [layout.decode_tag(t)[1:] for t in missing_ids
          if layout.decode_tag(t)]
    flags = []
    rows = [r for r, _ in rc]
    cols = [c for _, c in rc]
    if rows.count(0) >= run_min:
        flags.append("TOP_CROP")
    if rows.count(layout.GRID_ROWS - 1) >= run_min:
        flags.append("BOTTOM_CROP")
    if cols.count(0) >= run_min:
        flags.append("LEFT_CROP")
    if cols.count(layout.GRID_COLS - 1) >= run_min:
        flags.append("RIGHT_CROP")
    return flags


def thresholds_from_dict(d: dict) -> Thresholds:
    th = Thresholds()
    for k, v in (d or {}).items():
        if hasattr(th, k):
            setattr(th, k, v)
    return th
