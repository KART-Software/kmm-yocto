# 03 — ブート経路(SDP → 自作 U-Boot → netboot)

自作イメージを **[eMMC](00-glossary.md#g-emmc) に一切書かず** に XPI で起動させる経路。[DTS](00-glossary.md#g-dts)/カーネルの
試行錯誤を焼き直し無しで回すためのもの。量産プロビジョニングの土台にもなる。

```
[PC] uuu(SDP)         [XPI BootROM]  → 自作 SPL(RAM)→ 自作 U-Boot(RAM)
                                                              │
[PC] TFTP: Image + DTB ────────────────────────────────────→ RAM
[PC] NFS: /srv/nfs/kart(rootfs)────────────────────────────→ root
                                                              │
                                                        カーネル 6.12 起動
```

## 前提

- ビルド: `./scripts/build.sh imx8mm --netboot`
  (`kas/imx8mm-netboot.yml` が [U-Boot](00-glossary.md#g-u-boot) NET とカーネル [NFS](00-glossary.md#g-nfs) を復活させる。
  通常の slim ビルドはこれらを削っている)
- 成果物(`build/tmp/deploy/images/imx8mm-lpddr4-evk/`):
  - `imx-boot`(= `flash.bin-...-sd`、[SPL](00-glossary.md#g-spl)+U-Boot、1.11MB)
  - `Image`(21.9MB)、`imx8mm-xpi-kart.dtb`(42KB)
  - `kart-image-...rootfs.tar.zst`(122MB、NFS へ展開)
- [TFTP](00-glossary.md#g-tftp)/NFS 準備済み([02-debug-setup.md](02-debug-setup.md))
- S1 を **Serial Download**(`1010 1010`)に設定

## Step 1 — SDP モードに入れる

S1 を Serial Download にして電源を入れ直す。[BootROM](00-glossary.md#g-bootrom) が USB [SDP](00-glossary.md#g-sdp) デバイスとして出現:

```bash
lsusb | grep 1fc9:0134   # NXP Semiconductors SE Blank M845S
uuu -lsusb               # 3:5 MX8MM SDP: 0x1FC9 0x0134
```

[UART](00-glossary.md#g-uart) は無音(BootROM は喋らない)。SDP は**無限に待てる**のでタイミング勝負が無い
(シリアル割り込みでの [autoboot](00-glossary.md#g-autoboot) 停止と違って確実)。

## Step 2 — 自作 U-Boot を RAM 起動(UUU)

**単純な `uuu SDP: boot -f imx-boot` では SPL しか送られず、U-Boot 本体を
待ったまま止まる**(SPL が `Trying to boot from USB SDP` で待機)。
ベンダ `uuu.auto` と同じく **SPL 後段([SDPV](00-glossary.md#g-sdpv))まで送るスクリプト**が要る。

スクリプトはリポジトリに入っている(`scripts/kart-boot.uuu`):

```
uuu_version 1.5.243
SDP:  boot  -f ../build/tmp/deploy/images/imx8mm-lpddr4-evk/flash.bin-imx8mm-lpddr4-evk-sd
SDPV: delay 1000
SDPV: write -f ../build/.../flash.bin-imx8mm-lpddr4-evk-sd -skipspl
SDPV: jump
```

> ⚠️ **[UUU](00-glossary.md#g-uuu-universal-update-utility) スクリプトのパスは「スクリプトのあるディレクトリからの相対」で解決される。**
> 絶対パスを書くと二重連結で壊れる(`scratchpad//home/...` エラー)。
> リポジトリ版が `../build/...` で書かれているのはこのため(`scripts/` 起点で
> デプロイディレクトリを指す。実行時の CWD には依存しない)。

実行(リポジトリ直下から):

```bash
uuu -v scripts/kart-boot.uuu
# SDP: boot ... Okay
# SDPV: write ... Okay
# SDPV: jump ... Okay
```

UART に自作 U-Boot が出る:

```
U-Boot SPL 2025.01-00005-gaa4bc52d08c3   ← DDR 訓練後に出るので DDR OK の証拠
...
U-Boot 2025.01 ...
Error: ethernet@30be0000 No valid MAC address found.   ← MAC 未焼き(後で手動設定)
Hit any key to stop autoboot: ...
u-boot=>
```

**この時点で自作 SPL(DDR)+ 自作 U-Boot が XPI で動いた** = 移行の技術的関門クリア。

## Step 3 — TFTP + NFS で自作カーネルを netboot

`u-boot=>` プロンプトで(**プロンプト同期で 1 コマンドずつ**、[04](04-pitfalls.md) 参照):

```
setenv ethaddr ac:db:da:69:be:8e            # 個体の MAC(未焼きなので手動)
setenv serverip 192.168.0.136               # ホスト(PC)
setenv ipaddr 192.168.0.16                  # ボード
setenv netmask 255.255.255.0
setenv loadaddr 0x40480000
setenv fdt_addr 0x43000000
tftp ${loadaddr} Image
tftp ${fdt_addr} imx8mm-xpi-kart.dtb
setenv bootargs 'console=ttymxc1,115200 root=/dev/nfs \
  nfsroot=192.168.0.136:/srv/nfs/kart,vers=3,tcp \
  ip=192.168.0.16:192.168.0.136:192.168.0.1:255.255.255.0:xpi:eth0:off \
  rw rootwait net.ifnames=0'
booti ${loadaddr} - ${fdt_addr}
```

**NFS root では [systemd-networkd](00-glossary.md#g-systemd-networkd) を止める必要がある**([04](04-pitfalls.md) の
「16 秒の壁」)。今回は NFS ディレクトリに直接 mask を投入:

```bash
R=/srv/nfs/kart
sudo ln -sf /dev/null $R/etc/systemd/system/systemd-networkd.service
sudo ln -sf /dev/null $R/etc/systemd/system/systemd-networkd.socket
sudo ln -sf /dev/null $R/etc/systemd/system/systemd-networkd-wait-online.service
```

起動が通ると:

```
VFS: Mounted root (nfs filesystem) on device 0:23.
...
Poky (Yocto Project Reference Distro) 5.0.19 imx8mm-lpddr4-evk ttymxc1
imx8mm-lpddr4-evk login:
```

## ベンダ U-Boot を使う代替経路

自作 U-Boot の bring up 前は、**ベンダ U-Boot(eMMC boot0)から netboot** もできた。
ベンダ Linux を SSH で `systemctl reboot -f` → 起動中に **U-Boot autoboot を
スペース連打で止める** → 同じ `tftp`/`booti` シーケンス。ただし autoboot 停止は
タイミング勝負で失敗しやすい(SPL でなく **U-Boot 段の "Hit any key" 数秒**を
狙う。スペースは開始直後から連打が確実)。SDP 経路の方が確実。

## デバイス側プラットフォーム判別(ota-update.sh 対応済み)

`kart-ab-status` の出力に `UBOOT_*` キーがあれば i.MX。`ota-update.sh` は
イメージの wic p1 サイズと合わせて自動判別する(RPi5 と共用)。
