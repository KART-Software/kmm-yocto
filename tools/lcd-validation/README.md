# LCD Validation System

実機ディスプレイを Web カメラで撮影し、Bootloader → Weston → GUI の表示
タイミングと表示異常 (位置ずれ/スケール/クロップ/局所歪み) を自動判定する。
設計書: `local/lcd_validation_system_design.md`(ML 不使用、AprilTag 36h11 +
OpenCV aruco のルールベース)。

## セットアップ (ホスト)

```bash
cd tools/lcd-validation
python3 -m venv .venv
.venv/bin/pip install opencv-python-headless numpy
```

kart ベンチのカメラは udev 永続名 `/dev/kart-debix-cam`(C930e)。

## 使い方

### 1. パターン生成

```bash
.venv/bin/python generate_pattern.py --stage calibration \
    --output out/calibration.png --raw out/calibration.raw
```

stage = calibration / bootloader / weston / gui(ID 帯 0/100/200/300-)。
`--raw` は XRGB8888 生データ(ボード表示用)。白レベル既定 128(§13)。

### 2. ボードにパターンを表示

ビューアは `wl-image-view`(meta-kart のベンチ用レシピ。イメージには
入れない — deploy 産物を scp する):

```bash
kas-container shell <構成> -c "bitbake wl-image-view"
scp build/tmp/deploy/images/imx8mp-debix/wl-image-view root@<board>:/tmp/
scp out/calibration.raw root@<board>:/tmp/
ssh root@<board> 'su kart -s /bin/sh -c \
  "XDG_RUNTIME_DIR=/run/wayland WAYLAND_DISPLAY=wayland-1 \
   /tmp/wl-image-view /tmp/calibration.raw" &'
```

kiosk-shell は最後にマップされた surface を前面に出すので、kmm の上に
パターンが表示される。消すときはプロセスを kill。

### 3. Geometric Calibration(§6-9)

GUI 完全起動 + Calibration Pattern 表示状態で:

```bash
.venv/bin/python calibrate.py --device /dev/kart-debix-cam \
    --output calibration.json --debug-dir out/calib-debug
```

- 60 タグ連続検出 → Homography(全点 + RANSAC)→ 品質(RMS ゲート)
- カメラ設定は自動を切って固定(§12)。露出等を明示するなら
  `--controls '{"exposure_time_absolute":100,"gain":64}'`
- 以後カメラとディスプレイを**物理的に動かさない**(§11)

### 4. 計測(§30)

```bash
.venv/bin/python measure_boot.py --device /dev/kart-debix-cam \
    --calibration calibration.json --power-cycle --duration 20
```

- Homography は calibration.json のものに**固定**(§10 — 再計算禁止)
- `--power-cycle` は `scripts/dp100.py` で電源断→投入(sudo -n)
- フレームごとの CSV(§32)と §36 形式の最終レポートを出力
- GUI stable 時 RMS が `--camera-moved-rms` 超なら INVALID(CAMERA_MOVED)

## 実ブート 3 stage 計測(実験モード、実機検証済み 2026-09-02)

`target-stage-setup.sh` が可逆な差し替え一式を行う:

```bash
# 素材 (bootloader は KLGO、weston/gui は raw)
.venv/bin/python generate_pattern.py --stage bootloader \
    --output out/bootloader.png --klgo out/bootloader.klgo
./target-stage-setup.sh install     # logo.bin 交換 + unit drop-in x2
.venv/bin/python measure_boot.py --device /dev/kart-debix-cam \
    --calibration out/calibration.json --power-cycle --duration 22
./target-stage-setup.sh uninstall   # 完全に元へ戻す
```

差し替えの中身: ① `/boot/logo.bin` → bootloader パターンの KLGO
(SPL がそのまま blit する。原本は logo.bin.orig に退避)
② kart-splash-wl.service → wl-image-view weston.raw(drop-in)
③ kmm.service → wl-image-view gui.raw(drop-in、Type=simple 化)。

実測: SPL blit のパターンでも **60/60・RMS 0.56px で全検証 PASS**
(1bit なので白=255 だが、確定露出のままで飽和せず検出できた)。
bootloader first は電源 +0.7s(シリアル実測と一致)、weston stable は
gui が ~50ms 後に被さるため未達になるのが正常(Mixed フレームは記録される)。

## 実装フェーズの状態

- Phase 1-4(パターン/検出/Calibration/Stage 判定/タイミング/検証/PASS-FAIL/
  ログ): 実装済み
- Phase 5: カメラ移動検出は最終判定に組込済み。30 分ごとの Photometric
  再キャリブレーション(§14)は未実装(`camera.luminance_stats` が部品)
- Phase 6(Fine Pattern / Pixel-Phase): 未実装。`validation.py` と独立の
  モジュールとして追加する構造(§28)

## ベンチ実測で決めた設定 (§35 マイルストーン、2026-09-02)

kart ベンチ (C930e + DEBIX 800x480 パネル、暗環境) での確定値:

| 項目 | 値 | 根拠 |
|---|---|---|
| 解像度 / FPS / 形式 | 1920x1080 / 30 / MJPG | 720p ではモジュール解像度が限界 (58/60 止まり) |
| 白レベル | **224** | 128 だと視野角でコントラストが薄い領域 (上段) が落ちる |
| exposure_time_absolute | 250 | 400 以上で白飽和が始まり検出数が崩壊 |
| gain | 32 | |
| focus_absolute | **35** | 0 (無限遠) だと右下がボケて 56-58/60。50 以上で全滅 |
| exposure_dynamic_framerate | 0 | |

結果: **60/60 連続検出、Homography RMS 0.50px / max 1.13px**。
E2E (パターン切替の疑似ブート) で stage timing + 全検証 PASS、
処理 ~23fps (detect 29ms が支配的)。

### 運用上の教訓 (実測)

- **C930e はコントロールが streamon で既定へ巻き戻る**。設定は必ず
  ストリーム開始後に行う (`Camera.setup()` がこの順序を実装)
- **zoom_absolute が不揮発で残る個体がある** (zoom=299 が残っていて画角が
  切れた)。zoom/pan/tilt も calibration.json から毎回再適用する
- calibrate 前にボードの表示を確認せず数値だけ追わない — 検出欠けの原因は
  露出/フォーカス/画角のどれもあり得る (`out/calib-debug/annotated.png` を見る)

## 制約・既知の注意

- タイムスタンプは `time.monotonic_ns()`(read 直後)。V4L2 frame timestamp
  は cv2 経由で取れないため誤差 ~1 フレーム(§21 の代替規定)
- タグ 56px は 36h11 の 10 モジュールで割り切れない(モジュール幅 5-6px 混在)。
  検出は問題ないが、気になる場合は `--tag-size 50` か `60`
- Experiment 中に Homography を更新しない・カメラが動いたら INVALID、は
  設計書 §37 の最重要ルール。ツールもその前提で書かれている
