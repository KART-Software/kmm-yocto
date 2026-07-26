# kmm-yocto — Kart Product Yocto Build

Raspberry Pi 5 向け組み込み Linux イメージを Yocto (scarthgap) + kas-container で構築するプロジェクト。

## 概要

| 項目 | 内容 |
|------|------|
| ターゲット | Raspberry Pi 5 (NVMe ブート) |
| Yocto リリース | scarthgap (5.0) |
| ビルドツール | kas-container (Docker) |
| GUI | Wayland + Weston (kiosk) + PyQt6 |
| init | systemd |
| ネットワーク | systemd-networkd |
| CAN | MCP2515 (SocketCAN) |
| GPIO | libgpiod |
| リモートアクセス | Tailscale + SSH |
| LTE | PIX-MT100 (USB NIC) |

## 使用ハードウェア

| 用途 | 製品 | 備考 |
|------|------|------|
| M.2 SSD HAT | [Waveshare Raspberry Pi 5 用 PCIe-M.2 SSD 変換基板（ヒートシンク&ファン付属）](https://ssci.to/9859) | NVMe ブート用。RPi5 の PCIe に M.2 NVMe SSD を接続 |
| CAN HAT | [Waveshare RS485 CAN HAT](https://amzn.asia/d/07GRvdVZ) | MCP2515 (SPI) + SIT65HVD230 トランシーバ。**オシレータ 12MHz / INT=GPIO25** — `kas/rpi5.yml` の `CAN_OSCILLATOR=12000000` / `CAN0_INTERRUPT_PIN=25` と一致 |

> **M.2 SSD へのイメージ書き込みには USB⇔M.2 (NVMe) 変換アダプタ（または外付けケース）が必要。**
> SSD は M.2 HAT 経由で Pi 本体の PCIe に載るため、そのままでは PC から書き込めない。SSD を USB-M.2 変換で書き込み機に接続し、`flash.sh -nvme` / `remote-flash.sh -nvme` で焼いてから HAT に取り付ける（詳細は「[SD カード / NVMe への書き込み](#sd-カード--nvme-への書き込み)」）。

## 前提条件

- **Ubuntu 22.04 以降** (WSL2 含む)
- Docker がインストール済み
- kas-container が使用可能 (`pipx install kas` or `docker pull ghcr.io/siemens/kas/kas`)
- 十分なディスク容量 (初回ビルドで 50GB 以上推奨)
- QEMU を使う場合: ホストに `qemu-system-aarch64` がインストール済み

```bash
# pipx のインストール (まだの場合)
sudo apt install pipx
pipx ensurepath   # ~/.local/bin を PATH に追加（シェル再起動が必要）

# kas-container のインストール
pipx install kas

# QEMU のインストール
sudo apt install qemu-system-arm qemu-efi-aarch64

# バージョン確認
qemu-system-aarch64 --version
```

> **注意**: Yocto の `runqemu` はビルド成果物内の QEMU を使う場合がありますが、本プロジェクトの `run-qemu.sh` は**ホストの `qemu-system-aarch64`** を直接呼び出します。

## ビルド方法

### build.sh (推奨)

```bash
# RPi5 本番 (NVMe)
./scripts/build.sh prod --nvme

# RPi5 本番 (SD カード) + アプリ埋め込み
./scripts/build.sh prod --sdcard --with-app

# RPi5 本番 (NVMe) + アプリ埋め込み
./scripts/build.sh prod --nvme --with-app

# RPi5 開発 (SD カード, debug-tweaks)
./scripts/build.sh dev --sdcard

# RPi5 開発 (SD カード) + アプリ埋め込み
./scripts/build.sh dev --sdcard --with-app 

# RPi5 開発 (NVMe) + アプリ埋め込み
./scripts/build.sh dev --nvme --with-app

# QEMU 開発
./scripts/build.sh qemu

# QEMU 開発 + アプリ埋め込み
./scripts/build.sh qemu --with-app
```

- `prod` / `dev` は `--sdcard` または `--nvme` の指定が必須
- `--with-app` を指定すると、kas が GitHub から kart-machine-manager をクローンしてイメージに埋め込む
- 未指定の場合は `/opt/kart` が空で作成され、`sync-app.sh` で後からデプロイできる

> **`--with-app` の前に `.env` の配置が必要:**
>
> `meta-kart/recipes-app/kart-machine-manager/files/.env` を配置する（チームメンバーから取得してください）。
>
> `.env` がないとビルドが失敗します。

### kas-container 直接実行

```bash
# 本番イメージ (RPi5, NVMe ブート)
kas-container build kas/rpi5-prod.yml:kas/boot-nvme.yml

# 本番イメージ (RPi5, SD カードブート)
kas-container build kas/rpi5-prod.yml:kas/boot-sdcard.yml

# 開発イメージ (RPi5, SD カードブート)
kas-container build kas/local-dev.yml:kas/boot-sdcard.yml

# 開発イメージ (RPi5, NVMe ブート)
kas-container build kas/local-dev.yml:kas/boot-nvme.yml

# QEMU 開発イメージ (実機不要で動作確認)
kas-container build kas/qemu-dev.yml
```

> **kas の `:` 記法**: 複数の YAML を `:` で連結すると設定がマージされます。
> `rpi5-prod.yml` / `local-dev.yml` にはブート方式が含まれないため、`boot-sdcard.yml` または `boot-nvme.yml` を追加指定してください。

### kas 構成ファイル一覧

| ファイル | 種別 | 内容 |
|----------|------|------|
| `base.yml` | ベース | 共通設定 (repos, distro features, sstate) |
| `rpi5.yml` | マシン | RPi5 固有 (BSP, SPI/CAN, GPU) |
| `qemu.yml` | マシン | QEMU 固有 (qemuarm64, virtio-gpu) |
| `boot-sdcard.yml` | フラグメント | SD カードブート (WKS 指定) |
| `boot-nvme.yml` | フラグメント | NVMe ブート (WKS 指定) |
| `app-embed.yml` | フラグメント | アプリ埋め込み (KART_APP_SRC 設定) |
| `rpi5-prod.yml` | 組み合わせ | base + rpi5 (本番) |
| `local-dev.yml` | 組み合わせ | base + rpi5 + debug-tweaks (開発) |
| `qemu-dev.yml` | 組み合わせ | base + qemu + debug-tweaks (QEMU 開発) |

### キャッシュの共有

DL_DIR / SSTATE_DIR を他プロジェクトと共有したい場合:

```bash
export DL_DIR=/path/to/shared/downloads
export SSTATE_DIR=/path/to/shared/sstate-cache
kas-container build kas/rpi5-prod.yml
```

## QEMU で動作確認

実機がなくても QEMU で GUI を含めた動作確認が可能。

### VNC 経由 (推奨)

```bash
# ビルド
kas-container build kas/qemu-dev.yml

# QEMU 起動 (VNC サーバーがポート 5901 で起動)
./scripts/run-qemu.sh --vnc

# 別ターミナルで VNC クライアント接続
vncviewer localhost:5901
```

### シリアルコンソールのみ

```bash
./scripts/run-qemu.sh --nographic
```

### QEMU SSH 接続

```bash
# QEMU 起動中に別ターミナルから (debug-tweaks 有効時)
ssh root@192.168.7.2
```

## 生成物

ビルド完了後、以下に生成される。

```
build/tmp/deploy/images/raspberrypi5/
├── kart-image-raspberrypi5-sdcard.wic.bz2   # SD カード書き込み用
├── kart-image-raspberrypi5-sdcard.wic.bmap  # bmaptool 用マップ
├── kart-image-raspberrypi5-nvme.wic.bz2     # NVMe 書き込み用
└── kart-image-raspberrypi5-nvme.wic.bmap    # bmaptool 用マップ

build/tmp/deploy/images/qemuarm64/
├── kart-image-qemuarm64.wic          # QEMU 用
└── kart-image-qemuarm64.qcow2        # QEMU 用 (qcow2)
```

## SD カード / NVMe への書き込み

> **M.2 SSD (NVMe) に焼く場合は USB⇔M.2 (NVMe) 変換アダプタが必要。** SSD は [M.2 HAT](#使用ハードウェア) 経由で Pi の PCIe に載るため書き込み時は取り外し、USB-M.2 変換で書き込み機に接続してから `-nvme` で焼く。

### flash.sh (推奨)

```bash
# SD カード
sudo ./scripts/flash.sh -sdcard /dev/sdb
sudo ./scripts/flash.sh -sdcard /dev/mmcblk0

# NVMe
sudo ./scripts/flash.sh -nvme /dev/nvme0n1

# 確認プロンプトをスキップ
sudo ./scripts/flash.sh -y -sdcard /dev/sdb

# data パーティションを保持して焼き直し（推奨: 2回目以降のフラッシュ）
sudo ./scripts/flash.sh --keep-data -nvme /dev/nvme0n1
```

`-sdcard` / `-nvme` は必須。ビルド時の IMAGE_LINK_NAME に対応するイメージを自動選択する。

> **`--keep-data`（remote-flash.sh でも使用可）**: 既存の data パーティション（`LABEL=data`）をバックアップ → 焼き → 復元する。`/data/tailscale` の状態が引き継がれるため **tailnet 上で同一ノードのまま**（亡霊ノードが増えず、authkey の再注入も不要）。`/data/log` も残る。工場出荷状態にしたい場合はオプション無しで焼く（新ノード + authkey 注入）。

<details>
<summary>Windows での書き込み</summary>

#### そもそも物理書き込みが必要か（Windows ユーザー向けの推奨順）

1. **通常の更新は OTA**: WSL 内で `./scripts/ota-update.sh --host <host>`。`/data`（tailscale 識別・ログ）はそもそも触らないので保持は自動。物理アクセス不要
2. **物理フラッシュが必要な場合**（初回移行・復旧・新品）: 下の **WSL2 + flash.sh** で。`--keep-data` も authkey 注入もそのまま使える

> Raspberry Pi Imager 等の GUI 書き込みツールは使わない（ディスク全体上書きで `/data` 保持不可、authkey 注入も不可。すべて WSL2 + flash.sh で完結する）。

#### WSL2 + flash.sh を使う場合

WSL2 ではホスト側のディスクがデフォルトで見えないため、事前に `wsl --mount` でマウントが必要。

```powershell
# PowerShell (管理者) — ディスク番号を確認
Get-Disk

# WSL にマウント (例: ディスク番号 1 の場合)
wsl --mount \\.\PHYSICALDRIVE1 --bare
```

```bash
# WSL2 内 — デバイスが見えることを確認してからフラッシュ
lsblk
sudo ./scripts/flash.sh -sdcard /dev/sdb

# /data (tailscale 識別・ログ) を保持して焼き直す場合
sudo ./scripts/flash.sh --keep-data -sdcard /dev/sdb
```

```powershell
# 書き込み完了後にアンマウント（忘れずに）
wsl --unmount \\.\PHYSICALDRIVE1
```

</details>

### OTA アップデート（A/B・SSD 抜き差し不要）

イメージは A/B (tryboot) レイアウト。稼働中のデバイスへ SSH（Tailscale 可）経由で OS ごと更新できる:

```bash
# ビルド済み最新 nvme イメージで更新（転送 ~211MB gzip）
./scripts/ota-update.sh --host raspberrypi5

# イメージ指定（GitHub Release からダウンロードした wic.bz2 でも OK）
./scripts/ota-update.sh --host <IP> path/to/kart-image-….wic.bz2
```

> **ビルド環境は不要**: 必要なのはこのスクリプトと wic.bz2 だけ（ホスト側依存は `bzip2 fdisk gzip e2fsprogs ssh` の標準ツールのみ・sudo 不要）。Release からイメージを落とせばどの PC (Linux/WSL) からでも OTA できる。

流れ: 非アクティブ面へ書込み → `reboot '0 tryboot'` で新面を**1回だけ**起動 → ヘルス確認 → **y で commit**（正式化）。**新面が起動に失敗した場合はファームウェアが自動で旧面に戻る**（commit しなければ何度リブートしても旧面のまま = 安全側）。

デバイス側コマンド:
```bash
kart-ab-status   # 現用面・autoboot.txt の確認
kart-ab-commit   # tryboot 起動した面の手動 commit
```

パーティション: p1=AUTOBOOT(面セレクタ) / p2,p3=BOOTA,B / p5,p6=rootA,B / p7=data(共有・OTA で消えない)。旧レイアウトからの移行時のみ物理フラッシュが必要（`--keep-data` で tailscale 識別ごと引き継ぎ可）。

### リモートマシンでの書き込み

```bash
# SD カードリーダーが別 PC に接続されている場合
./scripts/remote-flash.sh -sdcard user@remote-pc /dev/sdb

# 確認プロンプトをスキップ
./scripts/remote-flash.sh -y -nvme user@remote-pc /dev/nvme0n1
```

## Raspberry Pi 5 EEPROM 設定

NVMe ブートには EEPROM の boot order 変更が必要。**本 Yocto イメージに `rpi-eeprom` / `raspi-utils`（`vcgencmd`）を含めているので、このイメージ上で直接設定できる**（Raspberry Pi OS の SD 起動は不要）。

### 標準設定の一括適用（新しいボードはこれだけで OK）

検証済みの標準 EEPROM 設定（`BOOT_ORDER=0xf16` / `PSU_MAX_CURRENT=5000` / `DISABLE_HDMI=1` ほか）を冪等に適用するコマンドをイメージに同梱している:

```bash
kart-eeprom-setup --check    # 差分表示のみ（何も変更しない）
sudo kart-eeprom-setup       # 差分があれば適用をステージ → 次回リブートで反映
sudo kart-eeprom-setup --reboot   # 適用して即リブート
```

設定内容はスクリプト自体（`meta-kart/recipes-support/kart-eeprom-setup/`）がソースオブトゥルース。個別にいじる場合は従来通り:

```bash
# 現在の EEPROM 設定を確認
rpi-eeprom-config
vcgencmd bootloader_config

# boot order を編集 (6=NVMe, 4=USB, 1=SD, f=リトライループ)
sudo rpi-eeprom-config --edit
```

> ⚠️ EEPROM 書き込みは失敗すると起動不能になり得る（別 SD の recovery.bin で復旧）。まず `rpi-eeprom-config`（読み取り）で現状を確認してから編集する。RPi OS とは boot パスが異なる（`/boot` vs `/boot/firmware`）ため、apply の実挙動は実機で一度確認するのが安全。

PCIe Gen 3 は `config.txt` 側で設定（`kas/rpi5.yml` の `RPI_EXTRA_CONFIG` に `dtparam=pciex1_gen=3` 設定済み）。設定後、NVMe を接続して再起動する。

## 初回起動確認

### 基本確認

```bash
# systemd の状態確認
systemctl status

# ネットワーク確認
ip addr
networkctl status
ping -c 3 8.8.8.8
```

### GUI 確認

```bash
# Weston が起動しているか
systemctl status weston

# GUI アプリが起動しているか
systemctl status kart-machine-manager
journalctl -u kart-machine-manager -f
```

### CAN バス確認

```bash
# can0 が UP しているか
systemctl status can0-up
ip -detail link show can0

# CAN 送信テスト (別端末が必要)
cansend can0 123#DEADBEEF

# CAN 受信モニタ
candump can0
```

### GPIO 確認

```bash
# GPIO チップ一覧
gpiodetect

# GPIO ライン一覧
gpioinfo gpiochip0

# 入力読み取り (例: GPIO17)
gpioget gpiochip0 17

# 出力設定 (例: GPIO27 を HIGH)
gpioset gpiochip0 27=1
```

### Tailscale 確認

```bash
# tailscaled 起動確認
systemctl status tailscaled

# 初回認証 (ブラウザで表示される URL にアクセス)
tailscale up

# 接続状態確認
tailscale status

# tailnet 経由 SSH (別マシンから)
ssh root@<tailscale-ip>
```

### PIX-MT100 (USB LTE) 確認

```bash
# USB デバイス認識確認
lsusb

# ネットワークインターフェース確認 (usb0 or eth1 等)
ip addr

# PIX-MT100 管理画面 (ブラウザで)
# http://192.168.0.1
```

## アプリのデプロイ（再ビルド不要）

`kart-machine-manager` の**アプリコードだけ**を更新する場合は、再ビルド・再フラッシュせず `sync-app.sh` で rsync デプロイできる。

```bash
# 実機 (直 IP / Tailscale IP)
./scripts/sync-app.sh --target <IP>

# ~/.ssh/config のホスト名を使う
./scripts/sync-app.sh --host <ssh-config-host>

# QEMU (デフォルト: root@192.168.7.2)
./scripts/sync-app.sh --qemu

# デプロイ元を明示 (デフォルトは ../kart-machine-manager)
./scripts/sync-app.sh --target <IP> /path/to/kart-machine-manager
```

配置先は `/opt/kart/kart-machine-manager/`（`.pyc` プリコンパイル → rsync → `chown kart:kart`）。`.git` `.venv` `log/` `uv.lock` などは除外。`--no-restart` で配置のみ。

デプロイ後にコードを反映するには daemon を再起動する。systemd ユニットは `kmmd.service`（デーモン）と `kmm-start.service`（GUI 起動通知）:

```bash
ssh root@<IP> 'systemctl restart kmmd && systemctl start kmm-start'
```

> **注意:** `sync-app.sh` は**アプリコードのみ**を配る。OS 側の設定（CAN bitrate / オシレータ、systemd ユニット、カーネル config など）は反映されないため、それらの変更は再ビルド + 再フラッシュが必要。

## 設定変更

### CAN bitrate 変更

```bash
# /etc/default/can0 を編集
vi /etc/default/can0
# BITRATE=250000

# サービス再起動
systemctl restart can0-up
```

### GPIO ピン変更

```bash
# /opt/kart-machine-manager/gpio-config.json を編集
vi /opt/kart-machine-manager/gpio-config.json

# GUI 再起動
systemctl restart kart-machine-manager
```

### MCP2515 CAN HAT 設定変更

kas YAML (`kas/rpi5.yml`) の `local_conf_header` を編集:

```yaml
rpi5-spi-can: |
  ENABLE_SPI_BUS = "1"
  ENABLE_CAN = "1"
  CAN_OSCILLATOR = "8000000"    # 8MHz の場合
  CAN0_INTERRUPT_PIN = "25"      # HAT の INT ピン
```

変更後、再ビルドが必要。

### オシレータ周波数の変更（再ビルド不要）

MCP2515 のオシレータ周波数は boot パーティションの `config.txt` に dtoverlay パラメータとして書かれているため、再ビルドせず実機上で変更できる。HAT の水晶と設定値が一致していないと CAN が通信できない（設定ビットレートと実効ビットレートがずれる）ので、現物の水晶（8.000 / 12.000 / 16.000 MHz など）に合わせる。

```bash
# 実機上で編集 (/boot は vfat で rw マウント)
vi /boot/config.txt
# dtoverlay=mcp2515-can0,oscillator=12000000,interrupt=25
#                        ^^^^^^^^^^^^^^^^^^^^ ここを 8000000 / 16000000 などに変更

reboot
```

PC 側で boot パーティション (FAT32, label=boot) をマウントして `config.txt` を編集してもよい。

> 恒久的に確定したら `kas/rpi5.yml` の `CAN_OSCILLATOR` も同じ値に更新する（次回以降のビルドに反映）。上記「MCP2515 CAN HAT 設定変更」参照。

## プロジェクト構成

```
kmm-yocto/
├── kas/
│   ├── base.yml          # 共通設定 (repos, distro features)
│   ├── rpi5.yml          # RPi5 固有設定 (machine, BSP, CAN, GPIO)
│   ├── qemu.yml          # QEMU 固有設定 (qemuarm64, virtio-gpu)
│   ├── rpi5-prod.yml     # 本番ビルド → includes: base + rpi5
│   ├── local-dev.yml     # RPi5 開発 → includes: base + rpi5 + debug
│   └── qemu-dev.yml      # QEMU 開発 → includes: base + qemu + debug
├── meta-kart/
│   ├── conf/layer.conf
│   ├── recipes-core/images/kart-image.bb
│   ├── recipes-graphics/weston/          # Kiosk 設定
│   ├── recipes-app/kart-machine-manager/  # PyQt6 GUI アプリ
│   ├── recipes-support/can-setup/        # CAN 初期化
│   ├── recipes-connectivity/tailscale/   # Tailscale VPN
│   ├── recipes-kernel/linux/             # カーネル config fragments
│   └── wic/kart-rpi5-nvme.wks           # NVMe パーティション定義
├── scripts/
│   ├── build.sh          # ビルドヘルパー
│   ├── run-qemu.sh       # QEMU 起動 (ホストの qemu-system-aarch64 を使用)
│   ├── flash.sh          # SD/NVMe 書き込み (-sdcard/-nvme 指定)
│   ├── remote-flash.sh   # リモート書き込み
│   └── sync-app.sh       # アプリデプロイ (rsync)
├── .gitignore
└── README.md
```

## レイヤ構成

| レイヤ | ブランチ | 用途 |
|--------|----------|------|
| poky (meta, meta-poky) | scarthgap | Yocto コアレイヤ |
| meta-openembedded (meta-oe, meta-python, meta-networking, meta-filesystems) | scarthgap | 追加パッケージ |
| meta-raspberrypi | scarthgap | RPi5 BSP |
| meta-qt6 | 6.10 | Qt6 + PyQt6 |
| meta-kart | local | 製品固有レシピ |

## 未確定事項

- [ ] PIX-MT100 が Raspberry Pi 側で具体的にどの USB class / NIC 名で見えるか
- [ ] MCP2515 HAT の実際の配線 (SPI バス, CS, INT GPIO, 発振周波数)
- [ ] 使用ディスプレイの接続方式 (HDMI / DSI)
- [ ] Tailscale の認証方法 (手動 / auth key)
- [ ] PyQt6 のライセンス条件確認 (GPL v3)
- [ ] Tailscale レシピの sha256sum (初回ビルド時に要更新)

## ライセンス

meta-kart レイヤ内の独自コード: MIT  
各 upstream レイヤは元のライセンスに従う。  
PyQt6: GPL v3 — 製品配布時に確認が必要。
