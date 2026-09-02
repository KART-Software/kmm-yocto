---
name: lcd-validation
description: LCD バリデーションシステム (tools/lcd-validation) の使い方 — AprilTag パターンをボードに表示し、カメラで表示タイミング/表示異常を自動判定する。起動時間の実験、スプラッシュ/表示の回帰確認、画面のズレ/クロップ検証をやる前に必ず参照。カメラ設定の実測済み確定値と C930e の罠も。
---

# LCD バリデーションシステムの使い方

`tools/lcd-validation/` — 実機ディスプレイを Web カメラで撮り、AprilTag 60 個
(10x6) の検出でブート表示タイミングと表示異常をルールベース判定する。
設計書: `local/lcd_validation_system_design.md`、詳細手順: `tools/lcd-validation/README.md`。
新しい知見が出たらこの skill と README の両方に追記する。

## いつ使うか

- 起動時間の施策の前後比較 (Bootloader/Weston/GUI の first/50%/stable を秒精度で)
- 表示のズレ/スケール/クロップ/局所歪みの検証 (PASS/FAIL 自動判定)
- 従来の boot-visual-check.sh (輝度タイムライン) より細かい判定が要るとき

## クイックリファレンス (kart ベンチ)

```bash
cd tools/lcd-validation          # venv 無ければ README のセットアップを実行

# 1. パターン生成 (白レベル 224 が実測確定値)
.venv/bin/python generate_pattern.py --stage calibration \
    --output out/calibration.png --raw out/calibration.raw --white 224

# 2. ボードに表示 (wl-image-view = bitbake wl-image-view の deploy 産物)
scp -O ../../build/tmp/deploy/images/imx8mp-debix/wl-image-view \
    out/calibration.raw root@192.168.0.7:/tmp/
ssh root@192.168.0.7 'chmod +x /tmp/wl-image-view; su kart -s /bin/sh -c \
  "XDG_RUNTIME_DIR=/run/wayland WAYLAND_DISPLAY=wayland-1 \
   /tmp/wl-image-view /tmp/calibration.raw > /dev/null 2>&1 &"'
# 消すとき: ssh root@... 'kill -9 $(pidof wl-image-view)'
#   ※ pgrep -f + kill は ssh 自身の cmdline に自己マッチして死ぬ — pidof を使う

# 3. キャリブレーション (実測確定のカメラ設定込み)
.venv/bin/python calibrate.py --device /dev/kart-debix-cam \
    --width 1920 --height 1080 \
    --controls '{"exposure_time_absolute": 250, "gain": 32,
                 "exposure_dynamic_framerate": 0, "focus_absolute": 35}' \
    --output out/calibration.json --debug-dir out/calib-debug

# 4. 計測 (電源サイクル込み。Homography は固定 — 再計算禁止が設計の最重要ルール)
.venv/bin/python measure_boot.py --device /dev/kart-debix-cam \
    --calibration out/calibration.json --power-cycle --duration 20
```

## 実測で確定した設定 (2026-09-02、変える前に README の表を読む)

1920x1080/30/MJPG、白レベル **224**、exposure **250** / gain 32 /
**focus 35** / dynamic_framerate 0。この組で **60/60 連続検出、RMS 0.50px**。

## C930e の罠 (全部実測)

1. **コントロールは streamon で既定に巻き戻る** — 設定は必ずストリーム開始後。
   ツールは `Camera.setup()` がこの順序を実装済み。自前で v4l2-ctl を叩く
   ときも「1 フレーム読んでから設定」
2. **zoom_absolute が不揮発で残る** (zoom=299 が残って画角が切れた事故あり)。
   検出欠けが出たらまず `v4l2-ctl -d /dev/kart-debix-cam --list-ctrls` で
   zoom/pan/tilt を確認
3. focus_absolute は 0 (無限遠) で右下がボケ、50 以上で全滅 — 35 近辺
4. 検出が欠けたら数値だけ追わず `out/calib-debug/annotated.png` を目で見る
   (露出・フォーカス・画角のどれかはすぐ分かる)

## 未実装 (設計書 Phase 5-6)

30 分ごとの Photometric 再キャリブレーション、Fine Pattern (1px 縞) の
Pixel/Phase 検証、実ブート 3 stage のパターン組込み (logo.bin /
kart-splash-wl 差し替え — 配線案は README)。

## 関連

- カメラ/電源/シリアルの基礎操作と輝度タイムライン版: `imx8mm-xpi-bench` skill
  (カメラ節は DEBIX ベンチにもそのまま適用、カメラは `/dev/kart-debix-cam`)
- 表示チェーンとスプラッシュ設計: `docs/imx8mp-debix-bringup/06-splash.md`
