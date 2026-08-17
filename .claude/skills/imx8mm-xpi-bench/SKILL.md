---
name: imx8mm-xpi-bench
description: XPI-iMX8MM 実機ベンチの操作リファレンス — 電源(DP100)、シリアル、UUU/SDP、eMMC への flash.bin 書き込み。電源を入れ直す/シリアルを読む/ブートローダを焼く/UUU を使う前に必ず参照。
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

udev 安定名 (`.claude/skills/xpi-serial-debug/` の rules。無ければ ttyACM で代替):
- `/dev/kart-a53-console` → ttyACM0 (Teensy Dual Serial if00) = A53/SPL/U-Boot コンソール (115200 8N1)
- `/dev/kart-m4-uart` → ttyACM1 (if02) = M4 UART
- ttyACM2 = CANable (hcan0、slcand 使用中。コンソールではない)

**注意: 連続リブート/USB churn 中に ttyACM0 の open() が D-state でハングすることがある**。
`fuser` は掴んでいないのに開けない時は **電源サイクル (dp100 cycle) で解消**。読み取りは
`O_NONBLOCK` + 自前タイムアウトで(scratchpad の sercap 系スクリプト参照)。ミラーは pts/15。

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
