#!/usr/bin/env python3
"""Pattern Generator (§5)。800x480 の 10x6 AprilTag パターンを生成する。

例:
  python generate_pattern.py --stage calibration --output out/calibration.png
  python generate_pattern.py --stage gui --output out/gui.png --raw out/gui.raw

--raw はボード側ビューア (wl-image-view) 用の XRGB8888 生データ。
白レベルは §13 (白飛び対策) に従い既定 128。
"""
import argparse
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lcdval import layout, tags  # noqa: E402


def build_pattern(stage: str, tag_size: int, white: int) -> np.ndarray:
    """グレースケール 800x480。背景=white、タグ黒モジュール=0。"""
    img = np.full((layout.DISPLAY_H, layout.DISPLAY_W), white, np.uint8)
    off = (layout.CELL - tag_size) // 2
    for row in range(layout.GRID_ROWS):
        for col in range(layout.GRID_COLS):
            tid = layout.tag_id(stage, row, col)
            m = tags.generate_marker(tid, tag_size)
            # aruco 出力は 0/255 — 白側を white レベルへ落とす
            m = np.where(m > 0, white, 0).astype(np.uint8)
            y = row * layout.CELL + off
            x = col * layout.CELL + off
            img[y:y + tag_size, x:x + tag_size] = m
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", required=True, choices=layout.STAGES)
    ap.add_argument("--output", required=True, help="PNG 出力パス")
    ap.add_argument("--raw", help="XRGB8888 raw 出力パス (wl-image-view 用)")
    ap.add_argument("--tag-size", type=int, default=layout.DEFAULT_TAG_SIZE)
    ap.add_argument("--white", type=int, default=128,
                    help="白レベル (§13、既定 128)")
    args = ap.parse_args()

    img = build_pattern(args.stage, args.tag_size, args.white)
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    cv2.imwrite(args.output, img)
    print(f"wrote {args.output} ({layout.DISPLAY_W}x{layout.DISPLAY_H}, "
          f"stage={args.stage}, tag={args.tag_size}px, white={args.white})")

    if args.raw:
        # XRGB8888 (LE): B,G,R,X の順で 4 バイト
        bgra = cv2.cvtColor(cv2.cvtColor(img, cv2.COLOR_GRAY2BGR),
                            cv2.COLOR_BGR2BGRA)
        bgra[:, :, 3] = 0xFF
        with open(args.raw, "wb") as f:
            f.write(bgra.tobytes())
        print(f"wrote {args.raw} ({bgra.nbytes} bytes)")


if __name__ == "__main__":
    main()
