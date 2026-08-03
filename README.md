# kmm-yocto — Kart Product Yocto Build

Raspberry Pi 5 向け組み込み Linux イメージを Yocto (scarthgap) + kas-container で構築するプロジェクト。

## 概要

| 項目 | 内容 |
|------|------|
| ターゲット | Raspberry Pi 5 (NVMe ブート) |
| Yocto リリース | scarthgap (5.0) |
| ビルドツール | kas-container (Docker) |
| GUI | Wayland + Weston (kiosk) + C++/Qt6 Widgets |
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

# RPi5 本番 (SD カード)
./scripts/build.sh prod --sdcard

# RPi5 開発 (SD カード, debug-tweaks)
./scripts/build.sh dev --sdcard

# RPi5 開発 (NVMe)
./scripts/build.sh dev --nvme

# QEMU 開発
./scripts/build.sh qemu
```

- `prod` / `dev` は `--sdcard` または `--nvme` の指定が必須
- アプリ (C++ 版 kart-machine-manager) は**常にイメージに含まれる**。レシピ
  (`meta-kart/recipes-app/kart-machine-manager/`) が GitHub から `SRCREV` 固定で
  取得してクロスビルドする。アプリ更新 = レシピの `SRCREV` を上げて再ビルド
  （旧 `--with-app` / `kas/app-embed.yml` は廃止）

> **`.env`（秘密設定）はイメージに焼き込まれない**: kmm.service は `/data/kmm.env` を読む。ビルドに `.env` は不要で、**イメージは Release に公開してよい**。
>
> デバイスごとに1回だけ配置する（/data 上なので OTA・再フラッシュ(--keep-data) を跨いで永続）:
> ```bash
> scp meta-kart/recipes-app/kart-machine-manager/files/.env root@<host>:/data/kmm.env
> ssh root@<host> systemctl restart kmm   # 反映
> ```
> （`.env` 自体はチームメンバーから取得。リポジトリには含まれない）

### kas-container 直接実行

`build.sh` を経由せず直接叩く場合は、先にキャッシュ用の環境変数を export してください:

```bash
export DL_DIR=$PWD/downloads SSTATE_DIR=$PWD/sstate-cache
```

kas-container がこれらをコンテナ内の `/downloads`・`/sstate` にバインドマウントします。未設定だと `base.yml` の弱いデフォルト (`${TOPDIR}/../...`) がコンテナ内の `TOPDIR=/build` を基準に解決され、書き込めないコンテナルート直下を指すため、bitbake の sanity check が `Failed to create a file in SSTATE_DIR: Permission denied` で停止します。

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
| `sdk.yml` | フラグメント | Qt SDK ビルド用 (qtbase のみに絞る) |
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

## Tailscale について

**本番イメージでは Tailscale が唯一のリモートアクセス手段。** ここを理解せずに進めるとデバイスに入れなくなるので、先に読んでおくこと。

Tailscale は WireGuard ベースの VPN。参加した機器同士が NAT やファイアウォールを越えて直接通信でき、各機器は tailnet 内の固定 IP（`100.x.y.z`）を持つ。インターネット側にポートを開けずに SSH できるのが利点。

> ⚠️ **prod イメージの root パスワードはロックされている。** `kas/rpi5-prod.yml` は `debug-tweaks` を含まないため（含むのは `local-dev.yml` / `qemu-dev.yml` のみ）、パスワード認証が全経路で無効になる。**SSH だけでなく HDMI コンソールもシリアルコンソールもログインできない。** 入る手段は Tailscale SSH のみ。

### 自動接続の仕組み

初回起動時に auth key を使って自動で tailnet に参加する。

1. ブートパーティション（`BOOTA`）に `tailscale.authkey` を置く。`flash.sh --authkey-file` が焼くときに書き込む
2. 起動時、`tailscale-autoconnect.service` がキーの存在を条件に起動する（`ConditionPathExists=/boot/tailscale.authkey`）
3. `tailscale up --authkey=... --ssh` を実行。`--ssh` により **Tailscale SSH** が有効になり、ローカルにログイン手段がなくても tailnet 経由で入れる
4. 成功するとキーをブートパーティションから削除する（イメージに残さない）
5. 以降の認証状態は `/data/tailscale` に永続化されるので、OTA でも再認証は不要

auth key は [Tailscale 管理画面](https://login.tailscale.com/admin/settings/keys) で発行する。**再利用可能（reusable）なキーを推奨** — 使い捨てキーは 1 台で消費され、焼き直しや別デバイスで使い回すと失敗する。tailnet の ACL が SSH を許可している必要もある。

### 繋がらなくなったときの復旧

パスワード認証が無い以上、**起動中のデバイスに入る手段は無い**。ストレージを physically 外して対処する。

1. SD / SSD を別マシンに接続する
2. `BOOTA` ラベルのパーティションをマウントし、`tailscale.authkey` に新しいキーを書く
3. 戻して起動すると `tailscale-autoconnect.service` が拾って再参加する

焼き直しは不要。`/data` も保持される。**シリアルコンソール（`BOOT_UART=1`）はログインには使えないが**、起動ログやカーネルパニックが見えるので原因究明には有用（ordering cycle の発見もこれで行われた）。

## 新規デバイスのセットアップ

新品の Raspberry Pi 5 + SSD を製品状態にするまでの通し手順。各ステップの詳細はリンク先を参照。

| # | 手順 | 詳細 |
|---|------|------|
| 1 | SD 用と NVMe 用のイメージを両方ビルドし、片方を退避する | [準備](#準備) |
| 2 | SD カードを焼く（auth key 注入込み） | [flash.sh](#flashsh-推奨) |
| 3 | SD と SSD を装着して起動し、tailnet 経由で SSH できることを確認 | [Tailscale について](#tailscale-について) |
| 4 | **SD で起動している間に** EEPROM を設定する（2 回実行が必要） | [EEPROM 設定](#raspberry-pi-5-eeprom-設定) |
| 5 | NVMe にイメージを書き込む | [書き込み](#書き込み) |
| 6 | NVMe 側の初期設定（tailscale の引き継ぎ、`/data/kmm.env`） | [NVMe 側の初期設定](#nvme-側の初期設定) |
| 7 | 電源を落とし、**SD カードを抜いてから** 起動する | [起動切り替え](#起動切り替え) |
| 8 | root / `/boot` / `/data` が全て NVMe を指しているか検証する | [初回起動確認](#初回起動確認) |

順序で特に注意すべき点:

- **EEPROM は SD 起動中（ステップ 4）に設定する。** `BOOT_ORDER=0xf16` が入っていないと、NVMe に書き込んでも NVMe から起動しない
- **`/data/kmm.env` の配置は SD を抜いた後（ステップ 7 の後）に行う。** SD が挿さっている間は `/data` が SD 側を指す可能性があり、NVMe 側に書いたつもりが SD に書かれる
- **auth key は再利用可能なものを用意する。** ステップ 2 と 6 で 2 回必要になる場合がある

> **アプリの設定ファイル `/data/kmm.env` は必ず配置すること。** `kmm.service` はここから設定を読む。置かないとアプリが起動に失敗し、`Restart=on-failure` により 3 秒ごとに再起動を繰り返す。内容はチームから受け取る（リポジトリには含まれない）。

SSD が既に M.2 HAT に載っていて PC から直接書けない場合は、上記の SD 経由が標準ルート。USB-M.2 変換アダプタがあるなら、SSD を外して PC から直接焼く方が手数は少ない（[flash.sh](#flashsh-推奨) の `-nvme`）。

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

> アプリ (C++ 版) は常にイメージに含まれるため、OTA だけでアプリも一緒に更新される（旧 Python イメージ時代の「アプリなしイメージ + sync-app」運用は廃止）。

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

### 標準設定の一括適用（新しいボード）

検証済みの標準 EEPROM 設定を冪等に適用するコマンドをイメージに同梱している。管理対象は 6 項目:

| 設定 | 値 | 意図 |
|------|-----|------|
| `BOOT_ORDER` | `0xf16` | NVMe → SD フォールバック → リトライ |
| `PSU_MAX_CURRENT` | `5000` | USB-PD ネゴをスキップ（GPIO 5V 給電 / 非対応電源向け） |
| `DISABLE_HDMI` | `1` | ブートローダの表示初期化をスキップ |
| `boot_partition` | `1` | ブートパーティション走査をスキップ |
| `BOOT_UART` | `1` | デバッグ用 UART を維持（コスト実測 ~0ms） |
| `POWER_OFF_ON_HALT` | `0` | カートはマスタースイッチで電源を切るため |

**新しいボードでは 2 回実行する必要がある。**

```bash
kart-eeprom-setup --check    # 差分表示のみ（何も変更しない）
kart-eeprom-setup            # 差分があれば適用をステージ
reboot                       # ここで初めてブートローダが適用する
kart-eeprom-setup            # 2 回目: 一致確認 + 残骸の掃除
```

`kart-eeprom-setup --reboot` なら 2〜3 行目をまとめられる。

1 回目は「差分あり → `--apply` → `/boot` に `pieeprom.upd` / `.sig` / `recovery.bin` が残る」で終わる。ブートローダはこの残骸を毎ブート timestamp 照合しており **+0.27s/boot** かかる。掃除処理は「設定が既に一致している」分岐でのみ走るため、再起動後にもう一度実行しないと残り続ける。

> **`sudo` を付けないこと。** 本イメージに `sudo` は入っておらず（root でログインする前提）、`command not found` になる。

> **自動実行はされない。** レシピは `/usr/sbin/kart-eeprom-setup` を置くだけで systemd ユニットは無く、ボードごとに手動で一度だけ行う運用。

> **SD → NVMe の初期構築では SD で起動している段階で実行する。** `BOOT_ORDER=0xf16` が入っていないと、NVMe に書き込んでも NVMe から起動しない。工場出荷状態の値は `--check` で確認すること。

設定内容はスクリプト自体（`meta-kart/recipes-support/kart-eeprom-setup/`）がソースオブトゥルース。個別にいじる場合は従来通り:

```bash
# 現在の EEPROM 設定を確認
rpi-eeprom-config
vcgencmd bootloader_config

# boot order を編集 (6=NVMe, 4=USB, 1=SD, f=リトライループ)
rpi-eeprom-config --edit
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

### NVMe から起動できているかの確認

SD 経由でセットアップした場合は必ず確認する。

```bash
grep -o 'root=[^ ]*' /proc/cmdline          # root=/dev/nvme0n1p5 であること
grep -E ' /boot | /data ' /proc/mounts      # 両方 /dev/nvme0n1p* であること
```

> ⚠️ **`/boot` や `/data` が `mmcblk0p*` になっていたら SD カードが挿さったまま。** 両ディスクに `AUTOBOOT` / `BOOTA` / `BOOTB` / `roota` / `rootb` / `data` という同一ラベルが付くため、`/boot`（`kart-boot-mount.service` が `LABEL=BOOTA` でマウント）と `/data`（fstab の `LABEL=data`）がどちらのディスクを掴むかは非決定的になる。root はカーネル cmdline が実デバイスを指定しているので影響を受けず、**root だけ NVMe で `/boot` と `/data` は SD という混在状態**になる。電源を落として SD を抜くこと。

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

auth key を注入していれば初回起動時に自動で参加している（[仕組み](#自動接続の仕組み)）。手動で `tailscale up` を叩く必要は通常ない。

```bash
# tailscaled 起動確認
systemctl status tailscaled

# 自動接続の結果を確認（キーを注入した初回のみ動く）
systemctl status tailscale-autoconnect
journalctl -u tailscale-autoconnect

# 接続状態確認
tailscale status

# tailnet 経由 SSH (別マシンから)
ssh root@<tailscale-ip>
```

参加できていない場合、`/boot/tailscale.authkey` が残っていればキーが弾かれている（使い捨てキーの消費済みなど）。キーが消えていれば接続に成功している。復旧手順は [Tailscale について](#繋がらなくなったときの復旧) を参照。

### PIX-MT100 (USB LTE) 確認

```bash
# USB デバイス認識確認
lsusb

# ネットワークインターフェース確認 (usb0 or eth1 等)
ip addr

# PIX-MT100 管理画面 (ブラウザで)
# http://192.168.0.1
```

## アプリの更新

アプリ (C++ 版 kart-machine-manager) はレシピが `SRCREV` 固定で GitHub から取得してビルドする。

**正式な更新**: kart-machine-manager を push → `meta-kart/recipes-app/kart-machine-manager/kart-machine-manager_2.0.bb` の `SRCREV` をそのコミットに更新 → イメージ再ビルド → OTA。

**開発イテレーション（再ビルド・再フラッシュ不要）**: Yocto SDK でクロスビルドしてバイナリだけ差し替える。SDK インストーラは **GitHub Release に同梱**（`poky-*-toolchain-*.sh`、release.sh が自動でビルド・アップロード）。手元で生成する場合:

```bash
kas-container shell kas/rpi5-prod.yml:kas/boot-nvme.yml:kas/sdk.yml -c "bitbake meta-toolchain-qt6"
# -> build/tmp/deploy/sdk/poky-*-toolchain-*.sh (自己完結インストーラ)
```

使い方（kas / bitbake / Docker 不要）:

```bash
source <SDK>/environment-setup-cortexa76-poky-linux
cmake -B build-rpi5 kart-machine-manager/app-cpp && cmake --build build-rpi5 -j
ssh root@<host> 'mount -o remount,rw /'
scp build-rpi5/kmm root@<host>:/usr/bin/kmm
ssh root@<host> 'mount -o remount,ro / ; systemctl restart kmm'
```

または kmm-yocto 内で `devtool`（`devtool add kmm-cpp <src>` → `devtool build`）でも同じバイナリが得られる。

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
│   ├── recipes-app/kart-machine-manager/  # C++/Qt6 GUI アプリ
│   ├── recipes-support/can-setup/        # CAN 初期化
│   ├── recipes-connectivity/tailscale/   # Tailscale VPN
│   ├── recipes-kernel/linux/             # カーネル config fragments
│   └── wic/kart-rpi5-nvme.wks           # NVMe パーティション定義
├── scripts/
│   ├── build.sh          # ビルドヘルパー
│   ├── run-qemu.sh       # QEMU 起動 (ホストの qemu-system-aarch64 を使用)
│   ├── flash.sh          # SD/NVMe 書き込み (-sdcard/-nvme 指定)
│   ├── remote-flash.sh   # リモート書き込み
│   ├── ota-update.sh     # A/B OTA 更新
│   └── release.sh        # GitHub Release 作成
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
- [x] ~~Tailscale の認証方法~~ → auth key をブートパーティションに注入し、`tailscale-autoconnect.service` が初回起動時に `--ssh` 付きで接続する方式で確定（[詳細](#自動接続の仕組み)）
- [x] ~~PyQt6 のライセンス条件確認~~ → C++/Qt6 Widgets への移行により PyQt6 はイメージから消滅（マニフェスト上 0 パッケージ）。Qt6 本体のライセンス条件は別途要確認
- [x] ~~Tailscale レシピの sha256sum~~ → `8eb0ae11...` で確定済み

## ライセンス

meta-kart レイヤ内の独自コード: MIT  
各 upstream レイヤは元のライセンスに従う。  
Qt6 (qtbase / qtwayland): LGPL v3 / GPL — 製品配布時に確認が必要。

## SD カードから NVMe へ書き込む

SSD を M.2 HAT に載せたままでは PC から直接書けない。USB-M.2 変換アダプタが手元にない場合は、**SD カードで起動したラズパイ自身に NVMe を書かせる**方法が使える。

起動用の SD は 2 通り選べる。**Raspberry Pi OS が既に入った SD が手元にあるなら、そちらの方が手数が少ない。**

| | kart イメージの SD | Raspberry Pi OS の SD |
|---|---|---|
| SD 用イメージのビルド | 必要（NVMe 版と交互に消えるので退避も必要） | **不要** |
| 書き込み | 手動で `dd` をパイプ | **`remote-flash.sh` がそのまま使える** |
| `bmaptool` による高速化 | 不可（イメージに無い） | **可（`apt install bmap-tools`）** |
| ラベル衝突 | **起きる**（SD を抜き忘れると事故） | 起きない（`bootfs`/`rootfs` で重複しない） |
| EEPROM 設定 | `kart-eeprom-setup` が使える | `rpi-eeprom-config` で手動、または NVMe 起動後に実施 |
| Tailscale | SD 側の状態を移送できる | auth key の注入のみ |

以下はまず kart イメージの SD を使う手順。Raspberry Pi OS を使う場合は
[Raspberry Pi OS の SD から書き込む場合](#raspberry-pi-os-の-sd-から書き込む場合) へ。

### 準備

SD 版と NVMe 版の両方のイメージが必要になる。ただし両者は同じ `kart-image` レシピなので、片方をビルドするともう片方のデプロイ成果物が消える（下の注意を参照）。先にビルドした方を退避しておく。

```bash
./scripts/build.sh prod --sdcard
mkdir -p build/images-archive
cp -L build/tmp/deploy/images/raspberrypi5/kart-image-raspberrypi5-sdcard.wic.bz2 \
      build/tmp/deploy/images/raspberrypi5/kart-image-raspberrypi5-sdcard.wic.bmap \
      build/images-archive/

./scripts/build.sh prod --nvme
```

SD カードを焼く。`IMAGE_DIR` で退避先を指定する。

```bash
sudo IMAGE_DIR=$PWD/build/images-archive ./scripts/flash.sh -sdcard /dev/sdX --authkey-file /path/to/tskey
```

SD と SSD の両方を装着して起動し、tailnet 経由で SSH できることを確認する。

```bash
ssh root@<pi> 'cat /proc/cmdline; grep nvme /proc/partitions'
```

`root=/dev/mmcblk0p5` なら SD から起動できている。`nvme0n1` が見えていれば SSD も認識されている。

### 書き込み

圧縮したまま転送し、ラズパイ側で展開する（転送量は 160MB 程度で済む）。

```bash
cat build/tmp/deploy/images/raspberrypi5/kart-image-raspberrypi5-nvme.wic.bz2 \
  | ssh root@<pi> 'bzcat | dd of=/dev/nvme0n1 bs=4M conv=fsync status=progress'
```

実測では 3.9GB の展開・書き込みに 33 秒（117 MB/s）。律速はネットワークではなく busybox の `bzcat`。

`dd` が報告したバイト数が `.wic` の実サイズと一致することを確認する。

```bash
ls -lL build/tmp/deploy/images/raspberrypi5/kart-image-raspberrypi5-nvme.wic
```

パーティションとラベルを確認する。

```bash
ssh root@<pi> 'grep nvme /proc/partitions'
ssh root@<pi> 'blkid /dev/nvme0n1p1 /dev/nvme0n1p2 /dev/nvme0n1p5 /dev/nvme0n1p7'
```

`p1 AUTOBOOT` / `p2 BOOTA` / `p3 BOOTB` / `p5 roota` / `p6 rootb` / `p7 data` が出れば成功。

> イメージには `lsblk` / `wipefs` / `partprobe` / `sudo` が入っていない（`blkid` は `/usr/sbin` にある）。`bzcat` は busybox、`dd` は coreutils なので `conv=fsync` と `status=progress` はどちらも使える。`dd` がデバイスを閉じた時点でカーネルがパーティションテーブルを読み直すため、`partprobe` がなくても p1〜p7 は現れる。

書き込んだ内容を read-only でマウントして確認しておくと安心。

```bash
# rootfs にアプリ本体が入っているか
ssh root@<pi> 'mkdir -p /run/chk && mount -o ro /dev/nvme0n1p5 /run/chk \
  && ls -l /run/chk/usr/bin/kmm && grep VERSION_ID /run/chk/etc/os-release \
  && umount /run/chk'

# BOOTA の cmdline が NVMe を指しているか
ssh root@<pi> 'mkdir -p /run/chk && mount -o ro /dev/nvme0n1p2 /run/chk \
  && cat /run/chk/cmdline.txt && umount /run/chk && rmdir /run/chk'
```

cmdline が `root=/dev/nvme0n1p5` になっていること。ここが `mmcblk0p5` なら SD 用イメージを焼いてしまっている。

### Raspberry Pi OS の SD から書き込む場合

Raspberry Pi OS が入った SD で起動できるなら、上の「準備」「書き込み」の代わりにこちらを使う。**SD 用の kart イメージをビルドする必要がない。**

`remote-flash.sh` は元々「書き込み機を別マシンに繋いで焼く」用途のスクリプトで、Raspberry Pi OS を載せたラズパイはその条件を満たす（`sudo` / `wipefs` / `lsblk` / `findmnt` / `bzcat` が全て揃っている。kart イメージにはこれらが無いため使えない）。

```bash
# 高速化したい場合は先に (任意)
ssh pi@<pi> 'sudo apt install -y bmap-tools'

./scripts/remote-flash.sh -nvme pi@<pi> /dev/nvme0n1 --authkey-file /path/to/tskey
```

イメージと `.bmap` と `flash.sh` を scp し、向こう側で `sudo ./flash.sh` を実行して、終わったら一時ファイルを片付けるところまで自動で行う。`bmaptool` があれば `.bmap` を使って空きブロックを飛ばすため `dd` より速い。`--keep-data` によるデータパーティション保全も本来の設計通り動く。

書き込み後は下の「[NVMe 側の初期設定](#nvme-側の初期設定)」へ進む。ただし Raspberry Pi OS 特有の差分が 3 点ある。

**1. PCIe の有効化が必要な場合がある**

Pi 5 で M.2 HAT の NVMe を見せるには `/boot/firmware/config.txt` に以下が要る。kart 側は `kas/rpi5.yml` の `RPI_EXTRA_CONFIG` で設定済みだが、素の Raspberry Pi OS では既定で入っていないことがある。`lsblk` に `nvme0n1` が出なければここを疑う。

```
dtparam=pciex1
dtparam=pciex1_gen=3
```

**2. EEPROM 設定は手動になる**

`kart-eeprom-setup` は kart イメージにしか入っていない。`rpi-eeprom-config --edit` で `BOOT_ORDER=0xf16` を設定するか、NVMe から起動できるようになった後に kart イメージ側で `kart-eeprom-setup` を実行する（[EEPROM 設定](#raspberry-pi-5-eeprom-設定)）。

**3. Tailscale は auth key の注入のみ**

Raspberry Pi OS 側に kart の tailscaled 状態は存在しないため、[方法 A（状態の移送）](#nvme-側の初期設定)は使えない。`remote-flash.sh --authkey-file` による注入か、[方法 B](#nvme-側の初期設定) を使う。**再利用可能なキーを用意すること。**

> **ラベル衝突は起きない。** Raspberry Pi OS のパーティションラベルは `bootfs` / `rootfs` で、kart 側の `AUTOBOOT` / `BOOTA` / `data` と重ならない。SD を挿したまま NVMe から起動しても誤マウントは発生しないため、抜き忘れによる事故がない点はこちらが有利。

### NVMe 側の初期設定

**この作業を飛ばすと NVMe 起動後にアクセス手段を失う。** tailscaled の状態は `/data/tailscale` に保存されるが、NVMe の `/data` は新規作成されるため引き継がれない。prod イメージは root のパスワードが無効なので、tailnet に入れないと通常の SSH でも入れない。

> **rootfs は read-only なので `/mnt` にマウントポイントを作れない**（`mkdir: cannot create directory: Read-only file system`）。tmpfs の `/run` 配下を使う。

**方法 A: SD 側の tailscaled 状態を移す（推奨）**

すでに tailnet に参加している SD から移行する場合はこちらが確実。認証キーの使い回しに失敗するリスクがなく、同一ノード ID を引き継ぐので ghost node も出ない（`flash.sh --keep-data` と同じ考え方）。

```bash
ssh root@<pi> 'set -e
mkdir -p /run/nvmedata
mount /dev/nvme0n1p7 /run/nvmedata
cp -a /data/tailscale /run/nvmedata/
sync
umount /run/nvmedata && rmdir /run/nvmedata'
```

**方法 B: 認証キーを注入する**

新規デバイスなど、移せる状態がない場合。`p2`（`BOOTA`）に置くと初回起動時に `tailscale-autoconnect.service` が拾う。

```bash
scp /path/to/tskey root@<pi>:/tmp/tskey
ssh root@<pi> 'set -e
mkdir -p /run/nvmeboot
mount /dev/nvme0n1p2 /run/nvmeboot
cp /tmp/tskey /run/nvmeboot/tailscale.authkey
sync
umount /run/nvmeboot && rmdir /run/nvmeboot'
```

SD 側の `/boot/tailscale.authkey` は接続成功時に削除される仕様なので残っていない。**使い捨て（single-use）のキーは既に消費済みで失敗する**ため、再利用可能なキーを使うか新規発行すること。

**アプリの環境変数**

`kmm.service` は `/data/kmm.env`（`p7`）を読む。NVMe 起動後も tailnet 経由で配置できるので、この時点では必須ではない。

```bash
scp .env root@<pi>:/tmp/kmm.env
ssh root@<pi> 'set -e
mkdir -p /run/nvmedata
mount /dev/nvme0n1p7 /run/nvmedata
cp /tmp/kmm.env /run/nvmedata/kmm.env
sync
umount /run/nvmedata && rmdir /run/nvmedata'
```

**EEPROM**

```bash
ssh root@<pi> 'kart-eeprom-setup --check'
```

`EEPROM already configured; nothing to do.` と出れば `BOOT_ORDER=0xf16`（NVMe → SD フォールバック）が入っている。この場合は何もしなくてよい。

差分が表示された場合は新しいボードなので、SD で起動しているこの段階で適用しておく（NVMe に書き込んでも `BOOT_ORDER` が違えば NVMe から起動しない）。**適用後の再起動を挟んでもう一度実行する**必要がある — 詳細は「[Raspberry Pi 5 EEPROM 設定](#raspberry-pi-5-eeprom-設定)」を参照。

```bash
ssh root@<pi> 'kart-eeprom-setup --reboot'   # 適用して再起動
# 起動を待って
ssh root@<pi> 'kart-eeprom-setup'            # 一致確認 + /boot の残骸を掃除
```

### 起動切り替え

```bash
ssh root@<pi> 'poweroff'
```

電源が落ちてから **SD カードを抜いて** 電源を入れる。

> **SD を挿したまま NVMe 起動しないこと。** 両ディスクに `AUTOBOOT` / `BOOTA` / `BOOTB` / `roota` / `rootb` / `data` という同一のラベルが付くため、`/boot`（`kart-boot-mount.service` が `LABEL=BOOTA` でマウント）と `/data`（fstab の `LABEL=data`）がどちらのディスクを掴むか非決定的になる。root はカーネル cmdline が `/dev/nvme0n1p5` と実デバイス指定なので影響を受けない。

> **注意: 一方をビルドすると他方のイメージが消える。** `boot-nvme.yml` と `boot-sdcard.yml` は同じ `kart-image` レシピを同じ TMPDIR で作り直すだけなので、bitbake が前回のデプロイ成果物を削除する。`IMAGE_LINK_NAME` はリンク名を分けるだけで実体は保護されない。両方を手元に置きたい場合は上記のように退避する。`release.sh` は「ビルド → 即アップロード → 次のビルド」の順で回るため影響を受けない。
