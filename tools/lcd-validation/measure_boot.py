#!/usr/bin/env python3
"""Experiment Tool (§30)。

保存済み Calibration (固定 Homography) でブート中の表示を計測する。

例 (電源制御込み、kart ベンチ):
  python measure_boot.py --device /dev/kart-debix-cam \\
      --calibration calibration.json --power-cycle --duration 20

--power-cycle 無しの場合はツール起動後に手動で電源を入れる。
"""
import argparse
import csv
import json
import os
import subprocess
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lcdval import calibration, camera, layout, tags, timing, validation  # noqa: E402

DP100 = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "..", "..", "scripts", "dp100.py")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="/dev/video0")
    ap.add_argument("--calibration", default="calibration.json")
    ap.add_argument("--duration", type=float, default=20.0,
                    help="キャプチャ秒数 (電源 ON からの観測窓)")
    ap.add_argument("--power-cycle", action="store_true",
                    help="scripts/dp100.py で電源サイクルする (sudo)")
    ap.add_argument("--off-time", type=float, default=3.0)
    ap.add_argument("--csv", default="measure_boot.csv")
    ap.add_argument("--thresholds", help="PASS/FAIL 閾値の JSON (§27)")
    ap.add_argument("--camera-moved-rms", type=float, default=6.0,
                    help="GUI stable 時 RMS がこれ超で CAMERA_MOVED/INVALID")
    args = ap.parse_args()

    calib = calibration.load(args.calibration)
    H = calib["homography"]
    th = validation.thresholds_from_dict(
        json.loads(open(args.thresholds).read()) if args.thresholds else {})

    # Calibration 時のカメラ設定を再適用 (§9/§12)。streamon 後に適用
    # (streamon で巻き戻る C930e 実測のため — camera.Camera.setup 参照)
    fixed = {k: v for k, v in calib.get("camera_controls", {}).items()
             if k in camera.FIXED_CONTROL_NAMES}
    cinfo = calib["camera"]
    cam = camera.Camera(args.device, cinfo["width"], cinfo["height"],
                        int(cinfo["fps"]))
    cam.setup(fixed)
    det = tags.make_detector()

    if args.power_cycle:
        print(f"power cycle (off {args.off_time}s)...")
        subprocess.Popen(
            ["sudo", "-n", "python3", DP100, "cycle",
             "--off-time", str(args.off_time)],
            stdout=subprocess.DEVNULL)
    else:
        print("電源を投入してください (キャプチャ開始済み)")

    timer = timing.StageTimer()
    rows = []
    captured = processed = 0
    perf = {"capture": [], "rectify": [], "detect": [], "validate": []}
    t_end = time.monotonic() + args.duration + (
        args.off_time + 2 if args.power_cycle else 0)
    gui_stable_dets = None

    while time.monotonic() < t_end:
        t0 = time.perf_counter()
        ts, frame = cam.read()
        if frame is None:
            continue
        captured += 1
        t1 = time.perf_counter()
        rect = calibration.rectify(frame, H)          # §18 固定 H
        t2 = time.perf_counter()
        gray = cv2.cvtColor(rect, cv2.COLOR_BGR2GRAY)
        dets = tags.detect(gray, det)
        t3 = time.perf_counter()

        counts = {s: 0 for s in layout.STAGES}
        pos = {}
        for tid, d in dets.items():
            st = layout.decode_tag(tid)
            if st is None:
                continue
            counts[st[0]] += 1
            pos[tid] = d["center"]
        timer.feed(ts, counts)
        stage = timer.dominant_stage(counts)

        res = validation.analyze(stage, pos, th) if stage in layout.STAGES \
            else {"mean_dx": None, "mean_dy": None, "rms_error": None,
                  "max_error": None, "scale_x": None, "scale_y": None,
                  "missing_ids": []}
        t4 = time.perf_counter()

        if stage == "gui" and "gui" in timer.stable:
            gui_stable_dets = pos

        perf["capture"].append(t1 - t0)
        perf["rectify"].append(t2 - t1)
        perf["detect"].append(t3 - t2)
        perf["validate"].append(t4 - t3)
        processed += 1
        rows.append({
            "timestamp_ns": ts,
            "frame_number": captured,
            "bootloader_tag_count": counts["bootloader"],
            "weston_tag_count": counts["weston"],
            "gui_tag_count": counts["gui"],
            "detected_tag_ids": " ".join(map(str, sorted(dets))),
            "missing_tag_ids": " ".join(map(str, res.get("missing_ids", []))),
            "mean_dx": res.get("mean_dx"),
            "mean_dy": res.get("mean_dy"),
            "rms_error": res.get("rms_error"),
            "max_error": res.get("max_error"),
            "scale_x": res.get("scale_x"),
            "scale_y": res.get("scale_y"),
            "stage": stage,
        })

    cam.release()

    with open(args.csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else [])
        w.writeheader()
        w.writerows(rows)

    # ---- 最終判定 (GUI stable フレームで検証) ----
    invalid = None
    final = None
    if gui_stable_dets:
        final = validation.analyze("gui", gui_stable_dets, th)
        if final["rms_error"] is not None and \
           final["rms_error"] > args.camera_moved_rms:
            invalid = "CAMERA_MOVED"

    print("\n=== Boot Display Measurement ===\n")
    for line in timer.report_lines():
        print(line)
    if final:
        print(f"\nTags             : {final['detected_count']} / "
              f"{layout.NUM_TAGS}")
        print(f"Mean X error     : {final['mean_dx']:+.2f} px")
        print(f"Mean Y error     : {final['mean_dy']:+.2f} px")
        print(f"Scale X          : {final['scale_x']:.4f}")
        print(f"Scale Y          : {final['scale_y']:.4f}")
        print(f"RMS error        : {final['rms_error']:.2f} px")
        print(f"Max error        : {final['max_error']:.2f} px")
        print(f"\nCamera moved     : "
              f"{'SUSPECTED' if invalid else 'NO (rms below threshold)'}")
        for name in ("position", "scale", "crop", "distortion"):
            print(f"{name.capitalize():16s} : "
                  f"{'PASS' if final['checks'][name] else 'FAIL'}")
        if final["flags"]:
            print(f"Flags            : {' '.join(final['flags'])}")
    else:
        print("\nGUI stable に未到達")

    fps_seen = processed / max(args.duration, 1e-9)
    print(f"\nFrames           : captured={captured} processed={processed} "
          f"(~{fps_seen:.1f} fps)")
    for k, v in perf.items():
        if v:
            print(f"  {k:10s} avg {np.mean(v)*1000:.1f} ms  "
                  f"max {np.max(v)*1000:.1f} ms")
    print(f"CSV              : {args.csv}")

    if invalid:
        print(f"\nRESULT           : INVALID ({invalid})")
        sys.exit(2)
    ok = bool(final and final["passed"] and "gui" in timer.stable)
    print(f"\nRESULT           : {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
