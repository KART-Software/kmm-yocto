# kmm-yocto — Yocto build (i.MX8M / XPI-iMX8MM · DEBIX-iMX8MP)

[English](README.md) | **日本語**

NXP i.MX8M 系 SBC 向けの組み込み Linux イメージを Yocto (scarthgap) + kas-container で
構築するプロジェクト。自作 SPL / U-Boot / カーネルを載せ、Wayland/Weston 上で C++/Qt6 の
キオスク GUI (`kmm`) を動かす。**Falcon Mode**(SPL 直カーネル)、**Cortex-M コプロセッサ
経由の CAN ゲートウェイ**、A/B OTA、SPL スプラッシュ、Tailscale、read-only rootfs 対応。

現行の製品ターゲットは 2 つの i.MX8M ボードで、設計(Falcon・M コア CAN・A/B OTA・
冗長 env・スプラッシュ・Tailscale)を共有する:

| | **XPI-iMX8MM** | **DEBIX Infinity (i.MX8MP)** ← 最新 |
|---|---|---|
| SoC | i.MX8M **Mini** Quad A53 @1.8GHz + **Cortex-M4** | i.MX8M **Plus** Quad Lite A53 + **Cortex-M7** |
| ボード | Geniatech XPI-iMX8MM (RPi 互換フォームファクタ) | Polyhex DEBIX Infinity (EMB-IMX8MP-06) |
| RAM | 2GB LPDDR4(実測、スペック表 1GB より上位) | 4GB LPDDR4(falcon /memory は 3GB+1GB) |
| 表示 | MIPI-DSI → **LT9611** → HDMI | **lcdif3 → Samsung HDMI PHY**、TFP401 LCD は EDID FW 供給 |
| CAN | **MCP2515**(ECSPI2)を M4 が所有 → rpmsg | **FlexCAN1** を M7 が所有 → rpmsg |
| カーネル | linux-fslc **6.12**(mainline 系) | linux-fslc-imx **6.6**(NXP BSP 系) |
| BSP | u-boot-fslc + mainline ATF | u-boot-imx + imx-atf(`IMX_DEFAULT_BSP=nxp`) |
| U-Boot A/B | ROM **SIT** 表フォールバック | ROM **fuse** 既定オフセット(4MiB)フォールバック |
| env | 単一コピー | **2 面冗長**(`CONFIG_SYS_REDUNDAND_ENVIRONMENT`) |
| 電源→GUI | ≈4.9s | **≈2.93s**(σ0.04) |
| ブートモード切替 | 物理 DIP **S1**(eMMC / Serial) | DIP を **USB リレー**で遠隔切替(`debix-boot-switch` スキル) |
| bring-up 記録 | [docs/imx8mm-xpi-bringup/](docs/imx8mm-xpi-bringup/) | [docs/imx8mp-debix-bringup/](docs/imx8mp-debix-bringup/) |
| ハード構成図 | [hardware.png](docs/imx8mm-xpi-bringup/hardware.png) | [hardware.png](docs/imx8mp-debix-bringup/hardware.png) |

> **前身は Raspberry Pi 5。** RPi5 のビルド系(`kas/rpi5*.yml`・EEPROM/NVMe 手順)は
> 残しているが製品ターゲットからは外れている。完全な当時の状態はタグ
> [`rpi5-final`](https://github.com/KART-Software/kmm-yocto/tree/rpi5-final)、
> ドキュメントは [docs/archive/](docs/archive/) を参照。

共通の設計思想:

| 項目 | 内容 |
|------|------|
| Yocto | scarthgap (5.0)、kas-container (Docker) で構築 |
| ブート | **Falcon Mode**(SPL が `falcon.itb` = ATF+カーネル+DTB を直接起動、U-Boot proper を飛ばす)+ SPL スプラッシュ(暗転ゼロ引き継ぎ)|
| デッドマン | falcon は `boot_os=yes` の時だけ発動、SPL が発動時に `no` へ書き戻す → クラッシュ/電源断で次回は自動 proper。Linux 側 `falcon-rearm.service` が `yes` を補充 |
| CAN | CAN コントローラを **Cortex-M(M4/M7)に譲渡**し、M コアのファーム(`main-app`、Zephyr)の CAN の中継が rpmsg で `rpmsg-can` カーネルモジュールと繋がり **`rpmsgcan0`**(SocketCAN)を生やす |
| A/B OTA | Linux・M コアのファーム・SPL がそれぞれ独立した A/B を持ち、`ab` コマンド一つで扱う。Linux は SSH(Tailscale 可)経由で非アクティブ面へ書込 → 1 回試起動 → commit。試起動に失敗すると SPL(8MP)または U-Boot(8MM)が旧面へ戻す |
| GUI | Wayland + Weston 13(poky、kiosk)+ C++/Qt6 Widgets(`kmm`)。8MP は GPU 不使用(pixman 合成)|
| init / ネット | systemd / systemd-networkd、read-only rootfs(永続は `/data`)|
| リモート | Tailscale SSH(prod では唯一の手段)|

---

## ハードウェア

### DEBIX Infinity (i.MX8MP) — 最新ターゲット

| 項目 | 値 | 備考 |
|------|-----|------|
| SoC | i.MX8M Plus **Quad Lite** A53 + Cortex-M7 | VPU/NPU はヒューズアウト、DTS で無効化 |
| RAM | 4GB LPDDR4(Micron MT53E1G32D2NP) | 自作 timing 表(Model A 3732MTS + 16Gb ダイ密度移植) |
| eMMC | `/dev/mmcblk2` | A/B: imx-boot A=32KiB / B=4MiB、env 7MiB、BOOTA/B(p1/p2)・MCORE(p3、M コアのファームの A/B)・rootA/B(p5/p6)・data(p7) |
| 表示 | HDMI(lcdif3 → Samsung HDMI PHY → DW-HDMI) | TFP401 LCD(800x480@33.75MHz)は EDID FW 供給 + `drm.edid_firmware` |
| CAN | FlexCAN1 を M7 が所有 → `rpmsgcan0`。FlexCAN2 = `can0`(未使用予備) | J2 Pin31/33 → 絶縁トランシーバ |
| ブートモード | DIP(001=UUU / 010=eMMC / 011=SD) | bit2/bit3 を USB リレーで遠隔駆動(`debix-boot-switch`)|

一次情報・EVK との DTS 差分は
[02-dts-delta.md](docs/imx8mp-debix-bringup/02-dts-delta.md)、初回起動の U-Boot 修正
(DDR/HDMI/USB)は [03-first-boot.md](docs/imx8mp-debix-bringup/03-first-boot.md)。
ベンチ機材(DP100 電源・USB リレー・シリアル・カメラ検証)は
`debix-boot-switch` / `lcd-validation` スキル。

### XPI-iMX8MM

| 項目 | 値 | 備考 |
|------|-----|------|
| SoC | i.MX8M Mini Quad A53 @1.8GHz + Cortex-M4 | |
| RAM | 2GB LPDDR4 | 実機実測(スペック表 1GB ではなく上位構成) |
| eMMC | Samsung 8GB (`8GTF4R`)、HS400 ES | `/dev/mmcblk2` |
| 表示 | MIPI-DSI → LT9611(I2C4 @0x3b)→ HDMI | EVK の ADV7535 とは別チップ |
| CAN | MCP2515(ECSPI2)を M4 が所有 | 40 ピンヘッダ経由 |
| ブートモード | 物理 DIP **S1**(eMMC / Serial Download) | ソフトからは変えられない(`xpi-remote-sdp` で回避可)|

実機の一次情報は [docs/imx8mm-xpi-bringup/01-hardware.md](docs/imx8mm-xpi-bringup/01-hardware.md)、
ベンチ操作は `imx8mm-xpi-bench` / `xpi-serial-debug` スキル。

---

## 使い始める

作業の順の手順書は [docs/usage/](docs/usage/README.md) にある:

| 段階 | 手順書 |
|---|---|
| PC の用意とイメージのビルド | [01-build.md](docs/usage/01-build.md) |
| 新しい機体の eMMC への最初の書き込み | [02-first-flash.md](docs/usage/02-first-flash.md) |
| 機体ごとの初期設定(`kmm.env`・M コアのファーム・Tailscale) | [03-provisioning.md](docs/usage/03-provisioning.md) |
| Linux・M コアのファーム・SPL の A/B 更新 | [04-ab-updates.md](docs/usage/04-ab-updates.md) |
| アプリ(`kmm`)の更新と手元での試し方 | [05-app.md](docs/usage/05-app.md) |
| M コアのファームを試す・入れる | [06-mcore-firmware.md](docs/usage/06-mcore-firmware.md) |
| ベンチ操作(電源・ブートモード・シリアル・カメラ) | [07-bench.md](docs/usage/07-bench.md) |
| 起動しない・おかしいとき | [08-recovery.md](docs/usage/08-recovery.md) |

DEBIX の製品構成をビルドし、動いている機体を更新する流れはこうなる(キャッシュの場所を先に
export しないと bitbake がキャッシュに書けない):

```bash
export DL_DIR=$PWD/downloads SSTATE_DIR=$PWD/sstate-cache
kas-container build \
  kas/imx8mp-dev.yml:kas/imx-emmc-ab.yml:kas/imx8mp-falcon.yml:kas/imx8mp-splash.yml:kas/imx8mp-m7.yml
./scripts/ab.sh --host <機体> linux try build/tmp/deploy/images/imx8mp-debix/kart-image-imx8mp-debix-emmc.wic.bz2
./scripts/ab.sh --host <機体> linux commit
```

- **リモートからの入り方**: prod イメージは Tailscale SSH だけ(root のパスワードがロック
  されている)。開発用イメージ(debug-tweaks)は root のパスワードが空で、LAN の SSH でも入れる。
  シリアルコンソールは prod も含めて全イメージで root に自動ログインする(基板に物理的に触れる人は
  root とみなす設計判断)
- **秘密の設定はイメージに入れない**: `kmm.service` は永続領域の `/data/kmm.env` を読む
  (更新しても消えない)。機体ごとに一度置く
- **8MP にはまだ prod 構成が無い**: ベンチは開発用の構成(debug-tweaks)で動いている

---

## ブートの仕組み(Falcon Mode)

リレーは **BootROM → SPL(Falcon)→ ATF/BL31(+ M コア起動)→ カーネル →
systemd/weston/kmm**。U-Boot proper が出てくるのは復旧のとき(デッドマンの落ち先、
`falcon.itb` を読めない面)だけ。8MP は OTA の試起動も falcon 経路で、8MM(旧 SPL)は
試起動が U-Boot proper を通る。

- **Falcon Mode**:SPL が eMMC の FAT から `falcon.itb`(ATF+カーネル+DTB)を直接読んで
  ジャンプ。8MP では BL31 が M7 を起動してから A53 カーネルへ入る
- **SPL スプラッシュ**:SPL が表示チェーンを直接叩いてロゴを出し、カーネルへ暗転ゼロで
  引き継ぐ([06-splash.md](docs/imx8mp-debix-bringup/06-splash.md))
- **デッドマン**:falcon は `boot_os=yes` の時だけ発動し、SPL が発動時に `no` へ
  書き戻す。Linux 側 `falcon-rearm.service` が起動できた実績をもって `yes` を補充
  (seed 直後に前倒しし、デッドマン窓 ≈2.05s)。クラッシュ/デッドマン窓中の電源断は
  次回 proper で自動回復
- **A/B は独立した 3 組**で、どれも `ab` コマンドで扱う([04-ab-updates.md](docs/usage/04-ab-updates.md)):
  - **Linux**:BOOTA/B(p1/p2)・rootA/B(p5/p6)・data(p7、共有)。更新は非アクティブ面へ
    書き `upgrade_available=1` で 1 回試起動。8MP は SPL が env で面を選び、試行回数も数える
  - **M コアのファーム(8MP)**:p3(MCORE)の `mcore-a.img` / `mcore-b.img`。Linux とは独立
  - **SPL(imx-boot)**:パーティション外の A/B コピー。BootROM は A 面の IVT が不正なときだけ
    B 面を起動する(8MM=SIT 表、8MP=fuse 既定オフセット)。`ab spl` で管理
- **冗長 env(8MP)**:env を 2 面(0x700000 / 0x704000)持ち、保存は常に未使用面へ
  書く。デッドマン書き込み中の電源断でも他面が残り A/B 状態は無傷
  ([open-issues #13](docs/imx8mp-debix-bringup/open-issues.md))

DEBIX の電源→GUI は約 **2.93s**(σ0.04、N=10)。段別内訳・最適化の全記録は
[30-boot-time.md](docs/imx8mp-debix-bringup/30-boot-time.md)。XPI は約 4.9s
([09-boot-sequence.md](docs/imx8mm-xpi-bringup/09-boot-sequence.md))。

---

## Cortex-M CAN ゲートウェイ

CAN コントローラは **Cortex-M コプロセッサに譲渡**してある。M コアのファーム(`main-app`、
Zephyr)の CAN の中継が rpmsg でカーネルの `rpmsg-can` モジュールと繋がり、
netdev **`rpmsgcan0`**(通常の SocketCAN)を生やす。

- 8MM = **M4** が MCP2515(ECSPI2)を、8MP = **M7** が FlexCAN1 を所有
- M ファームは別リポジトリ
  [data-logger-zephyr](https://github.com/KART-Software/data-logger-zephyr)
  (`apps/main-app`、SoC ガードで 8MM/8MP を分岐)。土台(rpmsg、キープアライブ)と機能(CAN の中継)に
  ファイルが分かれている。前の `apps/can-gw` は CAN の中継だけを持っていた
- **キープアライブ**:M コアが rpmsg のチャネル `mcore-keepalive` で 1 秒ごとに知らせ、カーネル
  モジュール `mcore-keepalive` が `/sys/bus/rpmsg/devices/*.mcore-keepalive.*/state` に出す。途切れた
  ときと戻ったときはカーネルのログに出る。`ab mcore update` は、これが届き続けるときだけ確定する
- **falcon 統合**:SPL が M コアのファームを検証 → DDR ステージング、BL31 が M コアの
  ルートクロック起動 + ITCM 配置 + 起動。Linux は稼働中の M コアに `remoteproc` で attach
- **M コアのファームは Linux とは独立した A/B**(8MP):p3 に `mcore-a.img` /
  `mcore-b.img` を置き、env の `mcore_slot` / `mcore_try` で選ぶ。`ab mcore update` で
  手で置く。Linux のイメージには入れないので、Linux を更新しても
  M コアは変わらない。書いたばかりの eMMC には無く、無くても Linux は正常に動く。
  XPI(8MM)はまだ boot パーティションの `m4-fw.img` を読む(SPL の A/B 化が未対応)
- 新しいファームを試す(再起動で戻る)・入れるには、data-logger-zephyr の
  `scripts/try.sh` / `scripts/install.sh` を使う([06-mcore-firmware.md](docs/usage/06-mcore-firmware.md))
- kmm は `/data/kmm.env` の `CAN_INTERFACE=rpmsgcan0` で読む IF を選ぶ
- 仕組み・掟(クロックルート・RDC/CCGR・MU の read/ACK)は
  [01-m7.md](docs/imx8mp-debix-bringup/01-m7.md)(8MP)/
  [10-cortex-m4.md](docs/imx8mm-xpi-bringup/10-cortex-m4.md)(8MM)と `learning/`

```bash
candump rpmsgcan0
cansend rpmsgcan0 123#DEADBEEF
```

---

## プロジェクト構成

```
kmm-yocto/
├── kas/                          # ビルド合成 (フラグメントを : でマージ)
│   ├── base.yml                  # 共通 (repos, distro features, DL/SSTATE)
│   ├── imx8mp.yml / imx8mm.yml   # machine + meta-freescale + EULA
│   ├── imx8mp-dev.yml            # 8MP 開発イメージ
│   ├── imx8mm-dev.yml / -prod.yml
│   ├── imx-emmc-ab.yml           # 8MM/8MP 共通 eMMC A/B WKS 選択
│   ├── imx8m{p,m}-falcon.yml     # SPL 直カーネル起動
│   ├── imx8m{p,m}-splash.yml     # SPL スプラッシュ
│   ├── imx8mp-m7.yml / imx8mm-m4.yml   # M コア CAN ゲートウェイ + falcon 統合
│   └── rpi5*.yml / boot-*.yml / qemu*.yml / sdk.yml   # 旧 RPi5 / QEMU / SDK
├── meta-kart/                    # 製品 BitBake レイヤ
│   ├── conf/machine/             # imx8mp-debix.conf, imx8mm-xpi.conf
│   ├── recipes-core/images/kart-image.bb
│   ├── recipes-bsp-imx/          # SPL/U-Boot/ATF パッチ、falcon-itb、env、ab-tools 連携
│   ├── recipes-kernel-imx/       # カーネル config・DTS・rpmsg-can (candev)
│   ├── recipes-app/kmm/          # C++/Qt6 GUI (kmm_2.0.bb)
│   ├── recipes-graphics/weston/  # kiosk 設定 (weston 13)
│   ├── recipes-connectivity/tailscale/
│   ├── recipes-support/ab-tools/ # ab コマンド(Linux・M コア・SPL の A/B)、fw_env.config
│   └── wic/                      # imx8mp-emmc-ab.wks, imx8mm-emmc-ab.wks, rpi5*.wks
├── m4/                           # M4 ベアメタル雛形・診断 ELF (clk-test 等)
├── learning/                     # M コア/ブート低レベル知識の教材
├── docs/                         # 使い方の手順書と bring-up 記録 (下記)
└── scripts/                      # build・flash・A/B(ab.sh)ヘルパー
```

---

## ドキュメント

### 使い方 — [docs/usage/](docs/usage/README.md)

ビルド、最初の書き込み、機体ごとの初期設定、A/B 更新、アプリと M コアのファームの更新、
ベンチ操作、復旧(上の「使い始める」)。

### DEBIX (i.MX8MP) — [docs/imx8mp-debix-bringup/](docs/imx8mp-debix-bringup/)

| ファイル | 内容 |
|----------|------|
| 00-plan | 移行計画と実測ログ(工場イメージ確認 → machine 正式化)|
| 01-m7 | Cortex-M7 の起動・can-gw・falcon 統合(CAN1 root クロック等)|
| 02-dts-delta | EVK との DTS 差分 |
| 03-first-boot | 初回起動の U-Boot 修正(DDR 4GB・HDMI・USB)|
| 04-falcon | Falcon mode・デッドマン・落ち先 proper・電源断スイープ・A/B とスロット選択 |
| 06-splash | SPL スプラッシュ・暗ブートの真因と修正(weston 13)|
| 07-emmc-boot-rom | eMMC boot ROM / fast boot 化の調査(保留)|
| 08-dark-boot | 暗ブート調査の経緯 |
| 30-boot-time | 起動時間短縮の継続記録(電源→GUI 2.93s)|
| open-issues | 未解決事項・実機の暫定状態 |

### XPI (i.MX8MM) — [docs/imx8mm-xpi-bringup/](docs/imx8mm-xpi-bringup/)

01-hardware / 02-debug-setup / 03-boot-flow / 04-pitfalls / 06-emmc-flash /
08-falcon / 09-boot-sequence / 10-cortex-m4 / 11-splash-optimization。

低レベル概念(ARM ブート/特権レベル/ATF、RDC、rpmsg/MU、SPL)の教材は
[learning/](learning/README.md)。移行の設計判断は
[docs/imx8mm-migration-design.md](docs/imx8mm-migration-design.md)。RPi5 時代は
[docs/archive/](docs/archive/)。

---

## レイヤ構成

| レイヤ | ブランチ | 用途 |
|--------|----------|------|
| poky (meta, meta-poky) | scarthgap | Yocto コアレイヤ |
| meta-openembedded | scarthgap | 追加パッケージ |
| meta-freescale | scarthgap | i.MX BSP(SPL/U-Boot/カーネル基盤・firmware-imx)|
| meta-qt6 | 6.x | Qt6 |
| meta-kart | local | 製品固有レシピ |

---

## ライセンス

このリポジトリは [PolyForm Noncommercial License 1.0.0](LICENSE) に、学生フォーミュラ
チームと教育向けの[追加許可](ADDITIONAL-PERMISSION.md)を加えた条件で公開しています。

Copyright 2026 Ryomei Osaki

使ってよい例:

- 個人の趣味、大学などでの研究、授業や勉強会などの教育
- 学生フォーミュラチームでの利用と改変、ほかの学生フォーミュラチームとの改変版の共有。
  スポンサーや賞金の有無は問いません

使えない例:

- 製品やサービスへの組み込みなど、商用目的で使うこと
- 商用目的で改変すること、改変したものを商用目的で使うこと
- スポンサー企業などが、自社の事業のために使うこと

この要約は説明のためのものです。条件は [LICENSE](LICENSE) と
[ADDITIONAL-PERMISSION.md](ADDITIONAL-PERMISSION.md) の本文が優先します。

### ほかのライセンスのファイル

次のファイルは上のライセンスの対象外で、元のライセンスのままです。

- `meta-kart/recipes-bsp-imx/u-boot/files/` の U-Boot のパッチ(`*.patch`)と
  `debix-lpddr4_timing.c`: GPL-2.0-or-later。`debix-lpddr4_timing.c` は Copyright NXP
- `meta-kart/recipes-kernel-imx/linux/files/` の Linux カーネルのパッチと DTS:
  GPL-2.0、または各ファイルに記載のライセンス
- `meta-kart/recipes-kernel-imx/rpmsg-can/` と `meta-kart/recipes-kernel-imx/mcore-keepalive/` のカーネルモジュール: GPL-2.0-only
- `meta-kart/recipes-bsp-imx/imx-atf/files/` の Arm Trusted Firmware のパッチ: BSD-3-Clause
- `meta-kart/recipes-graphics/weston/files/` の Weston のパッチ、`weston.service`、
  `weston-early.service`: Weston と poky の weston-init 由来のため MIT
- `meta-kart/recipes-graphics/seatd/files/seatd.service`: seatd のユニット由来のため MIT
- `meta-kart/recipes-connectivity/tailscale/files/tailscaled.service`:
  Tailscale のユニット由来のため BSD-3-Clause
- `meta-kart/recipes-support/udev-slim/files/systemd-random-seed.service`:
  systemd のユニット由来のため LGPL-2.1-or-later
- `m4/*/rpmsg_config.h`: BSD-3-Clause。Copyright Mentor Graphics、Xilinx、Freescale、NXP
- `meta-kart/recipes-bsp-imx/falcon-itb/files/` の `m4-fw.bin` と `m7-fw.bin`:
  data-logger-zephyr からビルドしたファームウェアで、Zephyr(Apache-2.0)と
  NXP HAL(BSD-3-Clause)のコードを含みます
- `logo/` と `meta-kart/recipes-bsp-imx/u-boot/files/spl_splash_logo.h` のチームロゴ:
  KART の所有物で、このライセンスの対象外です。利用にはチームの許可が必要です

kas がこのリポジトリの隣に取得する upstream レイヤ(poky、meta-openembedded、meta-qt6、
BSP レイヤ)は、それぞれのライセンスに従います。

ビルドしたイメージには、それぞれのライセンスに従う第三者のソフトウェアが含まれます。
Qt6(qtbase と qtwayland)などの GPL・LGPL のコンポーネントや、**NXP EULA** で配布される
`imx-boot` の DDR トレーニング FW(firmware-imx、`ACCEPT_FSL_EULA=1` で同意)です。
一覧はビルド時に `build/tmp/deploy/licenses/` に出力されます。
