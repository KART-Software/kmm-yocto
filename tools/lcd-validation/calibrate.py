#!/usr/bin/env python3
"""Calibration Tool (§29)。

前提: ボードが完全起動し、Calibration Pattern がフルスクリーン表示中
(README の wl-image-view 手順参照)。

例:
  python calibrate.py --device /dev/kart-debix-cam --output calibration.json
"""
import argparse
import json
import os
import sys

import cv2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lcdval import calibration, camera, tags  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="/dev/video0")
    ap.add_argument("--output", default="calibration.json")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--controls", help="JSON: v4l2 コントロール固定値 "
                    '(例 \'{"exposure_time_absolute": 100, "gain": 64}\')')
    ap.add_argument("--frames", type=int, default=5,
                    help="この回数連続で 60/60 検出できたら合格")
    ap.add_argument("--max-rms", type=float, default=2.0,
                    help="Calibration 品質ゲート (§8)")
    ap.add_argument("--debug-dir", help="raw/annotated/rectified 画像の保存先")
    args = ap.parse_args()

    settings = json.loads(args.controls) if args.controls else {}
    cam = camera.Camera(args.device, args.width, args.height, args.fps)
    print(f"camera: {cam.info()}")
    applied = cam.setup(settings)  # streamon 後でないと設定が巻き戻る
    print(f"camera controls applied: {applied}")

    det = tags.make_detector()
    ok_frames = 0
    last = None
    for attempt in range(args.frames * 10):
        _ts, frame = cam.read()
        if frame is None:
            continue
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        dets = tags.detect(gray, det)
        try:
            calibration.validate_layout(dets)
        except calibration.CalibrationError as e:
            ok_frames = 0
            print(f"  [{attempt}] {len(dets)} tags: {e}")
            continue
        ok_frames += 1
        last = (frame, gray, dets)
        print(f"  [{attempt}] 60/60 OK ({ok_frames}/{args.frames})")
        if ok_frames >= args.frames:
            break
    cam.release()

    if ok_frames < args.frames:
        print("CALIBRATION FAILED: 60 タグの安定検出に到達せず")
        sys.exit(1)

    frame, gray, dets = last
    H, inliers = calibration.compute_homography(dets)
    per_tag, stats = calibration.quality(H, dets)
    lum = camera.luminance_stats(gray)
    print(f"homography inliers: {inliers}/60")
    print(f"quality: mean={stats['mean_error']:.2f}px "
          f"rms={stats['rms_error']:.2f}px max={stats['max_error']:.2f}px")
    print(f"luminance: {lum}")

    if stats["rms_error"] > args.max_rms:
        print(f"CALIBRATION FAILED: RMS {stats['rms_error']:.2f} > "
              f"{args.max_rms}")
        sys.exit(1)

    controls_now = camera.v4l2_get_all(args.device)
    calibration.save(args.output, H, stats, per_tag, dets,
                     {**cam.info()}, controls_now, lum)
    print(f"saved {args.output}")

    if args.debug_dir:
        os.makedirs(args.debug_dir, exist_ok=True)
        cv2.imwrite(os.path.join(args.debug_dir, "raw.png"), frame)
        ann = frame.copy()
        for tid, d in dets.items():
            c = tuple(int(v) for v in d["center"])
            cv2.polylines(ann, [d["corners"].astype(int)], True, (0, 255, 0))
            cv2.putText(ann, str(tid), c, cv2.FONT_HERSHEY_PLAIN, 1,
                        (0, 0, 255))
        cv2.imwrite(os.path.join(args.debug_dir, "annotated.png"), ann)
        cv2.imwrite(os.path.join(args.debug_dir, "rectified.png"),
                    calibration.rectify(frame, H))
        print(f"debug images -> {args.debug_dir}")


if __name__ == "__main__":
    main()
