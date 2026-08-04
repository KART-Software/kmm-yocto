# XPI-iMX8MM への移行検討（設計メモ）

2026-08-04 作成。**起動時間短縮を目的とした SoC 変更の実現性検討**。実装判断はまだ下していない。

現行 RPi5 の実測は [boot-timing.md](boot-timing.md) を参照（電源→GUI 8.59s、うちファーム段 7.00s）。

## 結論

**ブート時間は約半分になる見込み。ただし移行コストが大きく、CAN と NVMe で設計変更が必要。**

| | RPi 5（実測） | XPI-iMX8MM（見積） |
|---|---|---|
| ブートローダ段 | 7.00s | **1.9s**（U-Boot 最適化済み）/ さらに Falcon Mode で短縮余地 |
| カーネル | 0.70s | ~0.9s |
| userspace → GUI | 0.89s | ~1.3〜2.0s（推定） |
| **合計** | **8.59s** | **~4.1〜4.8s** |

ブートローダ段で 5.1 秒稼ぐが、CPU が弱くなる分 userspace で 0.4〜1.1 秒失う。差し引き **4 秒前後の短縮**。

## 根拠となる数値

### 現行 RPi5 のファーム段が削れない理由

Pi5 のブートローダは VPU 上で動く署名検証付きクローズド実装で置換不可。11 ブートの実測で
内訳は EEPROM ロード 1.65s / SDRAM トレーニング 1.83s / RP1 ファーム 0.67s / PCIe 0.63s /
DTB+overlay+EDID 1.11s / カーネル読込 0.50s。設定ノブは総当たりで検証済みだが
`force_eeprom_read=0`・`disable_poe_fan=1`・`hdmi_ignore_edid`・`NET_INSTALL_ENABLED=0` は
**全て ±0**（[research ログ §14](boot-optimization-research.md)）。

### i.MX8M Mini のブートローダ段

Embedded Artists が iMX8M Mini uCOM で公開している実測値
（[Optimization - iMX8M Mini uCOM](https://developer.embeddedartists.com/docs-app/guides/boot-times/optimization-imx8-mini/)）:

| チェックポイント | 未最適化 | 最適化後 | 削減 |
|---|---|---|---|
| U-Boot: Starting kernel | 2959ms | **1896ms** | 1063ms |
| Linux: Init process | 6084ms | 2802ms | 3282ms |
| Linux: Basic service | 8021ms | 3583ms | 4438ms |
| Linux: Login prompt | 10459ms | 4927ms | 5532ms |

個別の効果: U-Boot の boot delay 削除 ~2s / カーネル `quiet` ~3.3s /
bootcmd 簡素化 ~200ms / I2C 100→400kHz ~350ms / U-Boot 機能削減 ~480ms /
カーネルのペリフェラル削減 ~130ms。

**この 1896ms は通常の U-Boot 経路での値。** さらに Falcon Mode（SPL が U-Boot 本体を
飛ばしてカーネルを直接起動）を使えば短縮余地がある。NXP は公式レイヤ
[meta-imx-fastboot](https://github.com/nxp-imx-support/meta-imx-fastboot) を提供しており、
i.MX 8M Mini を含む 8M ファミリと i.MX 9 ファミリに対応、Falcon Mode v1/v2 を実装している。
対応ブランチはカーネル 6.6.23 / 6.6.36 / 6.6.52 / 6.12.20。詳細は AN14093
（[Fast Boot on i.MX 8M and i.MX 9 Using Falcon Mode and Kernel](https://community.nxp.com/pwmxy87654/attachments/pwmxy87654/imx-processors/232126/1/AN14093.pdf)）、
および AN13709（[Linux Boot Time Optimizations for i.MX8M Family](https://www.nxp.com/docs/en/application-note/AN13709.pdf)）。

> **注意**: `meta-imx-fastboot` が謳う「DDR Quickboot（DDR トレーニング結果をブートデバイスに
> 保存して再利用）」は **i.MX 95 向けの機能**として記載されており、8M Mini に適用できるとは
> 書かれていない。Pi5 の SDRAM トレーニング 1.83s に相当する削減が 8M Mini でも効くかは未確認。

### userspace の見積もりは推定である

上表の Linux 側の値は login prompt までのもので、**weston + Qt6 GUI 到達ではない**。
現行 RPi5 の userspace→GUI 0.886s は Cortex-A76 2.4GHz での値で、A53 1.8GHz では
シングルスレッド性能が 2 倍前後落ちる。GPU も VideoCore VII → GC NanoUltra と大幅に弱くなる。
1.3〜2.0s というレンジは実測ではなく構造からの推定。**移行判断の前に実機で測るべき数値。**

## ハードウェア制約からの設計変更点

出典: [Geniatech XPI-iMX8MM 製品ページ](https://www.geniatech.com/product/xpi-imx8mm/)、
[NXP i.MX 8M Mini Fact Sheet](https://www.nxp.com/docs/en/fact-sheet/IMX8MMINIFS.pdf)

### 1. CAN — SoC に CAN コントローラが無い（重要）

**i.MX 8M Mini には FlexCAN が搭載されていない。** CAN FD を内蔵するのは i.MX 8M **Plus** の方。
8M Mini のコネクティビティは 1x GbE / 2x USB2.0 OTG / 1x PCIe 2.0 (1-lane) /
4x UART / 4x I2C / 3x ECSPI で、CAN は含まれない。

→ **現行と同じく MCP2515 を SPI 接続で使い続ける。** SoC 内蔵化による改善は無い。
ECSPI が 3 系統あるので接続自体は問題ない。

ただし device tree の作り方が変わる。現在は meta-raspberrypi の変数で設定している:

```
ENABLE_SPI_BUS = "1"
ENABLE_CAN = "1"
CAN_OSCILLATOR = "12000000"
CAN0_INTERRUPT_PIN = "25"
```

これらは RPi 固有の overlay 機構に依存しているため、**i.MX では自前の DTS ノードを書く**ことになる。

### 2. ストレージ — PCIe/NVMe が無い

XPI-iMX8MM のストレージは **eMMC 5.1（8〜128GB オプション）+ microSD**。
SoC は PCIe 2.0 x1 を持つが、**ボードには M.2/PCIe が引き出されていない**。

→ eMMC ブートに変更。影響範囲:

- `meta-kart/wic/*.wks` を全面書き直し（`--ondisk nvme0n1` → `mmcblk0` 等）
- `CMDLINE_ROOT_PARTITION` の変更
- `kas/boot-nvme.yml` / `boot-sdcard.yml` の再定義
- `scripts/flash.sh` / `remote-flash.sh` の `-nvme` 経路の作り直し
- 現行の「SD で起動して NVMe に書く」運用（README）は不要になる。
  eMMC への初期書き込みは **UUU（NXP の USB ダウンロードツール）** 経由が標準的で、
  USB-C から直接書ける。運用としてはむしろ簡単になる

### 3. ディスプレイ — HDMI はブリッジ経由

**i.MX 8M Mini に HDMI IP は無い。** SoC が持つのは MIPI-DSI（4 lane）と MIPI-CSI（4 lane）。
XPI ボードは「HDMI v1.4 Type A」を備えるが、これは **DSI→HDMI ブリッジ IC 経由**
（ADV7535 系が一般的）。ボードは MIPI-DSI/CSI を 2 lane で引き出している。

→ 影響:

- weston の DRM/EGL 初期化パスが変わる。現行の `weston.ini` 設定と kiosk 構成は
  作り直しではないが再検証が必要
- **EDID の扱いが変わる。** Pi5 では `DISABLE_HDMI=1` でも EDID 読取りが走り
  約 0.3 秒使っていたが、ブリッジ経由では挙動が異なる
- HDMI 未接続時の weston の振る舞い（現状は即終了 → `Requires=` でアプリも起動しない）は
  再確認が必要
- MIPI-DSI パネル直結に切り替えれば、ブリッジ分のレイテンシと部品を削減できる。
  ディスプレイの接続方式は README の「未確定事項」に残っているので、
  **この機会に DSI 直結を選ぶ価値がある**

### 4. RAM

標準 1GB、1〜4GB オプション。現行イメージは軽量（1648 パッケージ、rootfs 1.5GB スロット）だが、
Qt6 + weston + tailscale を動かすなら **2GB 以上を選定すべき**。

## A/B OTA の再設計

**現行の A/B は Pi5 ファームウェアの `tryboot` 機構に完全依存しており、そのまま持ち込めない。**

現行:
- p1 AUTOBOOT に `autoboot.txt`（`tryboot_a_b=1` / `boot_partition=2` / `[tryboot] boot_partition=3`）
- `reboot '0 tryboot'` で一度だけ B 面起動
- `kart-ab-commit` が両セクションを入れ替えて確定
- 失敗時はファームウェアが自動フォールバック

i.MX + U-Boot での等価物:

| 機能 | U-Boot での実現 |
|---|---|
| 一度だけ別スロットで起動 | `bootcount` + `bootlimit` + `altbootcmd` |
| 失敗時の自動フォールバック | `bootcount` が `bootlimit` を超えると `altbootcmd` に切替 |
| 確定（commit） | 起動成功後に userspace から `fw_setenv bootcount 0` |
| スロット選択の永続化 | U-Boot 環境変数（eMMC の専用領域 or FAT 上のファイル） |

`kart-ab-commit` / `kart-ab-status` / `scripts/ota-update.sh` は
**`fw_setenv`/`fw_printenv`（libubootenv）ベースに書き直し**。
eMMC の boot partition（`mmcblk0boot0` / `boot1`）を A/B のブートローダ面として使える点は
Pi5 より素直。ハードウェアウォッチドッグによる保険は現行の
`RuntimeWatchdogSec=15` をそのまま流用できる。

機能的には U-Boot 側の方が素直で、実装後の保守性はむしろ改善する見込み。
ただし **作り直しの工数は小さくない**（現行は wic レイアウト・systemd ユニット・
デバイス側スクリプト・ホスト側スクリプトにまたがっている）。

## Yocto 構成の変更

| 現行 | 移行後 |
|---|---|
| `meta-raspberrypi` | `meta-freescale` + `meta-freescale-3rdparty` or NXP `meta-imx` |
| `MACHINE = "raspberrypi5"` | ボード固有 machine（Geniatech BSP 依存） |
| `recipes-kernel/linux/linux-raspberrypi_%.bbappend` | `linux-imx` 系 bbappend に置換 |
| `rpi-eeprom` / `kart-eeprom-setup` | 不要（U-Boot 環境変数へ） |
| `RPI_EXTRA_CONFIG` / `ENABLE_*` 変数群 | 自前 DTS + U-Boot config |
| `BBFILES_DYNAMIC` の `raspberrypi:` 条件 | 条件の張り替え |

**そのまま流用できるもの**（移行コストが低い部分）:

- `kart-machine-manager` レシピ — Qt6 の C++ アプリなのでクロス再ビルドのみ。ソース変更不要
- `tailscale` レシピ — prebuilt arm64 バイナリなので変更なし
- `weston-init.bbappend` / `weston.ini` — kiosk 構成の考え方は同じ（DRM 周りは要再検証）
- systemd 最適化の大半 — timesyncd / resolved の遅延、SSH ホスト鍵の事前生成、
  journal catalog マスク、`wait-online --any`、`SYSTEMD_DEFAULT_MOUNT_RATE_LIMIT_BURST=100`。
  これらは SoC 非依存
- `/data` パーティション運用、`kmm.env` の仕組み、read-only rootfs

## リスクと未確認事項

1. **Geniatech の BSP の入手性と品質が最大のリスク。** Yocto BSP・カーネル・U-Boot ソースは
   [ダウンロードページ](https://www.geniatech.com/download/xpi-imx8mm-yocto/)がフォーム経由で、
   **公開 git リポジトリや meta レイヤ名が確認できない**。Yocto のバージョン、
   カーネル/U-Boot のバージョン、scarthgap 対応の有無、更新頻度はいずれも未確認。
   ベンダ BSP が古い Yocto に固定されている場合、現行の scarthgap 構成を捨てることになる
2. **userspace→GUI の実測が無い。** A53 + GC NanoUltra での weston + Qt6 起動時間は
   推定に留まる。ここが 2.5s を超えると全体の優位が薄れる
3. **Falcon Mode が実用に耐えるか。** SPL がカーネルを直接起動するため、
   U-Boot のデバッグ機能・環境変数操作が使えなくなる。A/B の切替を SPL 段でどう実装するかは
   AN14093 を読み込む必要がある。Falcon と A/B の両立は自明ではない
4. **DDR トレーニング時間。** Pi5 では 1.83s を占めていた。8M Mini での実測値と、
   短縮手段（DDR Quickboot 相当）が使えるかは未確認
5. **MCP2515 HAT の互換性。** 40 ピンヘッダは RPi 互換配置だが、
   SPI の CS/割り込み GPIO の番号と DTS 記述は作り直し。HAT の電気的互換性も要確認
6. **供給・EOL・調達性** — 製品ライフサイクル、入手性、価格は未調査

## 実装状況（2026-08-04）

**フェーズ 1 の足場を実装済み**（このブランチ）。XPI の BSP が未入手のため、同一 SoC の
公開マシン `imx8mm-lpddr4-evk`（meta-freescale scarthgap、mainline BSP =
linux-fslc + etnaviv）をターゲットにしている。実機 BSP 入手後は
`kas/imx8mm.yml` の machine とレイヤを差し替える。

- `kas/imx8mm.yml` — machine + meta-freescale + `ACCEPT_FSL_EULA`
- `kas/imx8mm-dev.yml` — base + imx8mm + debug-tweaks（`./scripts/build.sh imx8mm`）
- `meta-kart/recipes-kernel-imx/` — linux-fslc / linux-fslc-imx 両対応の
  can.cfg bbappend（`BBFILES_DYNAMIC` で meta-freescale 存在時のみロード）
- `kart-image.bb` — `:mx8mm-generic-bsp` オーバーライドで can-utils / can-setup /
  kernel-modules を追加。tryboot 専用機構（autoboot.vfat 生成、
  kart-boot-mount）は `:raspberrypi5` にガードして他マシンから除外。
  **落とし穴**: meta-freescale は machine-overrides-extender で MACHINEOVERRIDES
  を BSP 種別付き（`mx8mm-generic-bsp` / `mx8mm-mainline-bsp` 等）に変換するため、
  素の `:mx8mm` は OVERRIDES に存在せず append が黙って捨てられる（変数履歴には
  載るのに値に反映されない）。実際にこれを踏んで wic 生成が失敗した
- `imx8mm-evk-kart.dts` — MCP2515 + eMMC ノード入りの EVK バリアント DTB。
  **eMMC (usdhc3) は mainline の EVK DT に存在しない**（microSD のみ）ため、
  NXP ベンダツリー (lf-6.6.y) の usdhc3 ノードを移植した。/dev/mmcblk2 で見える。
  RPi5 ではファームウェアオーバーレイ（`ENABLE_CAN=1` → mcp2515-can0）が
  やっていたことを DTB に焼き込む。**ピン割り当ては暫定**
  （ECSPI2 専用パッド + CS=GPIO5_IO13 + INT=GPIO1_IO08、発振子 12MHz）。
  `IMAGE_BOOT_FILES` の rename 機能でストック名 `imx8mm-evk.dtb` として
  ブートパーティションに置き、U-Boot の fdtfile デフォルトのまま選ばせる

**ビルド検証済み（2026-08-04）**: 6418 タスク全成功。wic (p1 boot 256M + p2 rootfs
678M、シングルスロット) がデプロイされ、DTB に mcp2515 / usdhc3 / can-osc ノードを
確認。マニフェスト 1605 パッケージに kmm 2.0 / weston / qtbase / qtwayland /
can-utils / kernel-module-mcp251x / tailscale を確認。U-Boot は extlinux 経由で
`FDT ../imx8mm-evk.dtb` を読むため、IMAGE_BOOT_FILES の rename 方式が成立している。

**未実装**: A/B ブート（U-Boot bootcount）、eMMC 用 wks
（現状は machine デフォルトの wks を使用）、Falcon Mode。
XPI 実機では DTS のピン参照（ECSPI インスタンス / INT GPIO）の差し替えが必要。

**実機で要確認**: extlinux.conf の APPEND に `rw` が入る（RPi5 の cmdline には
無かった）。read-only-rootfs 機能が systemd 側で ro を強制するかは EVK 実機の
初回起動で `/proc/mounts` を確認すること。

## 進め方の提案

移行判断の前に、**安く早く潰せる不確実性から潰す**。

1. **Geniatech に BSP の詳細を問い合わせる** — Yocto バージョン、meta レイヤの入手形態、
   git の有無、scarthgap 対応。ここが致命的なら以降は不要
2. **評価ボードを 1 枚買って `boot-timing.md` と同じ計測をする** — 特に userspace→GUI。
   UART 計測の手順は今回確立済みなので、そのまま適用できる
3. **並行して、移行しない場合の体感改善を検討する** — research ログが未実施として
   挙げているブートスプラッシュは「実速度は不変だが画面に反応が出るまでを ~6s にできる」
   体感対策で、移行コストゼロ。またモニタ同期（~2.2s）はボードを変えても減らない。
   **体感の遅さの原因が本当に OS の起動時間なのかを先に切り分ける価値がある**

## 参考資料

- [Geniatech XPI-iMX8MM 製品ページ](https://www.geniatech.com/product/xpi-imx8mm/)
- [Geniatech XPI-iMX8MM Yocto / kernel / U-Boot ソース（要フォーム）](https://www.geniatech.com/download/xpi-imx8mm-yocto/)
- [NXP i.MX 8M Mini Fact Sheet](https://www.nxp.com/docs/en/fact-sheet/IMX8MMINIFS.pdf)
- [NXP AN13709: Linux Boot Time Optimizations for i.MX8M Family](https://www.nxp.com/docs/en/application-note/AN13709.pdf)
- [NXP AN14093: Fast Boot on i.MX 8M and i.MX 9 Using Falcon Mode and Kernel](https://community.nxp.com/pwmxy87654/attachments/pwmxy87654/imx-processors/232126/1/AN14093.pdf)
- [NXP meta-imx-fastboot（Falcon Mode Yocto レイヤ）](https://github.com/nxp-imx-support/meta-imx-fastboot)
- [Embedded Artists: Boot time optimization - iMX8M Mini uCOM](https://developer.embeddedartists.com/docs-app/guides/boot-times/optimization-imx8-mini/)
- [Embedded Artists: iMX 6/7/8 Boot time and optimization (PDF)](https://www.embeddedartists.com/wp-content/uploads/2020/11/iMX_Boot_Times.pdf)
- [CNX Software: Geniatech XPI-iMX8MM SBC](https://www.cnx-software.com/2021/09/03/geniatech-xpi-imx8mm-sbc-offers-nxp-i-mx-8m-mini-processor-in-raspberry-pi-form-factor/)
