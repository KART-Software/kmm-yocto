---
name: imx8mm-xpi-bench
description: XPI-iMX8MM 実機ベンチの操作リファレンス — 電源(DP100)、シリアル、Web カメラでの画面目視検証、UUU/SDP、eMMC への flash.bin 書き込み。電源を入れ直す/シリアルを読む/画面をカメラで撮って検証する/ブートローダを焼く/UUU を使う前に必ず参照。
---

# XPI-iMX8MM ベンチ操作リファレンス

XPI (Geniatech i.MX8MM Mini) 実機を PC から操作する手順集。**毎回聞き直さない**ための恒久メモ。新しい知見が出たら追記する。

## 電源 (DP100 プログラマブル電源)

ボードは **ALIENTEK/ATORCH DP100** (USB `2e3c:af01`) で給電。`scripts/dp100.py` で制御。
**hidraw は root 専用なので sudo 必須**(このマシンは `sudo -n` = パスワード不要で通る)。

```bash
sudo python3 scripts/dp100.py status               # vin/vout/iout/温度/出力状態
sudo python3 scripts/dp100.py off                  # 出力 OFF
sudo python3 scripts/dp100.py on                   # 出力 ON
sudo python3 scripts/dp100.py cycle --off-time 3   # 電源断→投入 (コールドブート / SDP リセット)
```

→ **電源の入れ直しは自分でできる**(ユーザに頼まない)。`cycle` はコールドブート実測や、
wedge した SDP のリセット、warm reboot と違う真のリセットが要る時に使う。

## シリアルコンソール

udev 安定名 (`.claude/skills/xpi-serial-debug/` の rules。ttyACM 番号は変動するので必ずこちらを使う):
- `/dev/kart-a53-console` = A53/SPL/U-Boot コンソール (115200 8N1)
- `/dev/kart-m4-uart` = M4 UART4 コンソール
- `/dev/kart-teensy-diag` = ブリッジ自己診断 (1Hz)
- `/dev/kart-canable` = CANable (hcan0、slcand 使用。コンソールではない)

**注意: 連続リブート/USB churn 中に ttyACM0 の open() が D-state でハングすることがある**。
`fuser` は掴んでいないのに開けない時は **電源サイクル (dp100 cycle) で解消**。読み取りは
`O_NONBLOCK` + 自前タイムアウトで(scratchpad の sercap 系スクリプト参照)。ミラーは pts/15。


## 画面の目視検証 (Web カメラ)

LCD を **Logitech C930e (`046d:0843`)** で撮っている。ロゴ表示・暗転・GUI 出現など
「画面が実際どう見えるか」の検証や起動時間の実測に使う(シリアルログと突き合わせる)。

**1. どの video デバイスが LCD か特定**(番号は変わるので毎回テスト撮影で確認):
```bash
ls /dev/video*                                   # C930e は capture+metadata で 2 ノード持つ
for d in 0 2 4; do ffmpeg -y -f v4l2 -i /dev/video$d -frames:v 1 /tmp/t$d.jpg 2>/dev/null; done
# 各 jpg を Read ツールで見て、LCD が写っているものを選ぶ (この構成では /dev/video4)
```

**2. 起動中を録画**(バックグラウンドで回し、その間に電源サイクル):
```bash
ffmpeg -y -f v4l2 -framerate 30 -video_size 640x360 -i /dev/video4 -t 40 \
       -c:v libx264 -preset ultrafast -pix_fmt yuv420p rec.mkv &   # run_in_background 推奨
sudo python3 scripts/dp100.py cycle --off-time 3                    # 録画中に電源 OFF/ON
```

**3. 解析(3 通り)**:
```bash
# (a) 輝度プロファイルで遷移を数値化 (黒→ロゴ→GUI の時刻特定)
ffprobe -v error -f lavfi -i "movie=rec.mkv,fps=4,signalstats" \
  -show_entries frame=pts_time:frame_tags=lavfi.signalstats.YAVG -of csv=p=0
#   目安: 黒/消灯 Y<~30、SPL ロゴ Y~100、weston カーテンの沈み Y~66、GUI Y~140+
#   「消灯 (Y 急落) = リセット近傍」を基準に区間を測る

# (b) 黒区間の自動検出 (リブートの消灯時間など)
ffmpeg -i rec.mkv -vf "blackdetect=d=0.1:pix_th=0.10" -an -f null - 2>&1 | grep blackdetect

# (c) コマをタイル化して目視 (遷移を 1 枚で確認 → Read ツールで開く)
ffmpeg -y -ss 3 -i rec.mkv -t 7 -vf "fps=3,scale=200:-1,tile=7x3:padding=2:color=lime" \
       -frames:v 1 montage.jpg     # 左上→右下で時間進行。細部は 2x + crop
```
- モンタージュ/フレームは **Read ツールで開いて自分で確認**し、ユーザには **SendUserFile** で送る。
- ロゴ位置がオフセットロード等で正しいかの確認にも (c) が有効。
- 注意: カメラの自動露出でロゴが実際より明るく/フェードして見えることがある。輝度の絶対値より
  **区間の切れ目 (急変点)** を見る。

**典型ワークフロー**: 録画(bg)開始 → `dp100 cycle` → 録画終了待ち → (a) で区間時刻を出し
シリアルの SPL ログ(`ready`/`logo on`/`Falcon:`)と突き合わせ → (c) で見た目を確認 → 送付。

## UUU / SDP (Serial Download)

- **S1 = Serial Download** (物理 DIP スイッチ、ソフトからは変えられない) で電源投入すると
  BootROM が SDP に入る → `lsusb` に **`1fc9:0134` (SE Blank M845S)** が見える。
- **重要な制約: falcon 版 flash.bin は UUU で RAM 起動できない**。falcon SPL は SDP の
  SDPV ハンドシェイクを受けず、`SDP: boot -f flash.bin` を送っても SPL が走らない
  (USB は 0134 のまま遷移せず/HID timeout)。`scripts/kart-falcon-bench.uuu` は動かない。
  → **UUU 経路は常に stock 退避版** `local/recovery/flash.bin-stock`
  (`scripts/build-recovery-uboot.sh` で生成、`scripts/kart-boot.uuu` が参照)を使う。
- **SDP は繰り返し試行で wedge する** (HID timeout)。詰まったら `dp100 cycle` で仕切り直し。
  1 電源投入 = 1 発勝負のつもりで。

## eMMC の flash.bin (ブートローダ) を更新する

OTA は rootfs + falcon.itb + env しか触らない。**SPL/U-Boot コード = flash.bin は OTA で
配れない**。falcon 版は UUU RAM 起動も不可なので、更新は **stock U-Boot を RAM に上げて
`ums` で eMMC を露出 → dd** の一択:

```bash
# 1. S1=Serial で電源投入 (dp100 cycle)、lsusb に 1fc9:0134 を確認
# 2. stock U-Boot を RAM 起動しつつ autoboot を打鍵 (\n 連打) で止めて `=>` へ、
#    そこで ums を送る (scratchpad/uboot_catch.py が自動化: プロンプト検出→コマンド送信)
python3 scratchpad/uboot_catch.py /dev/ttyACM0 out.log 45 "ums 0 mmc 2" &
uuu scripts/kart-boot.uuu
# 3. eMMC user 領域が /dev/sda で見える (MODEL="UMS disk", ~7.8GB。ホストの nvme0n1 とは別物 — 必ず確認)
sudo blockdev --getsize64 /dev/sda        # 7.8GB なら eMMC
# 4. imx-boot(=flash.bin) は 33KiB (A コピー) に置く。SIT=32KiB, B コピー=2081KiB (wic の align 参照)
sudo dd if=/dev/sda bs=1k skip=33 count=2048 of=spl-A-backup.bin    # 旧をバックアップ
sudo dd if=build/tmp/deploy/images/imx8mm-xpi/flash.bin-imx8mm-xpi-sd of=/dev/sda bs=1k seek=33 conv=fsync
sync
# 5. Ctrl-C で ums 終了 (効かない時もあるが sync 済みなら OK)、電源 OFF、
#    S1=eMMC に切替 (ユーザ操作)、dp100 cycle で起動
```

**失敗しても再フラッシュで復旧可能**(同じ経路で backup or 既知 flash.bin を書き戻す)。
S1 は物理スイッチなのでユーザに「eMMC にして」と頼む必要がある(電源は自分で操作可)。

## 関連
- 設計/ブート順: `docs/imx8mm-xpi-bringup/08-falcon.md`, `03-boot-flow.md`, `06-emmc-flash.md`
- 低レベル概念 (RDC/ATF/rpmsg 等): `imx8mm-m4-knowledge` skill + `learning/` (m4 ブランチ)
