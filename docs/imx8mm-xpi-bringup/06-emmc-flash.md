# 06 — eMMC 初回書き込み(新品ボード → スタンドアロン起動)

新品(またはベンダ環境)の XPI-iMX8MM を、**電源投入だけで kart イメージが
[eMMC](00-glossary.md#g-emmc) から起動する状態**にするまでの手順書。

一度この手順を通せば、以後の更新は `scripts/ota-update.sh`(SSH 経由の A/B OTA)
だけで済み、この手順に戻ることはない。

方式は **UMS 直書き**: uuu で RAM に U-Boot を上げ、`ums` で eMMC を PC の
ブロックデバイスとして見せて bmaptool で焼く。uuu は 1 周だけ、
TFTP/NFS サーバも netboot イメージも不要で、authkey 注入と `partconf` まで
同じセッションで完結する。

```
[PC] uuu (scripts/kart-boot.uuu) → XPI RAM 上で自作 U-Boot (eMMC 無関係)
u-boot=> ums 0 mmc 2 ───────────→ eMMC user 領域が PC の /dev/sdX に
[PC] bmaptool + authkey ────────→ A/B wic 書き込み + tailscale 鍵
u-boot=> mmc partconf ──────────→ ROM のブート元を user 領域へ
S1 を eMMC に → 電源投入 ───────→ スタンドアロン起動 → tailnet 自動参加
```

(旧手順の netboot Linux + dd 経路は文末「リカバリ — netboot 経路」に温存。
U-Boot が上がらない・USB が使えない等の深い状態からの復旧はそちら)

検証状態: `ums` の公開・boot FAT への書き込み・S1 切替なしの ums 進入は
実機検証済み(2026-08-12)。フルイメージの bmaptool 書き込みは初回セットアップ
経路としては未実測(所要時間を次の新品ボードで確認する)。

## 前提

**ハードウェア:**

- デバッグ UART 接続済み([02-debug-setup.md](02-debug-setup.md) の Teensy ブリッジ。J63 ピン配置は [01-hardware.md](01-hardware.md))
- S1 DIP スイッチに触れること(位置と設定値は [01-hardware.md](01-hardware.md) のブートモード表)
- USB OTG ケーブルで PC と接続(uuu / SDP と同じケーブルを ums でも使う)

**ホスト側:**

- `uuu`(NXP mfgtools。導入は [02-debug-setup.md](02-debug-setup.md))
- `bmaptool`(Debian/Ubuntu: `sudo apt install bmap-tools`。無ければ dd でも可)
- **stock U-Boot** — `./scripts/build-recovery-uboot.sh` で
  `local/recovery/flash.bin-stock` を生成しておく(kart-boot.uuu が参照)。
  falcon 運用 ([08-falcon.md](08-falcon.md)) の flash.bin は SDPV を受けず
  `u-boot=>` に到達できないため、**UUU 経路は常に stock 版**を使う

**ビルド:**

```bash
./scripts/build.sh imx8mm --emmc      # kart-image-...-emmc.wic (A/B レイアウト, 3.9GB raw)
```

prod を焼く場合は `kas-container build kas/imx8mm-prod.yml:kas/imx8mm-emmc-ab.yml`
(`DL_DIR`/`SSTATE_DIR` の export を忘れずに — CLAUDE.md)。
deploy ディレクトリに `.wic` / `.wic.bz2` / `.wic.bmap` が並ぶ。

## Step 0 — (推奨) バックアップ

ベンダ環境に戻せるように。手順は [02-debug-setup.md](02-debug-setup.md) の
「ボード全体のバックアップ(文鎮化保険)」。
最低限、eMMC user 領域の先頭 8MiB(パーティションテーブル+ベンダ U-Boot env)は
取っておく。**boot0 のベンダブートローダはこの手順では無傷**なので、完全復帰は
「user 領域をベンダ `.sdcard` から書き戻し + `mmc partconf 2 0 1 0`」で可能。
(バックアップの採取自体も後述の ums で PC 側から dd するのが楽)

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

UART に `U-Boot SPL 2025.01`(= DDR 訓練成功)が出たら、autoboot
(`bootdelay=1`)を打鍵で止めて `u-boot=>` に入る(空の eMMC なら bootcmd が
失敗してどのみちプロンプトに落ちる)。
`No valid MAC address found` の警告は正常(個体 MAC 未焼き。ums には無関係)。
詰まったら [03-boot-flow.md](03-boot-flow.md) Step 1–2 と [04-pitfalls](04-pitfalls.md) を参照。

## Step 2 — ums で eMMC を PC に見せる

```
u-boot=> ums 0 mmc 2        # USB0 gadget で eMMC user 領域(mmc 2)を公開
```

SDP と同じ USB ケーブルのまま、PC に `/dev/sdX`(7.3GB "UMS disk 0")が出る:

```bash
lsblk -S | grep -i usb      # デバイス名を確認 (以下 sdX と表記)
```

`ums` 中は PC からの読み書きがそのまま eMMC に落ちる。boot0/boot1 ハード
パーティションは公開されないので、**ベンダブートローダ(boot0)には触れようがない**。

なお falcon 構成の wic は U-Boot A/B の**両面とも falcon** になる(既存ボードの
「B 面 = stock」は kart-uboot-update の温存による)。新品ボードの最終復旧は
UUU + stock (`local/recovery/flash.bin-stock`) と覚えておくこと。

## Step 3 — wic を書き込む

```bash
sudo bmaptool copy \
    build/tmp/deploy/images/imx8mm-xpi/kart-image-imx8mm-xpi-emmc.wic.bz2 \
    /dev/sdX
```

- bmaptool は `.wic.bmap` を自動で見つけ、実データブロックだけを書く
  (bz2 のまま食わせられる)。USB 2.0 HS 越しなので生 dd よりだいぶ速い
- bmaptool が無い場合: `bunzip2 -kc …-emmc.wic.bz2 | sudo dd of=/dev/sdX bs=4M`
- 途中で失敗しても板はもともと空 — やり直すだけ
- wic には [SIT](00-glossary.md#g-sit) / U-Boot A/B コピー / env(kart_slot)まで
  rawcopy で全部入っている。書くのはこの 1 ファイルだけ

### Step 3.5 — tailscale authkey 注入(prod イメージのとき必須級)

prod にはローカルログインが無いので、初回起動で tailnet に自動参加させて
以後のアクセスを Tailscale SSH にする。同じ ums セッションのまま:

```bash
sudo mount /dev/sdX1 /mnt            # p1 = BOOTA (初回起動スロット)
echo 'tskey-auth-…' | sudo tee /mnt/tailscale.authkey
sudo umount /mnt
```

初回起動時に `kart-boot-mount.service` が BOOTA を `/boot` にマウントし、
`tailscale-autoconnect.service` が `tailscale up --ssh` で接続、成功したら
鍵を自動削除する。失敗時は鍵を残して毎起動リトライするので、ネットが
繋がった起動で自動回復する。

鍵は admin console で **pre-approved・非 ephemeral** で発行すること
(approval 待ちは `tailscale up` がブロック、ephemeral は切断で識別が消える)。
複数台展開は reusable + タグ付き(例 `tag:kart`)にして ACL をタグで書く。

なお**稼働中**ボードのスロット更新で注入する場合は
`ota-update.sh --authkey <file>` を使う(boot コピーが書き込み先を
`rm -rf` してから展開するため、事前に手で置いた鍵は消される。
dev → prod 移行で tailnet 参加まで実機検証済み 2026-08-12)。

## Step 4 — ROM のブート元を user 領域へ切り替え

BootROM は eMMC の **[boot0](00-glossary.md#g-emmc) を見る設定(partconf 1)が出荷時デフォルト**。
自作構成は user 領域先頭に SPL を置いているので、切り替えが必要。

シリアルで **Ctrl-C** を送って ums を抜け、同じ `u-boot=>` セッションで:

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
```

- dev イメージなら login プロンプトまで(実測 +15.4s、シリアル初バイト起点)
- prod はシリアルログイン不可。健全性は tailnet 参加
  (`tailscale status | grep <ホスト名>`)→ Tailscale SSH で確認:
  `kart-ab-status`(slot A / upgrade_available=0)、
  `systemctl is-active weston kmm can0-up`、`systemctl --failed` が空

## Step 6 — プロビジョニング(デバイス個体ごとに一度)

- アプリの秘密情報: `scp .env root@<host>:/data/kmm.env`(`/data` は OTA を跨いで永続)
- MAC は未焼きのまま運用可(DHCP の IP は変わり得るが tailscale 名運用なら影響なし)。
  固定したい場合は `fw_setenv ethaddr <MAC>` で U-Boot env に恒久化

## 以後の更新

```bash
./scripts/ota-update.sh --host <host> [--yes] [--authkey <file>] build/tmp/deploy/images/imx8mm-xpi/kart-image-*-emmc.wic.bz2
```

A/B の仕組み・フォールバック挙動(起動失敗 → bootcount 超過 → 旧スロット自動復帰、
無人 84s 実測)は [05-next-steps](05-next-steps.md) C-4 を参照。

## 補足 — 稼働中ボードへの ums(S1 切替不要)

起動できるボードなら Serial Download に落とす必要はない(実機検証 2026-08-12):
reboot してシリアルから autoboot(`bootdelay=1`)を打鍵で止め、eMMC 起動した
U-Boot でそのまま `ums 0 mmc 2` すればよい。Tailscale SSH で reboot →
シリアル打鍵、で**物理操作ゼロ**の完全リモート進入もできる。
パーティション確認・バックアップ採取・boot FAT への小物置きに便利。

- **書く先のパーティション番号に注意**: スロット B の boot は p2。起動時に
  `/boot` へマウントされるのは「次回起動するスロット」の側
- 終わったら Ctrl-C → `reset` で通常起動に復帰

## リカバリ — netboot 経路(TFTP/NFS)

U-Boot は上がるが USB が使えない、eMMC の状態をデバイス上の Linux から
調べたい、といった深い状態からの復旧用。bring up 全体で実績のある経路
(2026-08-11 の初回実機書き込みはこの方法で実施)。

前提: ホストに TFTP + NFS サーバ([02-debug-setup.md](02-debug-setup.md)。
netboot rootfs を `/srv/nfs/kart` に展開)、
`./scripts/build.sh imx8mm --netboot` の成果物(flash.bin / Image / DTB /
rootfs.tar.zst)を配置。焼く wic は NFS root 内に置く
(`cp … /srv/nfs/kart/root/kart-emmc.wic`)。

Step 1 の `u-boot=>` から、以下を **1 コマンドずつプロンプト同期で** 流す
(まとめ貼りはシリアル RX オーバーランで化ける — [04](04-pitfalls.md))。
IP/MAC は環境に合わせる:

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

login プロンプトまで到達したら(NFS root 特有の networkd mask など、詳細は
[03](03-boot-flow.md) Step 3)、netboot Linux 上で dd
(rootfs は NFS なので eMMC はどこもマウントされていない):

```sh
dd if=/root/kart-emmc.wic of=/dev/mmcblk2 bs=1M
sync
```

authkey を置くなら dd 直後に `mount /dev/mmcblk2p1 /mnt` して
`tailscale.authkey` を書く(Step 3.5 と同じ内容)。あとは `poweroff` して
Step 4(partconf)以降は本編と同じ — ただし netboot 経路では ums を
使っていないので、もう一度 `uuu -v scripts/kart-boot.uuu` で `u-boot=>` に
入り直してから `mmc partconf 2 0 7 0` を打つ。

注意: U-Boot のネットワークは製品ビルドでは削られている
(kart-uboot-slim.cfg)。netboot には `kas/imx8mm-netboot.yml` を合成した
flash.bin が必要(`./scripts/build.sh imx8mm --netboot` はそれを含む)。
