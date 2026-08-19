# kmm-yocto — Kart Product Yocto Build (XPI-iMX8MM)

Geniatech **XPI-iMX8MM**(NXP i.MX8M Mini、RPi 互換フォームファクタ SBC)向けの
組み込み Linux イメージを Yocto (scarthgap) + kas-container で構築するプロジェクト。
自作 SPL / U-Boot / カーネル 6.12 を載せ、Wayland/Weston 上で C++/Qt6 の
キオスク GUI (`kmm`) を動かす。CAN・Tailscale・OTA・SPL スプラッシュ対応。

> 前身は Raspberry Pi 5 ターゲット。RPi5 のビルド系(`kas/rpi5*.yml`・
> EEPROM/NVMe 手順)は残しているが、**現行の製品ターゲットは XPI-iMX8MM**。
> 本 README はそちらを主に記述する。RPi5 固有の手順は git 履歴と
> `kas/rpi5-prod.yml` を参照。

## 概要

| 項目 | 内容 |
|------|------|
| ターゲット | XPI-iMX8MM (Geniatech, i.MX8M Mini Quad A53 + Cortex-M4) |
| ストレージ / ブート | eMMC (`/dev/mmcblk2`)、**Falcon Mode**(SPL 直カーネル) |
| Yocto リリース | scarthgap (5.0) |
| ビルドツール | kas-container (Docker) |
| ブートローダ | 自作 SPL + U-Boot 2025.01 (u-boot-fslc)、A/B 冗長 (ROM SIT) |
| カーネル | linux-fslc 6.12 |
| GUI | Wayland + Weston (kiosk) + C++/Qt6 Widgets (`kmm`) |
| 表示 | MIPI-DSI → LT9611 → HDMI、SPL スプラッシュ(暗転ゼロ引き継ぎ) |
| CAN | MCP2515 を **Cortex-M4 ゲートウェイ**経由で SocketCAN 化 (rpmsg candev) |
| init / ネットワーク | systemd / systemd-networkd |
| リモートアクセス | Tailscale SSH (prod はこれが唯一の手段) |
| 更新 | A/B OTA (SSH 経由、失敗時ファーム自動フォールバック) |

## ハードウェア

| 項目 | 値 | 備考 |
|------|-----|------|
| SoC | i.MX8M Mini Quad Cortex-A53 @1.8GHz + Cortex-M4 | |
| RAM | 2GB LPDDR4 | 実機実測(スペック表の 1GB ではなく上位構成) |
| eMMC | Samsung 8GB (`8GTF4R`)、HS400 Enhanced strobe | `/dev/mmcblk2` |
| 表示 | MIPI-DSI → LT9611(Lontium, I2C4 @0x3b)→ HDMI | EVK の ADV7535 とは別チップ |
| CAN | MCP2515 (ECSPI2) — **M4 が所有**しゲートウェイ化 | 40 ピンヘッダ経由 |
| ブートモード | 物理 DIP スイッチ **S1**(eMMC / Serial Download) | ソフトからは変えられない |

実機の一次情報(ピン配置・DTB 解析・ブートモード)は
[docs/imx8mm-xpi-bringup/01-hardware.md](docs/imx8mm-xpi-bringup/01-hardware.md)。
ベンチ機材(DP100 電源・シリアル・カメラ検証・UUU)の操作は
`imx8mm-xpi-bench` スキルを参照。

## 前提条件

- **Ubuntu 22.04 以降**(WSL2 含む)、Docker、kas-container
- 十分なディスク容量(初回ビルドで 50GB 以上推奨)
- 実機書き込みに **NXP `uuu`**(mfgtools)。SDP 経由の初回書き込み・復旧で使う
- **NXP EULA への同意**が必要(`imx-boot` の DDR トレーニング FW = firmware-imx が
  EULA 配布)。`kas/imx8mm.yml` で `ACCEPT_FSL_EULA = "1"` を設定済み

```bash
sudo apt install pipx
pipx ensurepath
pipx install kas
# uuu: https://github.com/nxp-imx/mfgtools/releases から取得し PATH へ
```

## ビルド

### build.sh(開発イメージ)

```bash
./scripts/build.sh imx8mm --emmc      # eMMC A/B レイアウト (本命)
./scripts/build.sh imx8mm --netboot   # TFTP/NFS netboot (DTS/ドライバ試行用)
./scripts/build.sh imx8mm             # 素の EVK SD 持ち込み用 (シングルスロット)
```

`imx8mm` ターゲットは開発イメージ(debug-tweaks 入り)。`--emmc` を付けると
eMMC A/B の WKS になる(付けないと machine 既定のシングルスロット)。

### 本番 + Falcon + スプラッシュ(kas 直実行)

`build.sh` は開発イメージ止まり。本番の Falcon/スプラッシュ入りは kas を直接
合成する(`:` は YAML を左から右へマージ)。**先にキャッシュ変数を export**:

```bash
export DL_DIR=$PWD/downloads SSTATE_DIR=$PWD/sstate-cache

# 本番 (Tailscale SSH のみ) + eMMC A/B + Falcon + スプラッシュ
kas-container build \
  kas/imx8mm-prod.yml:kas/imx8mm-emmc-ab.yml:kas/imx8mm-falcon.yml:kas/imx8mm-splash.yml
```

> `DL_DIR`/`SSTATE_DIR` を export しないと `base.yml` の弱いデフォルトが
> コンテナ内 `TOPDIR=/build` を基準に解決され、bitbake が
> `Failed to create a file in SSTATE_DIR: Permission denied` で止まる。
> キャッシュは `build/` の兄弟に置いてあるので `rm -rf build` で消えない。

**オーバーレイの順序が適用順序**:`imx8mm-splash.yml` は必ず
`imx8mm-falcon.yml` の後ろに置く(splash パッチが falcon パッチの上に当たる)。

### kas 構成ファイル一覧

| ファイル | 種別 | 内容 |
|----------|------|------|
| `base.yml` | ベース | upstream repos, distro features, sstate |
| `imx8mm.yml` | マシン | `imx8mm-xpi` machine、meta-freescale、NXP EULA |
| `imx8mm-dev.yml` | 組み合わせ | base + imx8mm + debug-tweaks |
| `imx8mm-prod.yml` | 組み合わせ | base + imx8mm(debug-tweaks なし = Tailscale SSH のみ) |
| `imx8mm-emmc-ab.yml` | フラグメント | eMMC A/B WKS(`kart-imx8mm-emmc-ab.wks`) |
| `imx8mm-falcon.yml` | オーバーレイ | SPL 直カーネル起動(falcon.itb)。[08-falcon](docs/imx8mm-xpi-bringup/08-falcon.md) |
| `imx8mm-splash.yml` | オーバーレイ | SPL スプラッシュ + シームレス引き継ぎ。[11-splash](docs/imx8mm-xpi-bringup/11-splash-optimization.md) |
| `imx8mm-netboot.yml` | オーバーレイ | TFTP/NFS root(bring-up 用) |

アプリ(C++ 版 kart-machine-manager)は**常にイメージに含まれる**。レシピ
(`meta-kart/recipes-app/kart-machine-manager/`)が GitHub から `SRCREV` 固定で
取得しクロスビルドする。アプリ更新 = `SRCREV` を上げて再ビルド。

> **`.env`(秘密設定)はイメージに焼き込まれない。** `kmm.service` は
> `/data/kmm.env`(永続パーティション、OTA を跨ぐ)を読む。デバイスごとに 1 回
> 配置する:`scp .env root@<host>:/data/kmm.env`。よってイメージは Release に
> 公開してよい。

## ブートの仕組み

電源投入 → GUI 表示まで約 4.9 秒。リレーは
**BootROM → SPL(Falcon)→ ATF/BL31 → カーネル → systemd/weston/kmm**。
全段の図解・実測タイムライン・用語辞典は
[09-boot-sequence.md](docs/imx8mm-xpi-bringup/09-boot-sequence.md)。

要点:

- **Falcon Mode**:SPL が eMMC の `falcon.itb`(ATF+カーネル+DTB)を直接読んで
  カーネルへジャンプ。U-Boot proper は OTA 試行時と復旧時のみ登場
- **SPL スプラッシュ**:SPL が LCDIF/DSI/LT9611 を直接叩き、電源投入直後に
  ロゴを表示。カーネルへ暗転ゼロで引き継ぐ([11-splash](docs/imx8mm-xpi-bringup/11-splash-optimization.md))
- **A/B 冗長**は 2 層:
  - **rootfs/boot の A/B**:p2/p3=BOOTA/B、p5/p6=rootA/B、p7=data(共有)。
    OTA が非アクティブ面へ書き、`upgrade_available=1` で 1 回だけ試起動
  - **U-Boot(flash.bin)の A/B**:BootROM の SIT 機構で A 面 IVT 不正時に
    B 面へ自動フォールバック。`kart-uboot-*` ツールが管理
    ([04-pitfalls](docs/imx8mm-xpi-bringup/04-pitfalls.md) #19)

## 初回書き込み(新品ボード → 自立起動)

eMMC が空の新品は **UUU(SDP)** で書き込む。S1 を Serial Download にして
電源投入 → BootROM が USB SDP デバイス(`1fc9:0134`)として現れる → uuu で
書き込む。完全な手順書は
[06-emmc-flash.md](docs/imx8mm-xpi-bringup/06-emmc-flash.md)。

> **Falcon 版 flash.bin は UUU で RAM 起動できない**(SDPV ハンドシェイクを
> 受けない)。UUU 経路は常に stock 退避版 `local/recovery/flash.bin-stock`
> (`scripts/build-recovery-uboot.sh` で生成)を使い、`ums` で eMMC を露出して
> dd する。詳細は `imx8mm-xpi-bench` スキルと 06-emmc-flash。

bootloader(flash.bin)自体の更新は OTA では配れない(eMMC 33KiB 固定位置)。
稼働機では `kart-uboot-update <flash.bin>`(A=新版 / B=前版、header-last 書き込み、
電源断で ROM が前版へ自動フォールバック)を使う。

### 遠隔で SDP に入る(S1 を触れないとき)

S1 は物理スイッチだが、稼働中 Linux から A/B 両面の IVT セクタを意図的に
不正化して電源サイクルすると、S1=eMMC のまま ROM を SDP に落とせる
(実測済み)。手順・注意は `xpi-remote-sdp` スキル。

## OTA アップデート(A/B・SSH 経由)

稼働中のデバイスへ SSH(Tailscale 可)経由で OS ごと更新できる:

```bash
# imx8mm 用イメージを指定(スクリプトが PLATFORM=imx を自動判別)
IMAGE_DIR=build/tmp/deploy/images/imx8mm-xpi \
  ./scripts/ota-update.sh --host <tailscale-ip> \
  build/tmp/deploy/images/imx8mm-xpi/kart-image-imx8mm-xpi-emmc.wic.bz2
```

流れ:非アクティブ面へ書込み → `upgrade_available=1` で新面を **1 回だけ**試起動 →
ヘルス確認 → **commit で正式化**。新面が起動に失敗すれば U-Boot の `altbootcmd` が
旧面へ自動フォールバック(commit しない限り旧面のまま = 安全側)。

デバイス側コマンド:

```bash
kart-ab-status      # 現用スロットの確認
kart-ab-commit      # 試起動した面の手動 commit
kart-uboot-status   # U-Boot A/B の起動元・状態
```

## Cortex-M4 / CAN ゲートウェイ

MCP2515(ECSPI2)は **Cortex-M4 に譲渡**してあり、M4 上の CAN ゲートウェイ
ファーム(`can-gw`、Zephyr)が rpmsg でカーネルの candev ドライバ
(`kart-rpmsg-can`)と繋がり、通常の `can0`(SocketCAN)として見える。

- カーネルは `clk-imx8mm.mcore_booted=1`(machine conf)で M4 のルートクロックを維持
- M4 ファームは別リポジトリ `data-logger-imx8mm-cortex-m4`(Zephyr west workspace)
- ロード:`remoteproc` で ELF を start(`/sys/class/remoteproc/remoteproc0/`)
- 仕組み・掟(RDC/CCGR の 3 点セット、MU write × M4 read 衝突と NO_NOTIFY 回避)は
  [10-cortex-m4.md](docs/imx8mm-xpi-bringup/10-cortex-m4.md) と `learning/`

```bash
candump can0
cansend can0 123#DEADBEEF
```

## Tailscale について

**本番イメージでは Tailscale が唯一のリモートアクセス手段。**

Tailscale は WireGuard ベースの VPN。参加機器は tailnet 内の固定 IP(`100.x.y.z`)を
持ち、NAT/FW 越しに直接 SSH できる。

> ⚠️ **prod イメージの root パスワードはロックされている**(`imx8mm-prod.yml` は
> debug-tweaks を含まない)。**シリアルコンソールもログインには使えない**
> (起動ログの確認には有用)。入る手段は Tailscale SSH のみ。

### 自動接続の仕組み

初回起動時に auth key で自動参加する:

1. ブートパーティションに `tailscale.authkey` を置く(書き込み時に注入)
2. 起動時 `tailscale-autoconnect.service` がキーの存在を条件に起動
   (`ConditionPathExists`)
3. `tailscale up --authkey=... --ssh --accept-dns=false` を実行。`--ssh` で
   Tailscale SSH が有効になり、ローカルログイン手段が無くても入れる
4. 成功するとキーを削除(イメージに残さない)
5. 認証状態は `/data/tailscale` に永続化 — OTA でも再認証不要

auth key は [Tailscale 管理画面](https://login.tailscale.com/admin/settings/keys) で
発行(**再利用可能なキー推奨**)。tailnet の ACL が SSH を許可している必要あり。

> `--accept-dns=false`:MagicDNS を OS に適用しない。tailscaled が resolv.conf を
> 書き換えるパスが走らず、read-only rootfs での書き込み失敗が根絶される。
> 板から tailnet 名で他ノードを引く用途は無い(接続は常にこちらから IP 指定)。

## シリアル / ベンチ操作

udev 安定名を使う(ttyACM 番号は変動する。詳細は `xpi-serial-debug` スキル):

- `/dev/kart-a53-console` — A53/SPL/U-Boot コンソール(115200 8N1)
- `/dev/kart-m4-uart` — Cortex-M4 UART4 コンソール(J64)
- `/dev/kart-teensy-diag` — Teensy ブリッジ自己診断
- `/dev/kart-canable` — CANable(hcan0)

電源(DP100)・カメラでの画面目視検証・UUU/SDP・eMMC 書き込みは
`imx8mm-xpi-bench` スキルにまとまっている。

## アプリの更新

**正式**:kart-machine-manager を push → レシピの `SRCREV` を更新 → 再ビルド → OTA。

**開発イテレーション**(再ビルド不要):Qt6 SDK でクロスビルドしてバイナリだけ
差し替える。

```bash
source <SDK>/environment-setup-*   # SDK は release.sh が Release に同梱
cmake -B build-imx8mm kart-machine-manager/app-cpp && cmake --build build-imx8mm -j
ssh root@<host> 'mount -o remount,rw /'
scp build-imx8mm/kmm root@<host>:/usr/bin/kmm
ssh root@<host> 'mount -o remount,ro / ; systemctl restart kmm'
```

## プロジェクト構成

```
kmm-yocto/
├── kas/
│   ├── base.yml                  # 共通設定 (repos, distro features)
│   ├── imx8mm.yml                # imx8mm-xpi machine + meta-freescale + EULA
│   ├── imx8mm-dev.yml / -prod.yml
│   ├── imx8mm-emmc-ab.yml        # eMMC A/B WKS
│   ├── imx8mm-falcon.yml         # SPL 直カーネル起動
│   ├── imx8mm-splash.yml         # SPL スプラッシュ
│   ├── imx8mm-netboot.yml        # TFTP/NFS bring-up
│   └── rpi5*.yml / qemu*.yml     # 旧 RPi5 / QEMU 系
├── meta-kart/                    # 製品 BitBake レイヤ
│   ├── conf/machine/imx8mm-xpi.conf
│   ├── recipes-core/images/kart-image.bb
│   ├── recipes-bsp-imx/           # SPL/U-Boot パッチ、falcon.itb、SIT/env
│   ├── recipes-kernel-imx/        # 6.12 config、DTS、kart-rpmsg-can (candev)
│   ├── recipes-app/kart-machine-manager/   # C++/Qt6 GUI
│   ├── recipes-graphics/weston/   # kiosk 設定
│   ├── recipes-connectivity/tailscale/
│   ├── recipes-support/kart-ab-tools/       # A/B・U-Boot A/B 管理ツール
│   └── wic/kart-imx8mm-emmc-ab.wks
├── m4/                            # M4 ベアメタル雛形・診断 ELF (clk-test 等)
├── learning/                     # M4/ブート低レベル知識の教材
├── docs/imx8mm-xpi-bringup/      # bring-up 全記録(下記索引)
└── scripts/                      # build/flash/ota/release ヘルパー
```

## ドキュメント

XPI-iMX8MM の bring-up 全記録は [docs/imx8mm-xpi-bringup/](docs/imx8mm-xpi-bringup/README.md)。

| ファイル | 内容 |
|----------|------|
| 00-glossary | 用語集(初見はまずここ) |
| 01-hardware | ハードウェア実測(BSP/DTB 解析・ピン・ブートモード) |
| 02-debug-setup | デバッグ環境(UART ブリッジ・権限・UUU) |
| 03-boot-flow | ブート経路(SDP → 自作 U-Boot → netboot) |
| 04-pitfalls | 詰まった箇所と回避策(全部) |
| 06-emmc-flash | eMMC 初回書き込み手順書 |
| 08-falcon | Falcon Mode の設計・A/B 統合・実測 |
| 09-boot-sequence | ブートシーケンス完全解説(図解・初学者向け) |
| 10-cortex-m4 | Cortex-M4 の使い方(remoteproc・雛形・デバッグ) |
| 11-splash-optimization | スプラッシュ最適化(暗転ゼロ・実測 timing) |

低レベル概念(ARM ブート/特権レベル/ATF、RDC、rpmsg/MU、SPL)の教材は
[learning/](learning/README.md)。設計判断は
[docs/imx8mm-migration-design.md](docs/imx8mm-migration-design.md)。

## レイヤ構成

| レイヤ | ブランチ | 用途 |
|--------|----------|------|
| poky (meta, meta-poky) | scarthgap | Yocto コアレイヤ |
| meta-openembedded | scarthgap | 追加パッケージ |
| meta-freescale | scarthgap | i.MX8MM BSP(SPL/U-Boot/カーネル基盤・firmware-imx) |
| meta-qt6 | 6.x | Qt6 |
| meta-kart | local | 製品固有レシピ |

## ライセンス

meta-kart レイヤ内の独自コード: MIT。各 upstream レイヤは元のライセンスに従う。
Qt6 (qtbase/qtwayland): LGPL v3 / GPL — 製品配布時に確認が必要。
`imx-boot` の DDR トレーニング FW(firmware-imx)は **NXP EULA** 配布物
(`ACCEPT_FSL_EULA=1` で同意)。
