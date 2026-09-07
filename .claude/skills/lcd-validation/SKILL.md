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
- **起動系ユニットの変更後は必ずこのツールのパターン解析で実表示を確認する** —
  systemd が全ユニット active・weston 無エラー・EDID/モード正常でも画面が
  出ていないブートが実在した (2026-09-03、weston 早期化の撤回事例 =
  docs/imx8mp-debix-bringup/30-boot-time.md)。
  **輝度 crop での BRIGHT/DARK 判定は禁止** — GUI の暗い部分と
  バックライトのみの黒が Y≈108-111 で重なり判別不能で、2026-09-04 に
  暗ブートを大量に BRIGHT と誤判定した。判定は必ず AprilTag 検出
  (measure_boot.py / calibrate.py) を使う。vblank IRQ デルタ(`/proc/interrupts` の
  lcdif)は静止パターンでは idle の weston でも 0 になるので単独判定に使わない。
  「INT_ENABLE_D0 に VS_BLANK を立ててもカウンタ不動」も走査停止の証拠にならない
  (DRM 側 vblank->enabled が偽ならカウントされない。2026-09-07 に誤読と判明)。
  走査の生死を見たいときは weston.ini の background-color を変えて画面を見る。

## クイックリファレンス (実機ベンチ)

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

## 実ブート 3 stage 計測 (検証済み) — 鉄則: 3 段とも差し替える

**AprilTag で実ブートを判定するときは、必ず `target-stage-setup.sh install` で
bootloader / weston / GUI の 3 ステージ全部をパターンに差し替える。
GUI だけ(あるいは一部だけ)wl-image-view に差し替える自己流は禁止。**

```bash
./target-stage-setup.sh install    # logo.bin→LOGO、splash-wl→weston.raw、kmm→gui.raw (可逆)
.venv/bin/python measure_boot.py --device /dev/kart-debix-cam \
    --calibration out/calibration.json --power-cycle --duration 22
./target-stage-setup.sh uninstall  # 必ず戻す (製品状態に復帰)
```

理由 (2026-09-04 に丸一日の計測が無効になった実例): splash-wl(本物ロゴ)は
退場しない常駐クライアントで、kiosk-shell は最後に map した surface を前面に置く。
GUI だけパターンにすると、ロゴがパターンの上に乗った boot が「タグ 0 = 暗」と
誤計上され、表示が生きているのに暗ブートと区別できない。3 段ともステージ別 ID の
タグなら「どの段の絵が前面か」が分かり、「weston 段が前面に残って GUI が隠れる」
(map 順レース)と「本当に真っ黒」を分けられる。

- install が `/boot` の remount で失敗したら原因(vfat モジュール不整合など)を
  直してから進める。GUI だけ手で drop-in して逃げない
- 判定は run ごとの `measure_boot.csv`(`stage` 列と `*_tag_count`)で見る。
  最終 2 秒の stage が gui でなければ「前面に残った段」として報告する
- 静止パターンでは vblank IRQ デルタは使えない(repaint が無く weston が IRQ を
  止めるので表示が生きていても 0)。判定はタグ検出のみ
- SPL blit の 1bit パターン (白=255) でも確定露出のまま 60/60・PASS。
  正常時は weston stable が gui に即被さって未達になる
- **install したまま放置しない** — uninstall まで含めて 1 実験

## 未実装 (設計書 Phase 5-6 の残り)

30 分ごとの Photometric 再キャリブレーション、Fine Pattern (1px 縞) の
Pixel/Phase 検証。

## 関連

- カメラ/電源/シリアルの基礎操作と輝度タイムライン版: `imx8mm-xpi-bench` skill
  (カメラ節は DEBIX ベンチにもそのまま適用、カメラは `/dev/kart-debix-cam`)
- 表示チェーンとスプラッシュ設計: `docs/imx8mp-debix-bringup/06-splash.md`
