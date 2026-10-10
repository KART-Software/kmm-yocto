# 1. PC の用意とビルド

## PC の用意

- Ubuntu 22.04 以降(WSL2 も可)、Docker、kas-container
- 初回ビルドは 50GB 以上の空きが要る
- 実機への最初の書き込みと復旧に NXP の `uuu`(mfgtools)
- NXP EULA への同意が要る。`imx-boot` に入る DDR トレーニングのファーム(firmware-imx)が
  EULA で配布されているため。`kas/imx8mm.yml` / `kas/imx8mp.yml` に `ACCEPT_FSL_EULA = "1"` を
  設定済み

```bash
sudo apt install -y docker.io e2fsprogs uuu    # uuu は apt か mfgtools のリリースから
pipx install kas                               # または: uv tool install kas
sudo usermod -aG docker,dialout,plugdev $USER  # 反映には再ログイン
```

## build.sh(開発用イメージ)

```bash
./scripts/build.sh imx8mp --emmc            # DEBIX の開発用イメージ、eMMC A/B
./scripts/build.sh imx8mp --emmc --falcon   # DEBIX の製品ブート(Falcon + SPL スプラッシュ、M7 なし)
./scripts/build.sh imx8mm --emmc            # XPI の eMMC A/B
./scripts/build.sh imx8mm --emmc --falcon   # XPI の製品ブート(Falcon + スプラッシュ、M4 なし)
./scripts/build.sh imx8mm --netboot         # XPI の TFTP/NFS ネットブート(DTS やドライバの試行用)
```

`imx8mm` / `imx8mp` は開発用(debug-tweaks 入り)。`--emmc` で eMMC の A/B レイアウト、
`--falcon` で Falcon Mode と SPL スプラッシュを足す。M コアの CAN ゲートウェイは別の
オーバーレイなので、次の直接指定で足す。

## 製品構成(kas を直接呼ぶ)

YAML を `:` でつなぐと左から順に重なる。**先にキャッシュの場所を export する**:

```bash
export DL_DIR=$PWD/downloads SSTATE_DIR=$PWD/sstate-cache

# DEBIX: 開発用 + eMMC A/B + Falcon + スプラッシュ + M7 の CAN
kas-container build \
  kas/imx8mp-dev.yml:kas/imx-emmc-ab.yml:kas/imx8mp-falcon.yml:kas/imx8mp-splash.yml:kas/imx8mp-m7.yml

# XPI: 製品(Tailscale SSH のみ、debug-tweaks なし)+ eMMC A/B + Falcon + スプラッシュ + M4 の CAN
kas-container build \
  kas/imx8mm-prod.yml:kas/imx8mm-emmc-ab.yml:kas/imx8mm-falcon.yml:kas/imx8mm-splash.yml:kas/imx8mm-m4.yml
```

- `DL_DIR` / `SSTATE_DIR` を export しないと、`base.yml` の既定値がコンテナ内の
  `TOPDIR=/build` を基準に解決され、`Failed to create a file in SSTATE_DIR: Permission denied`
  で止まる。キャッシュは `build/` の外に置いてあるので、`rm -rf build` しても消えない
- 8MP には `imx8mm-prod.yml` に相当する prod 構成がまだ無い。ベンチは開発用で動いている

## 成果物

`build/tmp/deploy/images/imx8mp-debix/`(XPI は `imx8mm-xpi/`)に出る。

| ファイル | 使い道 |
|---|---|
| `kart-image-<machine>-emmc.wic.bz2` | eMMC 全体のイメージ。最初の書き込み(2)と Linux の更新(4) |
| `imx-boot` | SPL のイメージ。`ab spl update`(4) |
| `m7-fw.img`(8MP)/ `m4-fw.img`(8MM) | M コアのファーム。8MP は `ab mcore update`(3、4)。8MM はイメージの BOOT に入る |

## 層の版の固定

`kas/imx8mp-dev.lock.yml` と `kas/imx8mm-dev.lock.yml` が poky / meta-openembedded / meta-qt6 /
meta-freescale を特定のコミットに固定する。kas は構成ファイルの隣にある lock を自動で使う。
意図して上げたときは、別の名前に出してから置き換える(kas が自動で読む名前と衝突させない):

```bash
kas-container dump --lock --update <構成> > /tmp/x && mv /tmp/x kas/<構成>.lock.yml
```

## kas の構成ファイル

| ファイル | 種類 | 中身 |
|------|------|------|
| `base.yml` | 土台 | 上流のリポジトリ、distro features、DL/SSTATE、rm_work |
| `imx8mp.yml` / `imx8mm.yml` | 機種 | machine + meta-freescale + NXP EULA |
| `imx8mp-dev.yml` | 組み合わせ | base + imx8mp + debug-tweaks |
| `imx8mm-dev.yml` / `imx8mm-prod.yml` | 組み合わせ | base + imx8mm(prod は debug-tweaks なし) |
| `imx-emmc-ab.yml` | 断片 | 8MM/8MP 共通の eMMC A/B の WKS 選択(実体は machine の `EMMC_AB_WKS`) |
| `imx8mm-emmc-ab.yml` | 断片 | 8MM 専用の旧 A/B WKS |
| `imx8mp-falcon.yml` / `imx8mm-falcon.yml` | オーバーレイ | SPL がカーネルを直接起動(`falcon.itb`) |
| `imx8mp-splash.yml` / `imx8mm-splash.yml` | オーバーレイ | SPL スプラッシュ(**falcon の後ろに置く**) |
| `imx8mp-m7.yml` / `imx8mm-m4.yml` | オーバーレイ | M コアの CAN ゲートウェイ(`rpmsgcan0`)と falcon 統合 |
| `imx8mm-netboot.yml` | オーバーレイ | TFTP/NFS root(bring-up 用) |
| `sdk.yml` | 補助 | Qt の SDK を qtbase だけに絞る(5) |
| `rpi5*.yml` / `boot-*.yml` / `qemu*.yml` | 旧 | RPi5・QEMU |

アプリ(kart-machine-manager の C++ 版)は常にイメージに入る。レシピ
`meta-kart/recipes-app/kmm/kmm_2.0.bb` が GitHub から決めた `SRCREV` で取ってきてクロスビルドする(5)。
