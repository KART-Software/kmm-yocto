# 01 — XPI-iMX8MM ハードウェア実測

HW UserGuide(`local/GTC(HF)-HW_UserGuide...pdf`)+ ベンダ [BSP](00-glossary.md#g-bsp) + 実機ログから
確定した事実。**推測ではなく全て一次情報。**

## SoC / メモリ / ストレージ

| 項目 | 値 | 出典 |
|---|---|---|
| SoC | i.MX8M Mini Quad Cortex-A53 @1.8GHz(実動 1.2GHz 起動時) | 実機 [U-Boot](00-glossary.md#g-u-boot) `CPU: Freescale i.MX8MMQ rev1.0` |
| RAM | **2GB** [LPDDR4](00-glossary.md#g-lpddr4)(スペック表の標準 1GB ではなく上位構成だった) | 実機 `DRAM: 2 GiB` |
| [eMMC](00-glossary.md#g-emmc) | Samsung **8GB**(`8GTF4R`)、**[HS400](00-glossary.md#g-hs400) [Enhanced strobe](00-glossary.md#g-enhanced-strobe)** 対応 | 実機 `mmcblk2: 8GTF4R 7.28 GiB` |
| eMMC デバイス | `/dev/mmcblk2`(p1 boot 64MB / p2 8MB / p3 [rootfs](00-glossary.md#g-rootfs) 7.5GB + boot0/boot1/rpmb) | 実機 `/proc/partitions` |
| ブートローダ格納 | eMMC の **boot0 ハードウェアパーティション**(ユーザー領域 33KiB には無い) | ベンダ [uuu.auto](00-glossary.md#g-uuu-auto) の `mmc partconf 1 0`、実機 dd |

**DDR は EVK と同一設定で動く。** ベンダ [SPL](00-glossary.md#g-spl)(2018.03)も自作 SPL(2025.01)も
`DRAM PHY training for 3000/400/100MTS ... Training PASS` で 2GiB を初期化した。
これが移行の最大リスクだったが解消。

## 表示チェーン — LT9611(EVK の ADV7535 ではない)

XPI の HDMI は SoC 内蔵ではなく **[MIPI-DSI](00-glossary.md#g-mipi-dsi) → [LT9611](00-glossary.md#g-lt9611)(Lontium)→ HDMI** のブリッジ経由。
EVK のアダプタカードは ADV7535 なので、ここが最大の [DTS](00-glossary.md#g-dts) 差分。

ベンダ実行中 [DTB](00-glossary.md#g-dtb)(`cat /sys/firmware/fdt` を逆コンパイル)から採取した実配線:

| 項目 | 値 |
|---|---|
| I2C バス | **I2C4**(`i2c@30a50000`)、400kHz |
| I2C アドレス | **0x3b** |
| IRQ | **GPIO1_IO05** |
| RESET | **GPIO1_IO06** |
| ドライバ(ベンダ) | `lt,lt9611`(独自 4.14 ドライバ) |
| ドライバ(mainline) | `lontium,lt9611`(6.12 に正式ドライバあり)→ こちらへ移植 |

実機 4.14 の起動ログでも裏取り: `lt9611_parse_dt: irq_gpio=5 reset_gpio=6`。

## CAN(SPI 経由 MCP2515)

i.MX8M Mini に [CAN](00-glossary.md#g-can) コントローラは無い(FlexCAN は 8M **Plus**)。
RPi と同じく MCP2515 を SPI 接続する前提。ベンダ DTB / HW ガイド 40 ピン表から:

| 項目 | 値 |
|---|---|
| SPI | **ECSPI2**(`ecspi@30830000`)、CS = ECSPI2_SS0 を GPIO5_IO13 |
| ピン(40pin) | pin19=MOSI / pin21=MISO / pin23=SCLK / pin24=SS0(HW ガイド J62 表) |
| ECSPI2 conf 値 | **0x140**(ベンダ実績。EVK 足場の 0x82 から変更) |
| CAN INT | RPi GPIO25 相当 = 物理 **pin22** = **SAI5_RXD3** パッド = **GPIO3_IO24** |

**CAN INT の注意:** EVK 足場では GPIO1_IO08 を暫定使用していたが、XPI の 40 ピンには
その信号が出ていない。RPi の CAN HAT が挿さる pin22(GPIO25)は XPI では SAI5_RXD3
パッドに繋がっており、GPIO モードで GPIO3_IO24。DTS でここに差し替えた。

## Ethernet

| 項目 | 値 |
|---|---|
| [PHY](00-glossary.md#g-phy) | Qualcomm Atheros **AR8031/AR8033**([RGMII](00-glossary.md#g-rgmii)) | 
| MAC(実機個体) | `ac:db:da:69:be:8e`(eeprom 格納、U-Boot が読む) |
| リンク | 1Gbps/Full 実証 |

**自作 U-Boot は MAC を持たない**(ベンダは独自 eeprom パーティションから読む)。
netboot 時は `setenv ethaddr ac:db:da:69:be:8e` を手動設定した。

## ブートモード(BOOT DIP スイッチ S1、8 連)

HW ガイド本文の記述が正:

| モード | S1[1-8] | 用途 |
|---|---|---|
| eMMC ブート | `0110 1010` | 通常(出荷状態) |
| **Serial Download** | `1010 1010`(全体が交互 ON-OFF) | **[UUU](00-glossary.md#g-uuu-universal-update-utility) で [SDP](00-glossary.md#g-sdp) 書き込み** |
| microSD ブート | `0101 0101` | SD |

`ON` 印字側が「1」。Serial Download にすると [BootROM](00-glossary.md#g-bootrom) が USB SDP デバイス
(`1fc9:0134 NXP SE Blank`)として現れ、[UART](00-glossary.md#g-uart) には何も出さない(= 無音が正常)。

## デバッグ UART(J63、4 ピン 2.0mm ピッチ)

40 ピンヘッダとは別の専用コネクタ。**A コア = J63、M コア = J64。**

| J63 | 信号 | [FTDI](00-glossary.md#g-ftdi)/ブリッジ側 |
|---|---|---|
| pin1 | UART2_RXD | ← host TXD |
| pin2 | GND | GND |
| pin3 | UART2_TXD | → host RXD |
| pin4 | NC | |

115200 8N1、3.3V。**コンソールは UART2 = `ttymxc1`**(RPi 互換 pin8/10 の UART1 とは
分離されていて衝突しない良設計)。

> ⚠️ **HW ガイドのピンアサインは実物と食い違いがあった**(ユーザー確認済み)。
> 上表は最終的に UART 出力が取れた実配置。J63/J64 の取り違えや TX/RX の
> クロスは実機で合わせ込む前提。

## 電源

- DC5V/3A、USB-C(J8)。**GPIO 給電(5V ピン直結)でも起動**することを確認
  (kart の RPi5 と同じ流儀)。C-to-C ケーブル + PD 充電器の相性で 5V が
  出ないことがあるので、GPIO 給電か A-to-C が確実。
- [PMIC](00-glossary.md#g-pmic) は **BD71847**(EVK と同一)→ U-Boot の PMIC 初期化がそのまま通る。

## ベンダ配布物の扱い

`local/` に以下がある(gitignore 済み):

| ファイル | 用途 |
|---|---|
| `imx8mm-yocto_RNA200114-xpi_..._20220302194124.tar.gz` | ベンダ製 `.sdcard` イメージ + `uuu.auto` + ベンダ `imx-boot` |
| `imx8mm_xpi_yocto-kernel-uboot-source-20210909.zip` | **パスワード保護(開けない)** |
| HW/SW UserGuide PDF ×3 | 仕様 |

**zip が開けない問題を回避した方法:** ベンダ `.sdcard` イメージの boot パーティション
(FAT)を dd で抜き、その中のコンパイル済み DTB を **バイナリから carve**
(`d00dfeed` マジックを検索)して `dtc -I dtb -O dts` で逆コンパイル。
これで LT9611/ECSPI2/eMMC の実 DTS を暗号化 zip 無しで入手した。手順は
[02-debug-setup.md](02-debug-setup.md) の「ベンダ DTB の抽出」を参照。
