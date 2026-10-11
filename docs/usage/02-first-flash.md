# 2. 最初の書き込み(新しい機体 → eMMC から自立起動)

eMMC の全体(SPL の A/B、env、BOOT、M コアの領域、root の A/B、data)を wic で一度に書く。
一度通せば、以後の更新は [04-ab-updates.md](04-ab-updates.md) の SSH 経由だけで済む。

**書き込むと eMMC の全部が置き換わる。** `/data` の `kmm.env` や Tailscale の参加状態も消えるので、
書いた後は [03-provisioning.md](03-provisioning.md) をやり直す。

## DEBIX(i.MX8MP)

方式: `uuu` で書き込み用の U-Boot を RAM で起動し、その fastboot で wic を eMMC(mmc 2)へ書く。
Linux が無くてもよい。2026-09-17 に製品構成の wic(3.65GB)を約 3 分で書いて、そのまま起動した。

### 用意するもの

- **書き込み用の U-Boot**: falcon を付けない、U-Boot proper 入りの imx-boot。falcon の SPL は USB 書き込み
  (SDP)の 2 段目を受けないので使えない。次のコマンドで `build/recovery/imx-boot-imx8mp-stock` に作る。
  別のビルドディレクトリ(`build/recovery-imx8mp`)で作るので、普段の成果物は変わらない

  ```bash
  ./scripts/build-recovery-uboot.sh imx8mp
  ```

- **展開した wic**: 置き場所は uuu のスクリプトが決めている

  ```bash
  bunzip2 -kc build/tmp/deploy/images/imx8mp-debix/kart-image-imx8mp-debix-emmc.wic.bz2 > build/recovery/flash.wic
  ```

- **USB の線**: 機体の Type-A の DWN_USB1(OTG ができる方の口)と PC を A-A ケーブルでつなぐ。
  LTE ドングルを挿している口と同じなので、抜いて差し替える

### 手順

1. ブートモードを USB 書き込み(DIP 001)にして電源を入れ直す。ベンチではリレーで切り替える
   ([07-bench.md](07-bench.md))。`lsusb` に `1fc9:0146`(NXP)が出ればよい

   ```bash
   python3 .claude/skills/debix-boot-switch/bootsel.py uuu && python3 scripts/dp100.py cycle --off-time 3
   ```

2. 書き込む。USB 機器の権限がログイン中の席にしか付かない PC では `sudo` が要る

   ```bash
   sudo uuu scripts/debix-flash-all.uuu
   ```

3. ブートモードを eMMC(DIP 010)に戻して電源を入れ直す

   ```bash
   python3 .claude/skills/debix-boot-switch/bootsel.py emmc && python3 scripts/dp100.py cycle --off-time 3
   ```

書く前に、線と書き込み用の U-Boot だけを確かめたいときは、手順 2 の代わりに
`sudo uuu scripts/debix-probe.uuu` を使う。eMMC には書かず、fastboot から読んだ eMMC の区画表が
シリアルに出る。

### 書いた直後の状態

- SPL は A と B の両方が wic の版になる
- env は既定値で、`boot_os` が無い。最初の起動は U-Boot proper 経由になり、起動できた時点で
  `falcon-rearm` が `boot_os=yes` を書くので、次からは falcon 経路になる
- Linux は a 面だけに入る。b 面は空
- M コアの領域(p3)は空で、M7 は動かない。CAN(`rpmsgcan0`)も無い
- `/data/kmm.env` が無いので kmm は起動に失敗する
- SSH のホスト鍵は最初の起動で作られ、`/data/ssh` に残る。`/data` ごと書き直したので、前と違う鍵になる
  ([03-provisioning.md](03-provisioning.md))

いずれも [03-provisioning.md](03-provisioning.md) で埋める。

## XPI(i.MX8MM)

U-Boot の `ums` で eMMC を PC のブロックデバイスとして見せ、bmaptool で wic を書く。ROM の
起動元を user 領域へ切り替える `mmc partconf` も同じ U-Boot で行う。手順は
[imx8mm-xpi-bringup/06-emmc-flash.md](../imx8mm-xpi-bringup/06-emmc-flash.md)。書き込み用の U-Boot は
`scripts/build-recovery-uboot.sh` で作る(`build/recovery/flash.bin-stock`)。

XPI のブートモードは基板の DIP S1 で、手で切り替える。触れないときは、動いている Linux から
SPL の A/B の IVT をわざと壊して USB 書き込みに落とす方法がある(`xpi-remote-sdp` スキル)。
