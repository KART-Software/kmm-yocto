# Project Guidelines

## Overview

Raspberry Pi 5 向け組み込み Linux イメージを Yocto (scarthgap 5.0) + kas-container で構築するプロジェクト。
PyQt6 ダッシュボードアプリ (kart-machine-manager) を Wayland/Weston 上で動作させる。
詳細は [README.md](README.md) を参照。

## Build Commands

```bash
# 本番イメージ (RPi5, NVMe)
kas-container build kas/rpi5-prod.yml

# 開発イメージ (RPi5, SD カード)
kas-container build kas/local-dev.yml:kas/boot-sdcard.yml

# QEMU 開発イメージ
kas-container build kas/qemu-dev.yml
```

kas の `:` 記法で複数 YAML をマージする。`local-dev.yml` にはブート方式が含まれないため `boot-sdcard.yml` か `boot-nvme.yml` の追加指定が必須。

## Architecture

### kas 構成パターン

```
kas/
  base.yml       # 共通 (repos, distro features, sstate)
  rpi5.yml       # RPi5 マシン設定
  qemu.yml       # QEMU マシン設定
  boot-*.yml     # ブートフラグメント (WKS 指定のみ)
  *-prod.yml     # 本番 = base + machine + boot
  *-dev.yml      # 開発 = base + machine + debug-tweaks
```

### meta-kart レイヤー構造

- `conf/layer.conf` — Priority 10, depends on `core qt6-layer`
- `recipes-core/images/kart-image.bb` — メインイメージレシピ
- `recipes-app/` — kart-machine-manager アプリデプロイ
- `recipes-graphics/` — Weston/seatd 設定 (kiosk-shell, `kart` ユーザー作成)
- `recipes-kernel/` — CAN/NVMe/USB-net カーネル config フラグメント
- `recipes-support/` — CAN bus セットアップ (systemd service)
- `recipes-connectivity/` — Tailscale (プリビルドバイナリ)
- `recipes-python/` — python3-dotenv, PyQt6 bbappend
- `wic/` — ディスクイメージレイアウト (.wks)

### BBFILES_DYNAMIC

`meta-kart/conf/layer.conf` で `meta-raspberrypi` 存在時のみ kernel bbappend をロードする。QEMU ビルドでは RPi 固有パッチが除外される。

## Conventions

### Yocto レシピ

- 変数名: `UPPERCASE_SNAKE_CASE` (BitBake 標準)
- bbappend のワイルドカード: `%` でバージョン非依存に
- ファイル追加: `FILESEXTRAPATHS:prepend := "${THISDIR}/files:"` パターン
- systemd サービス: `inherit systemd` + `SYSTEMD_SERVICE:${PN}` + `SYSTEMD_AUTO_ENABLE`
- レイヤー優先度: meta-kart = 10 (meta-openembedded より高い)

### シェルスクリプト (scripts/)

- `flash-nvme.sh` / `flash-sdcard.sh` — bmaptool 優先、dd フォールバック
- `sync-app.sh` — rsync で開発中アプリを実機/QEMU にデプロイ
- `run-qemu.sh` — QEMU 起動 (TAP/slirp/VNC 対応)

## Pitfalls

- **`local-dev.yml` 単体ビルド不可**: ブートフラグメント (boot-sdcard/boot-nvme) の追加が必須
- **weston.socket マスク**: weston-init.bbappend で意図的に socket activation を無効化し multi-user.target で起動
- **`kart` ユーザー二重作成**: weston-init.bbappend と kart-machine-manager レシピの両方で作成される
- **キャッシュパス**: `DL_DIR=../downloads`, `SSTATE_DIR=../sstate-cache` (kas base.yml で設定)
- **初回ビルド**: 50GB 以上のディスク容量が必要
- **QEMU イメージ形式**: `.ext4` (QEMU 用) と `.wic` (実機用) は用途が異なる
