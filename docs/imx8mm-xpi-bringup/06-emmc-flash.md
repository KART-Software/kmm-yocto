# 06 — eMMC 初回書き込み(新品ボード → スタンドアロン起動)

新品(またはベンダ環境)の XPI-iMX8MM を、**電源投入だけで kart イメージが
[eMMC](00-glossary.md#g-emmc) から起動する状態**にするまでの手順書。2026-08-11 の実機実証
([05-next-steps](05-next-steps.md) C-4)を独立した手順に再構成したもの。

一度この手順を通せば、以後の更新は `scripts/ota-update.sh`(SSH 経由の A/B OTA)
だけで済み、この手順に戻ることはない。

方式は **netboot Linux から dd**(UUU の直接書き込みや `ums` は使わない)。
bring up で実績のある経路だけを使う構成で、[BootROM](00-glossary.md#g-bootrom) → SDP → netboot →
dd → partconf の 5 段。

```
[PC] uuu (scripts/kart-boot.uuu) → XPI RAM 上で自作 U-Boot
[PC] TFTP/NFS ──────────────────→ netboot Linux 起動 (eMMC 無関係)
netboot Linux 上で dd ──────────→ eMMC user 領域に A/B wic
SDP U-Boot で mmc partconf ─────→ ROM のブート元を user 領域へ
S1 を eMMC に → 電源投入 ───────→ スタンドアロン起動
```

## 前提

**ハードウェア:**

- デバッグ UART 接続済み([02-debug-setup.md](02-debug-setup.md) の Teensy ブリッジ。J63 ピン配置は [01-hardware.md](01-hardware.md))
- S1 DIP スイッチに触れること(位置と設定値は [01-hardware.md](01-hardware.md) のブートモード表)
- Ethernet をホスト PC と同一セグメントに接続

**ホスト側:**

- `uuu`(NXP mfgtools。導入は [02-debug-setup.md](02-debug-setup.md))
- TFTP + NFS サーバ([02-debug-setup.md](02-debug-setup.md)。netboot rootfs を `/srv/nfs/kart` に展開済み)

**ビルド(2 種類必要):**

```bash
./scripts/build.sh imx8mm --netboot   # 書き込み作業用: flash.bin / Image / DTB / rootfs.tar.zst
./scripts/build.sh imx8mm --emmc      # 焼く対象: kart-image-...-emmc.wic (A/B レイアウト, 3.9GB raw)
```

netboot 側の成果物は TFTP/NFS に配置し、eMMC 用 wic は netboot Linux から
見える場所に置く(一番簡単なのは NFS root 内):

```bash
cp build/tmp/deploy/images/imx8mm-lpddr4-evk/kart-image-*-emmc.wic /srv/nfs/kart/root/kart-emmc.wic
```

## Step 0 — (推奨) バックアップ

ベンダ環境に戻せるように。手順は [02-debug-setup.md](02-debug-setup.md) の
「ボード全体のバックアップ(文鎮化保険)」。
最低限、eMMC user 領域の先頭 8MiB(パーティションテーブル+ベンダ U-Boot env)は
取っておく。**boot0 のベンダブートローダはこの手順では無傷**なので、完全復帰は
「user 領域をベンダ `.sdcard` から書き戻し + `mmc partconf 2 0 1 0`」で可能。

## Step 1 — SDP モードで自作 U-Boot を RAM 起動

S1 を **Serial Download(`1010 1010`)** にして電源を入れ直す。UART は無音のまま
(BootROM は喋らない)、USB に SDP デバイスが出る:

```bash
lsusb | grep 1fc9:0134    # NXP Semiconductors SE Blank M845S
```

リポジトリ直下から:

```bash
uuu -v scripts/kart-boot.uuu
# SDP: boot ... Okay / SDPV: write ... Okay / SDPV: jump ... Okay
```

UART に `U-Boot SPL 2025.01`(= DDR 訓練成功)→ `u-boot=>` プロンプトが出る。
`No valid MAC address found` の警告は正常(個体 MAC 未焼き。次で手動設定)。
詰まったら [03-boot-flow.md](03-boot-flow.md) Step 1–2 と [04-pitfalls](04-pitfalls.md) を参照。

## Step 2 — netboot Linux を起動

`u-boot=>` で以下を **1 コマンドずつプロンプト同期で** 流す(まとめ貼りは
シリアル RX オーバーランで化ける — [04](04-pitfalls.md))。IP/MAC は環境に合わせる:

```
setenv ethaddr ac:db:da:69:be:8e            # 任意のローカル管理 MAC
setenv serverip 192.168.0.136               # ホスト PC
setenv ipaddr 192.168.0.16                  # ボード
setenv netmask 255.255.255.0
setenv loadaddr 0x40480000
setenv fdt_addr 0x43000000
tftp ${loadaddr} Image
tftp ${fdt_addr} imx8mm-xpi-kart.dtb
setenv bootargs 'console=ttymxc1,115200 root=/dev/nfs nfsroot=192.168.0.136:/srv/nfs/kart,vers=3,tcp ip=192.168.0.16:192.168.0.136:192.168.0.1:255.255.255.0:xpi:eth0:off rw rootwait net.ifnames=0'
booti ${loadaddr} - ${fdt_addr}
```

login プロンプトまで到達すること(NFS root 特有の networkd mask など、詳細は
[03](03-boot-flow.md) Step 3)。

## Step 3 — eMMC user 領域へ dd

netboot Linux 上で(rootfs は NFS なので eMMC はどこもマウントされていない):

```sh
dd if=/root/kart-emmc.wic of=/dev/mmcblk2 bs=1M
sync
```

- 書くのは **user 領域のみ**。boot0(ベンダブートローダ)には触れない
- ベンダの user 領域パーティション(旧 p1/p2/p3)はここで消える
- 終わったら `poweroff`

## Step 4 — ROM のブート元を user 領域へ切り替え

BootROM は eMMC の **[boot0](00-glossary.md#g-emmc) を見る設定(partconf 1)が出荷時デフォルト**。
自作構成は user 領域先頭に SPL を置いているので、切り替えが必要。

S1 は Serial Download のまま電源を入れ直し、もう一度 `uuu -v scripts/kart-boot.uuu`
で `u-boot=>` に入って:

```
mmc partconf 2 0 7 0
```

(`2` = eMMC デバイス番号、`7` = BOOT_PARTITION_ENABLE を user 領域に。
**ベンダ復帰は `mmc partconf 2 0 1 0`**)

## Step 5 — スタンドアロン起動確認

S1 を **eMMC(`0110 1010`)** にして電源投入。UART で確認:

```
Trying to boot from MMC2          ← ROM が user 領域から SPL を読んだ
KART: booting slot a (mmc 2:1)    ← wic に焼き込んだ A/B env が機能
...
imx8mm-lpddr4-evk login:          ← 実測 +15.4s (シリアル初バイト起点)
```

起動後の健全性: `kart-ab-status`(slot A / upgrade_available=0)、
`systemctl is-active weston kmm can0-up`、`/data` が rw マウント、
`systemctl --failed` が空、を確認。

## Step 6 — プロビジョニング(デバイス個体ごとに一度)

- アプリの秘密情報: `scp .env root@<host>:/data/kmm.env`(`/data` は OTA を跨いで永続)
- MAC は未焼きのまま運用可(DHCP の IP は変わり得るが tailscale 名運用なら影響なし)。
  固定したい場合は `fw_setenv ethaddr <MAC>` で U-Boot env に恒久化

## 以後の更新

```bash
./scripts/ota-update.sh --host <host> [--yes] build/tmp/deploy/images/imx8mm-lpddr4-evk/kart-image-*-emmc.wic.bz2
```

A/B の仕組み・フォールバック挙動(起動失敗 → bootcount 超過 → 旧スロット自動復帰、
無人 84s 実測)は [05-next-steps](05-next-steps.md) C-4 を参照。
