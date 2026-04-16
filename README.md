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
| ネットワーク | NetworkManager |
| CAN | MCP2515 (SocketCAN) |
| GPIO | libgpiod |
| リモートアクセス | Tailscale + SSH |
| LTE | PIX-MT100 (USB NIC) |

## 前提条件

- Docker がインストール済み
- kas-container が使用可能 (`pip install kas` or `docker pull ghcr.io/siemens/kas/kas`)
- 十分なディスク容量 (初回ビルドで 50GB 以上推奨)

```bash
# kas-container のインストール (まだの場合)
pip install kas
```

## ビルド方法

```bash
# 本番イメージ (Raspberry Pi 5)
kas-container build kas/rpi5-prod.yml

# 開発イメージ (Raspberry Pi 5, debug-tweaks 有効)
kas-container build kas/local-dev.yml

# QEMU 開発イメージ (実機不要で動作確認)
kas-container build kas/qemu-dev.yml
```

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

# QEMU 起動 (VNC サーバーがポート 5900 で起動)
./scripts/run-qemu.sh --vnc

# 別ターミナルで VNC クライアント接続
vncviewer localhost:5900
```

### X11 フォワーディング

```bash
# ホスト側で X11 アクセスを許可
xhost +local:

# QEMU 起動 (ホストの X サーバーに直接表示)
./scripts/run-qemu.sh --x11
```

### シリアルコンソールのみ

```bash
./scripts/run-qemu.sh --nographic
```

### QEMU SSH 接続

```bash
# QEMU 起動中に別ターミナルから (debug-tweaks 有効時)
ssh -p 2222 root@localhost
```

## 生成物

ビルド完了後、以下に生成される。

```
build/tmp/deploy/images/raspberrypi5/
├── kart-image-raspberrypi5.wic       # NVMe 書き込み用イメージ
├── kart-image-raspberrypi5.wic.bz2   # 圧縮版
└── kart-image-raspberrypi5.wic.bmap  # bmaptool 用マップ

build/tmp/deploy/images/qemuarm64/
├── kart-image-qemuarm64.wic          # QEMU 用
└── kart-image-qemuarm64.qcow2        # QEMU 用 (qcow2)
```

## NVMe への書き込み

### bmaptool (推奨・高速)

```bash
sudo bmaptool copy \
    build/tmp/deploy/images/raspberrypi5/kart-image-raspberrypi5.wic.bz2 \
    /dev/nvme0n1
```

### dd

```bash
bzcat build/tmp/deploy/images/raspberrypi5/kart-image-raspberrypi5.wic.bz2 \
    | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
```

### ヘルパースクリプト

```bash
sudo ./scripts/flash-nvme.sh /dev/nvme0n1
```

## Raspberry Pi 5 EEPROM 設定

NVMe ブートには EEPROM の boot order 変更が必要。  
**別の SD カードで Raspberry Pi OS を起動して設定する。**

```bash
# EEPROM 設定を編集
sudo rpi-eeprom-config --edit

# 以下を設定 (6=NVMe, 4=USB, 1=SD, f=リトライループ)
BOOT_ORDER=0xf416

# PCIe Gen 3 を有効化する場合
# /boot/firmware/config.txt に以下を追加
# dtparam=pciex1
# dtparam=pciex1_gen=3
```

設定後、NVMe を接続して再起動する。

## 初回起動確認

### 基本確認

```bash
# systemd の状態確認
systemctl status

# ネットワーク確認
ip addr
nmcli device status
ping -c 3 8.8.8.8
```

### GUI 確認

```bash
# Weston が起動しているか
systemctl status weston

# GUI アプリが起動しているか
systemctl status kart-gui
journalctl -u kart-gui -f
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
# /opt/kart-gui/gpio-config.json を編集
vi /opt/kart-gui/gpio-config.json

# GUI 再起動
systemctl restart kart-gui
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
│   ├── recipes-app/kart-gui/             # PyQt6 GUI アプリ
│   ├── recipes-support/can-setup/        # CAN 初期化
│   ├── recipes-connectivity/tailscale/   # Tailscale VPN
│   ├── recipes-kernel/linux/             # カーネル config fragments
│   └── wic/kart-rpi5-nvme.wks           # NVMe パーティション定義
├── scripts/
│   ├── run-qemu.sh       # QEMU 起動ヘルパー
│   └── flash-nvme.sh     # NVMe 書き込みヘルパー
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
