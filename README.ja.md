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
| CAN | CAN コントローラを **Cortex-M(M4/M7)に譲渡**し、M 上の `can-gw`(Zephyr)が rpmsg で `rpmsg-can` カーネルモジュールと繋がり **`rpmsgcan0`**(SocketCAN)を生やす |
| A/B OTA | SSH(Tailscale 可)経由で非アクティブ面へ書込 → 1 回試起動 → commit。失敗時は U-Boot が旧面へ自動フォールバック |
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
| eMMC | `/dev/mmcblk2` | A/B: imx-boot A=32KiB / B=4MiB、env 7MiB、BOOTA/B・rootA/B・data |
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

## 前提条件

- **Ubuntu 22.04 以降**(WSL2 含む)、Docker、kas-container
- 十分なディスク容量(初回ビルドで 50GB 以上推奨)
- 実機書き込みに **NXP `uuu`**(mfgtools)。SDP 経由の初回書き込み・ブートローダ復旧で使う
- **NXP EULA への同意**が必要(`imx-boot` の DDR トレーニング FW = firmware-imx が
  EULA 配布)。`kas/imx8mm.yml` / `kas/imx8mp.yml` で `ACCEPT_FSL_EULA = "1"` 設定済み

```bash
sudo apt install -y docker.io e2fsprogs uuu    # uuu は apt か mfgtools リリース
pipx install kas                               # または: uv tool install kas
sudo usermod -aG docker,dialout,plugdev $USER  # 要 再ログイン
```

---

## ビルド

### build.sh(開発イメージ)

```bash
./scripts/build.sh imx8mp --emmc            # DEBIX (i.MX8MP) 開発イメージ, eMMC A/B ← 最新
./scripts/build.sh imx8mp --emmc --falcon   # DEBIX 製品ブート: Falcon + SPL スプラッシュ (M7 なし)
./scripts/build.sh imx8mp                    # DEBIX シングルスロット (SD 持ち込み用)
./scripts/build.sh imx8mm --emmc            # XPI-iMX8MM eMMC A/B
./scripts/build.sh imx8mm --emmc --falcon   # XPI 製品ブート: Falcon + スプラッシュ (M4 なし)
./scripts/build.sh imx8mm --netboot         # XPI TFTP/NFS netboot (DTS/ドライバ試行)
./scripts/build.sh imx8mm                    # XPI 素の EVK SD 持ち込み (シングルスロット)
```

`imx8mm`/`imx8mp` は開発イメージ(debug-tweaks 入り)。`--emmc` で eMMC A/B の WKS に
なる(付けないと machine 既定のシングルスロット)。`--falcon` で Falcon Mode + SPL
スプラッシュ(製品ブート経路)が乗り、**fresh clone から1コマンド**で起動可能な製品
イメージが作れる。Cortex-M CAN ゲートウェイ(M7/M4)は別オーバーレイ(下記)。

> **レイヤは再現性のためにピン固定。** `kas/imx8mp-dev.lock.yml` /
> `kas/imx8mm-dev.lock.yml` が poky / meta-openembedded / meta-qt6 /
> meta-freescale を exact commit に固定する。kas は対応 config の隣にある lock を
> 自動適用するので、fresh clone でも検証済みと同じツリーがビルドされる。
> 意図的に更新するときの再ピン: `kas-container dump --lock --update <composition>
> > /tmp/x && mv /tmp/x kas/<config>.lock.yml`(出力名が kas の自動読込 lock と
> 衝突しないよう一旦別名で書く)。

### Cortex-M オーバーレイ + フル手動合成(kas 直実行)

`build.sh --falcon` で Falcon + スプラッシュはカバー済み。Cortex-M CAN ゲートウェイ
(`rpmsgcan0`)は**別オーバーレイ**として残す。フルスタックは kas を直接合成する
(`:` は YAML を左から右へマージ、**オーバーレイの順序 = 適用順序**)。
**先にキャッシュ変数を export**:

```bash
export DL_DIR=$PWD/downloads SSTATE_DIR=$PWD/sstate-cache

# DEBIX (8MP): dev + eMMC A/B + Falcon + スプラッシュ + M7 CAN
kas-container build \
  kas/imx8mp-dev.yml:kas/imx-emmc-ab.yml:kas/imx8mp-falcon.yml:kas/imx8mp-splash.yml:kas/imx8mp-m7.yml

# XPI (8MM) 本番 (Tailscale SSH のみ、debug-tweaks なし) + eMMC A/B + Falcon + スプラッシュ + M4 CAN
kas-container build \
  kas/imx8mm-prod.yml:kas/imx8mm-emmc-ab.yml:kas/imx8mm-falcon.yml:kas/imx8mm-splash.yml:kas/imx8mm-m4.yml
```

> `DL_DIR`/`SSTATE_DIR` を export しないと `base.yml` の弱いデフォルトが
> コンテナ内 `TOPDIR=/build` を基準に解決され、bitbake が
> `Failed to create a file in SSTATE_DIR: Permission denied` で止まる。
> キャッシュは `build/` の兄弟に置いてあるので `rm -rf build` で消えない。
> (kas 5.x はプロジェクト内の DL_DIR を `/work/downloads` として転送する。)

> **8MP には `imx8mm-prod.yml` に相当する prod 版がまだ無い。** ベンチは
> `imx8mp-dev.yml`(debug-tweaks)ベースで運用している。製品出荷向けの
> debug-tweaks オフ変種を起こすのは今後の課題。

成果物は `build/tmp/deploy/images/{imx8mp-debix,imx8mm-xpi}/*.wic.bz2`。

### kas 構成ファイル一覧

| ファイル | 種別 | 内容 |
|----------|------|------|
| `base.yml` | ベース | upstream repos, distro features, DL/SSTATE, rm_work |
| `imx8mp.yml` / `imx8mm.yml` | マシン | machine + meta-freescale + NXP EULA |
| `imx8mp-dev.yml` | 組み合わせ | base + imx8mp + debug-tweaks |
| `imx8mm-dev.yml` / `imx8mm-prod.yml` | 組み合わせ | base + imx8mm(prod は debug-tweaks なし)|
| `imx-emmc-ab.yml` | フラグメント | **8MM/8MP 共通**の eMMC A/B WKS 選択(実体は machine の `EMMC_AB_WKS`)|
| `imx8mm-emmc-ab.yml` | フラグメント | 8MM 専用の旧 A/B WKS |
| `imx8mp-falcon.yml` / `imx8mm-falcon.yml` | オーバーレイ | SPL 直カーネル起動(`falcon.itb`)|
| `imx8mp-splash.yml` / `imx8mm-splash.yml` | オーバーレイ | SPL スプラッシュ + シームレス引き継ぎ(**falcon の後に置く**)|
| `imx8mp-m7.yml` / `imx8mm-m4.yml` | オーバーレイ | M コア CAN ゲートウェイ(`rpmsgcan0`)+ falcon 統合(BL31 が M コア起動)|
| `imx8mm-netboot.yml` | オーバーレイ | TFTP/NFS root(bring-up 用)|
| `rpi5*.yml` / `boot-*.yml` / `qemu*.yml` / `sdk.yml` | 旧/補助 | RPi5・QEMU・Qt SDK |

アプリ(C++ 版 kart-machine-manager)は**常にイメージに含まれる**。レシピ
(`meta-kart/recipes-app/kmm/kmm_2.0.bb`)が GitHub から `SRCREV` 固定で取得し
クロスビルドする。アプリ更新 = `SRCREV` を上げて再ビルド。

> **`.env`(秘密設定)はイメージに焼き込まれない。** `kmm.service` は
> `/data/kmm.env`(永続パーティション、OTA を跨ぐ)を読む。デバイスごとに 1 回
> 配置する:`scp .env root@<host>:/data/kmm.env`。よってイメージは Release に
> 公開してよい。M コア構成では `CAN_INTERFACE=rpmsgcan0` を含める。

---

## ブートの仕組み(Falcon Mode)

リレーは **BootROM → SPL(Falcon)→ ATF/BL31(+ M コア起動)→ カーネル →
systemd/weston/kmm**。U-Boot proper は OTA 試行時と復旧時のみ登場する。

- **Falcon Mode**:SPL が eMMC の FAT から `falcon.itb`(ATF+カーネル+DTB)を直接読んで
  ジャンプ。8MP では BL31 が M7 を起動してから A53 カーネルへ入る
- **SPL スプラッシュ**:SPL が表示チェーンを直接叩いてロゴを出し、カーネルへ暗転ゼロで
  引き継ぐ([06-splash.md](docs/imx8mp-debix-bringup/06-splash.md))
- **デッドマン**:falcon は `boot_os=yes` の時だけ発動し、SPL が発動時に `no` へ
  書き戻す。Linux 側 `falcon-rearm.service` が起動できた実績をもって `yes` を補充
  (seed 直後に前倒しし、デッドマン窓 ≈2.05s)。クラッシュ/デッドマン窓中の電源断は
  次回 proper で自動回復
- **A/B は 2 層**:
  - **rootfs/boot の A/B**:BOOTA/B(p1/p2)・rootA/B(p5/p6)・data(p7、共有)。
    OTA が非アクティブ面へ書き `upgrade_available=1` で 1 回試起動
  - **U-Boot(imx-boot)の A/B**:BootROM が A 面 IVT 不正時に B 面へ自動フォールバック
    (8MM=SIT 表、8MP=fuse 既定オフセット)。`uboot-*` ツールが管理
- **冗長 env(8MP)**:env を 2 面(0x700000 / 0x704000)持ち、保存は常に未使用面へ
  書く。デッドマン書き込み中の電源断でも他面が残り A/B 状態は無傷
  ([open-issues #13](docs/imx8mp-debix-bringup/open-issues.md))

DEBIX の電源→GUI は約 **2.93s**(σ0.04、N=10)。段別内訳・最適化の全記録は
[30-boot-time.md](docs/imx8mp-debix-bringup/30-boot-time.md)。XPI は約 4.9s
([09-boot-sequence.md](docs/imx8mm-xpi-bringup/09-boot-sequence.md))。

---

## Cortex-M CAN ゲートウェイ

CAN コントローラは **Cortex-M コプロセッサに譲渡**してある。M 上の CAN ゲートウェイ
ファーム(`can-gw`、Zephyr)が rpmsg でカーネルの `rpmsg-can` モジュールと繋がり、
netdev **`rpmsgcan0`**(通常の SocketCAN)を生やす。

- 8MM = **M4** が MCP2515(ECSPI2)を、8MP = **M7** が FlexCAN1 を所有
- M ファームは別リポジトリ
  [data-logger-zephyr](https://github.com/KART-Software/data-logger-zephyr)
  (`apps/can-gw`、SoC ガードで 8MM/8MP を分岐)
- **falcon 統合**:`m7-fw.img`(8MP)/`m4-fw.img`(8MM)を boot パーティションに置き、
  SPL が検証 → DDR ステージング、BL31 が M コアのルートクロック起動 + ITCM 配置 +
  起動。Linux は稼働中の M コアに `remoteproc` で attach
- 開発イテレーションは `/lib/firmware` に ELF を置いて
  `/sys/class/remoteproc/remoteproc0` から start(稼働中は stop → start で差替)
- kmm は `/data/kmm.env` の `CAN_INTERFACE=rpmsgcan0` で読む IF を選ぶ
- 仕組み・掟(クロックルート・RDC/CCGR・MU の read/ACK)は
  [01-m7.md](docs/imx8mp-debix-bringup/01-m7.md)(8MP)/
  [10-cortex-m4.md](docs/imx8mm-xpi-bringup/10-cortex-m4.md)(8MM)と `learning/`

```bash
candump rpmsgcan0
cansend rpmsgcan0 123#DEADBEEF
```

---

## 初回書き込み(新品ボード → 自立起動)

### DEBIX (8MP)

DIP を **USB リレーで切替**できる(`debix-boot-switch` スキルの `bootsel.py`)。
`uuu`(DIP=001)でブートローダ + パーティションを書くか、`sd`(DIP=011)の U-Boot から
eMMC へ流す。手順は [fastboot-runbook.md](docs/imx8mp-debix-bringup/fastboot-runbook.md)
と `debix-boot-switch` スキル。

```bash
S=.claude/skills/debix-boot-switch/bootsel.py
python3 $S uuu && python3 scripts/dp100.py cycle --off-time 3   # SDP に落として uuu
python3 $S emmc && python3 scripts/dp100.py cycle               # 通常起動に戻す
```

### XPI (8MM)

物理 DIP **S1** を Serial Download にして電源投入 → BootROM が USB SDP デバイスとして
現れる → `uuu` で書く。手順書は
[06-emmc-flash.md](docs/imx8mm-xpi-bringup/06-emmc-flash.md)。S1 を触れないときは
稼働中 Linux から A/B IVT を意図的に不正化して SDP に落とす(`xpi-remote-sdp` スキル)。

> **Falcon 版 imx-boot は UUU で RAM 起動できない**(SDPV ハンドシェイクを受けない)。
> UUU 経路は stock 退避版 imx-boot を使い `ums` で eMMC を露出して dd する。

### ブートローダ(imx-boot)の更新

OTA では配れない(eMMC 固定位置)。稼働機では `uboot-update <flash.bin>`
(A=新版 / B=前版、read-back 照合、電源断で ROM が前版へ自動フォールバック)を使う。

---

## OTA アップデート(A/B・SSH 経由)

稼働中のデバイスへ SSH(Tailscale 可)経由で OS ごと更新できる。`ota-update.sh` は
イメージのパーティション構成とデバイスの `ab-status` からプラットフォームを自動判別する:

```bash
./scripts/ota-update.sh --host <host> --yes \
  build/tmp/deploy/images/imx8mp-debix/kart-image-imx8mp-debix-emmc.wic.bz2
```

流れ:非アクティブ面へ書込み(rootfs=dd、boot=ファイルコピー)→ `upgrade_available=1` で
**1 回だけ**試起動 → ヘルス確認 → **commit で正式化**。新面が起動に失敗すれば U-Boot の
`altbootcmd` が旧面へ自動フォールバック(commit しない限り旧面 = 安全側)。**両スロットを
揃えるなら 2 回**実行する(1 回目=非アクティブ面、commit 後の 2 回目=もう一方)。

初回参加用に Tailscale auth key を新スロットの boot FAT へ注入することもできる:
`--authkey <keyfile>`(接続成功後にデバイス側で自動削除)。

デバイス側コマンド:

```bash
ab-status      # 現用スロット
ab-commit      # 試起動した面の手動 commit
uboot-status   # imx-boot A/B の起動元・状態
uboot-update   # imx-boot の A/B 更新
uboot-rollback # imx-boot を前版へ
```

---

## Tailscale について

**prod イメージでは Tailscale が唯一のリモートアクセス手段**(root パスワードロック、
シリアルはログイン不可)。dev イメージ(debug-tweaks)は root パスワード空で LAN SSH も可。

初回起動時に auth key で自動参加する:

1. boot パーティションに `tailscale.authkey` を置く(書き込み時 / `ota-update.sh --authkey` で注入)
2. `tailscale-autoconnect.service` がキーの存在(`ConditionPathExists`)を条件に起動
3. `tailscale up --authkey=… --ssh --accept-dns=false` を実行。`--ssh` で Tailscale SSH 有効
4. 成功するとキーを削除(イメージに残さない)、認証状態は `/data/tailscale` に永続化
   — OTA でも再認証不要

> `--accept-dns=false`:MagicDNS を OS に適用しない。tailscaled が resolv.conf を
> 書き換えるパスが走らず、read-only rootfs での書き込み失敗が根絶される。

auth key は [Tailscale 管理画面](https://login.tailscale.com/admin/settings/keys)で発行
(再利用可能キー推奨)。tailnet の ACL が SSH を許可している必要あり。

---

## シリアル / ベンチ操作

- **DEBIX**:電源 = `scripts/dp100.py`(DP100、`/dev/dp100`)、ブートモード = USB リレー
  (`debix-boot-switch` の `bootsel.py`、`/dev/usbrelay`)、A53 コンソール = FTDI
  `/dev/ttyUSB0`(115200 8N1)、表示検証 = `lcd-validation`(AprilTag + カメラ)
- **XPI**:udev 安定名(`/dev/kart-a53-console` 等)を使う。電源・カメラ検証・UUU は
  `imx8mm-xpi-bench`、シリアル/M4 デバッグは `xpi-serial-debug` スキル

（`.claude/skills/` に各スキルの手順・実測確定値がまとまっている。）

---

## アプリの更新

**正式**:kart-machine-manager を push → レシピの `SRCREV` を更新 → 再ビルド → OTA。

**開発イテレーション**(再ビルド不要):Qt6 SDK でクロスビルドしてバイナリだけ差し替える。

```bash
source <SDK>/environment-setup-*        # SDK は release.sh が Release に同梱 (bitbake meta-toolchain-qt6)
cmake -B build-app ../kart-machine-manager/app-cpp && cmake --build build-app -j
ssh root@<host> 'mount -o remount,rw /'
scp build-app/kmm root@<host>:/usr/bin/kmm
ssh root@<host> 'mount -o remount,ro / ; systemctl restart kmm'
```

ローカルソースからイメージに組み込むには externalsrc 配線
(`local/kas-kmm-externalsrc.yml`、リポジトリ外)を使う。

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
│   ├── recipes-support/ab-tools/ # A/B・U-Boot A/B 管理ツール、fw_env.config
│   └── wic/                      # imx8mp-emmc-ab.wks, imx8mm-emmc-ab.wks, rpi5*.wks
├── m4/                           # M4 ベアメタル雛形・診断 ELF (clk-test 等)
├── learning/                     # M コア/ブート低レベル知識の教材
├── docs/                         # bring-up 記録 (下記)
└── scripts/                      # build/flash/ota/release ヘルパー
```

---

## ドキュメント

### DEBIX (i.MX8MP) — [docs/imx8mp-debix-bringup/](docs/imx8mp-debix-bringup/)

| ファイル | 内容 |
|----------|------|
| 00-plan | 移行計画と実測ログ(工場イメージ確認 → machine 正式化)|
| 01-m7 | Cortex-M7 の起動・can-gw・falcon 統合(CAN1 root クロック等)|
| 02-dts-delta | EVK との DTS 差分 |
| 03-first-boot | 初回起動の U-Boot 修正(DDR 4GB・HDMI・USB)|
| 04-falcon | Falcon mode・デッドマン・落ち先 proper・電源断スイープ |
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

meta-kart レイヤ内の独自コード: MIT。各 upstream レイヤは元のライセンスに従う。
Qt6 (qtbase/qtwayland): LGPL v3 / GPL — 製品配布時に確認が必要。
`imx-boot` の DDR トレーニング FW(firmware-imx)は **NXP EULA** 配布物
(`ACCEPT_FSL_EULA=1` で同意)。
