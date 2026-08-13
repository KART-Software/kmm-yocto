# 07 — ベンダ BSP 監査(現状構成との照合結果)

Geniatech 公式 BSP `imx8mm_xpi_yocto-kernel-uboot-source-20210909.zip`
(解凍パスワード `20210909`、`local/vendor-bsp/` に展開。NXP
`4.14.98_2.0.0_ga` ベース、U-Boot 2018.03 + kernel 4.14.98)を精査し、
現行構成(u-boot-fslc 2025.01 + mainline 系 kernel + 自作 XPI DTS)と
照合した記録(2026-08-12 実施)。

照合元: `geniatech/{uboot-source,kernel-source}` +
`loong/devices/xwayland-imx8mmevk-xpi/`(XPI 個体別 override。出荷版と
バイト一致することを確認済み)+ 実機から吸い出した逆コンパイル DTB
(`local/vendor-dtbs/running.dts`、こちらが最終の ground truth)。
ベンダ git 履歴は骨抜き(objects 無し)のため、NXP 公式タグとの
バイト比較で改造分を切り出した。

## 結論サマリ

| 項目 | 結果 |
|------|------|
| SPL の DDR タイミング | **一致 — 解消**。ベンダ 2GB 用 = NXP 純正 EVK 値そのまま。fslc 2025.01 は同一スクリプトの NXP 公式再生成版 |
| LT9611 電源シーケンス | **常時給電で確定 — 解消**。制御可能なレールは存在せず、regulator-fixed ダミーが正しいモデル |
| CAN が ecspi2 | **裏取り成功**。ecspi2 = 40 ピンの RPi 互換 SPI(ベンダは spidev)。ecspi1 は disabled |
| CAN INT = GPIO3_IO24 | **解消 (2026-08-13)**。HAT 装着で CAN 実受信を確認(受信は割り込み駆動のみ = INT 配線正当の実証) |
| eMMC (usdhc3) 設定 | 完全一致(8bit / 400MHz / パッド値まで) |
| Ethernet PHY リセット | **食い違い発見** — 実機は GPIO4_IO1、うちの継承 DT は GPIO4_IO22 を空撃ち |

## 1. DDR タイミング(未確認前提 → 解消)

- ベンダの 2GB 用 `lpddr4_timing.c` は **NXP `rel_imx_4.14.98_2.0.0_ga`
  の EVK ファイルとバイト一致**(Geniatech は 2GB 向けに再生成していない)。
- 現行 fslc 2025.01 の同ファイルは NXP 自身による同スクリプトの後年再生成
  (`cf16dc3329` "sync with v2020.04")。レジスタ照合の結果、
  ddrc 103 / phy 200 / trained_csr 719 / pie 592 レジスタ**全一致**。
  差分は訓練 FW メッセージ語 `{0x5400d, 0x100}` 1 個のみ(NXP 自身が廃止した
  語。タイミングレジスタではない)。setpoint も 3000/400/100 MTS で同一。
- **ただし 1GB 版 XPI は別物**: 出荷 defconfig は `CONFIG_IMX8M_LPDDR4_1GB=y`
  で、Longsys `LTHS0055GS4-ZPJ1` 用に再生成された
  `lpddr4_timing_1gb.c` を使う(RFSHTMG/ADDRMAP6 等 11 レジスタが相違、
  EVK 値では動かない)。**1GB 個体を扱う日が来たらこのファイルを
  fslc へ移植する**こと。手元の 2GB 個体は EVK 値で training PASS 実測済み。

## 2. LT9611(未確認前提 → 解消)

- ベンダ DT(ソース・実機 DTB とも)は LT9611 に **supply/regulator を
  一切与えていない** — VDD/VCC は基板の常時レール直結。ドライバ側の
  regulator 機構は全て dead code。→ **mainline binding の vdd/vcc を
  regulator-fixed ダミーで満たす現行構成は正解**
- 配線一致確認: i2c4 @0x3b / reset GPIO1_IO6 / IRQ GPIO1_IO5(edge-falling)/
  pinctrl 0x19 — 全て現行 DTS と一致
- リセット後の settle: ベンダも同一構造点で `msleep(500)` を使うが、
  読み戻し検証なしの盲目待ちで、PLL ロック自体はスリープ無しの
  ポーリングで済んでいる → **500ms は過剰保守の継承であり、うちの
  100ms 短縮パッチ(0003)と矛盾する証拠は無し**(実機検証が最終根拠)
- EDID: ベンダは DDC 読取(ブロック毎 5-10ms wait)+ `lt,preferred-mode`
  強制。**DDC バイパス用の fixed-mode 機構(`lt,non-pluggable`)も
  ベンダ自身が用意しており(XPI DTS にコメントアウト済み設定が現存)、
  うちの firmware-EDID 方式はその mainline 流儀版**
- 解像度毎の DSI レーン数切替(1080p60=4 / 低解像度=2-3)をベンダも実装 —
  うちの 0002 パッチ(dsi lanes from DT)の設計動機を裏付け

## 3. DTS 配線照合(ソース vs 実機 DTB vs 現行)

一致確認済み: LT9611 一式 / eMMC usdhc3(8bit, 400MHz, パッド値)/
i2c4 パッド / Ethernet PHY 種別(AR803x @0, rgmii-id)/ usbotg1 host。
CAN 用 MCP2515 はカート側アドオンでありベンダ DT には存在しない
(ecspi2 に spidev "rpispi" @12MHz、cs=GPIO5_IO13 — 40 ピン互換 SPI の
裏付け)。`pinctrl_ecspi1_mcp2515t`(GPIO1_IO13)は**どこからも参照されない
死に定義**で、別製品向けの残骸。

**発見した食い違い・欠落(採用候補、優先順。1/2/4 は 2026-08-12 に適用・
実機検証・commit 済み。3 は適用したがチップ無応答 — 各項の追記参照):**

1. **Ethernet PHY リセット**: 実機は SAI1_RXC→**GPIO4_IO1**。継承中の
   EVK dtsi は SAI2_RXC→GPIO4_IO22 を reset-gpios に指定しており
   **実 PHY をリセットしていない**(空きパッドの空撃ちで無害だが無意味)。
   採用: `ethphy0` の `reset-gpios = <&gpio4 1 GPIO_ACTIVE_LOW>` +
   fec1 ピングループ差し替え。ウォームリセット時の PHY 復旧が本物になる
2. **usbotg2 が丸ごと欠落**: 実機 DTB は OTG1/OTG2 とも host で有効。
   mainline evk dtsi に usbotg2 ノードが無いため現行イメージでは死んでいる。
   採用: `&usbotg2 { dr_mode = "host"; status = "okay"; };`
   **実測追記 (2026-08-12)**: 有効化したところ usb2 バスにハブ経由で
   **Marvell Wireless Device (1286:2045) = 基板搭載 WiFi/BT モジュール
   (88W8897、ベンダカーネルの MRVL8897U ドライバと符合) が出現**。
   usbotg2 は外部ポートではなく板載 WiFi の接続先だった。カートでは
   WiFi 不使用のため放置で無害 (mainline mwifiex_usb が 8897 対応なので
   使いたければ有効化余地あり)。
   実物照合 (訂正あり): **Marvell 88W8897 の実体は表面ヘッダーに縦挿しの
   メザニン基板**(チップ刻印 88W8897M-NMJ2 を実機写真で確認。ヘッダーに
   直はんだの恒久実装 — 引き抜き不可、無理に引っ張らないこと)。
   当初この役を疑った**裏面 U407**(キャステレーション端子・シルク RN… V1.1・
   サーマルグリス)は**正体未特定のまま** — 候補は DC-DC 電源モジュール /
   Broadcom SDIO 無線 (実機 DTB の brcm,bcm4329-fmac@usdhc1 の実体候補だが
   シールド缶なしが不自然) / サウンドバー変種向けモジュール。確定には
   グリス下のシルク読取か usdhc1 有効化ビルドでの SDIO enumerate 確認。
   Geniatech 基板コード系: 本機 RNA200114-xpi、兄弟変種に soundbar/
   gumstick/db11/gtw810/smarc (loong/devices/)。
   **最終判断 (2026-08-12)**: usbotg2 配下はハブ + この WiFi モジュールのみで
   外部ポートが無いことが確定したため、**usbotg2 は意図的に disabled へ戻した**
   (カートは WiFi/BT 不使用。モジュール物理撤去はパターン損傷リスクが高く
   却下。使う日が来たら host 有効化 + mwifiex_usb)
3. **RTC AM1805 @ i2c2 0x69**(電池バックアップ、ベンダは専用ドライバ):
   現行 DTS にノード無し。mainline は `rtc-abx80x`(`abracon,ab1805`)で
   対応可能。**起動時に有効な時刻が手に入る = timesyncd 遅延設計にも効く**。
   注意: このチップは HW ウォッチドッグを内蔵し、**ベンダ U-Boot は毎起動
   board_late_init で reg 0x1B に書いて無効化していた**(imx8mm_evk.c:772-801)。
   現行構成は何もしていないが実害は出ていない(工場出荷で未アーム)。
   RTC を有効化するならウォッチドッグ状態も確認すること。
   **実測追記 (2026-08-12)**: ノード + `CONFIG_RTC_DRV_ABX80X` を適用したが
   probe は常時 `-EIO` ("Unable to read partnumber")。ドライバ再バインドでも
   同じ。ベンダ時代の起動ログは現存せず、この個体で AM1805 が動いていた証拠は
   無い — **チップ未実装 (実装オプション) が濃厚**。ベンダ DT の status okay は
   複数実装バリアント共用 DT の名残とみられる。**不在確定を受けて DT ノードと
   `CONFIG_RTC_DRV_ABX80X` は撤去した**(カーネルスリム化方針と整合)。
   実装個体を扱う日が来たら: i2c2 に
   `rtc@69 { compatible = "abracon,ab1805"; reg = <0x69>; };` +
   `CONFIG_RTC_DRV_ABX80X=y` の 2 点で復活する。バックアップ電池の
   有無という問いはチップ不在のため無意味化。
   実物調査 (基板目視 + 配置図 RNA210114 V1.0): 裏面の空きランド U7 は
   AM1805 では**ない**(隣接 Y3 は 27.000MHz 実装済み = TC35874x 系 HDMI-RX
   実装オプションの構成。RTC なら 32.768kHz のはず)。AM1805 用ランドは
   未発見で、**この基板 rev にはフットプリント自体が無い可能性もある**
4. **PMIC の compatible 不一致**: 実チップは `rohm,bd71837`(8 buck)。
   継承 dtsi は `rohm,bd71847`(6 buck)として登録しており、レギュレータ
   マップが実チップとズレている。buck2/DVS 値は同一なので起動には無害だが、
   **cpufreq/DVS/suspend を信頼する前に bd71837 + ベンダのレギュレータ定義へ
   差し替える**のが安全
5. 小物: ステータス LED GPIO3_IO16(現行は意図的に削除済み・一致)、
   PCIe を使う日は reset=GPIO4_IO0 / clkreq=GPIO5_IO20 / ext_osc=1
   (EVK 値と全く異なる。`reg_pcie0` 無効化は正解 — gpio1 5 は LT9611 IRQ)。
   新しめの HW rev には SDIO WiFi(BCM43xx)+ BT(uart1) が載る個体もある
   (実機 DTB にのみ存在。うちの個体は USB Marvell 8897 世代とも別)

## 4. boot0 ベンダローダの挙動(リカバリ時の契約)

出荷 defconfig `imx8mm_evk_defconfig`(fastboot 有効、UMS あり、bootdelay 2s)。
ブートフロー: `mmc rescan → boot.scr(FAT p1) → 無ければ Image +
fsl-imx8mm-ddr4-evk.dtb + root=/dev/mmcblk2p3`。

- **リカバリフック**: ベンダローダは eMMC p1 の FAT から `boot.scr` を
  最優先実行する。うちの p1 = BOOTA(FAT)なので、**BOOTA に boot.scr を
  置けば partconf 1(ベンダ復帰)状態からでもうちのシステムを起動できる**。
  boot.scr 無しだと Image は見つかるが DTB 名(`fsl-imx8mm-ddr4-evk.dtb`)が
  無くて fdt で止まる → netboot に落ちる
- **env 衝突(要注意、[04-pitfalls](04-pitfalls.md) #20)**: ベンダローダの
  env は eMMC の **4MiB オフセット**(size 0x1000) — **kart env と同一位置**
  (`fw_env.config`: 0x400000, size 0x2000)。ベンダローダで `saveenv` すると
  kart_slot/A/B 状態が破壊される。ベンダ復帰中は saveenv 禁止。壊したら
  kart-env.bin を書き戻す(wic 再 dd か ums で該当領域だけ dd)
- AM1805 ウォッチドッグ無効化もこのローダの毎起動処理(上記 §3-3)

## 5. 現代カーネルでのデバッグ用ヒント(ベンダが踏んだ地雷の痕跡)

- **MCP2515 の発振子安定待ち**: ベンダは mcp251x の OST 遅延を 5ms→**20ms** に
  パッチしていた。CAN の初期化が稀に失敗するようならここを疑う
- **eMMC CQHCI**: ベンダは sdhci-esdhc-imx の CQHCI 初期化を revert していた。
  現代カーネルで eMMC CQE エラーが出たらこの eMMC は CQE 無効化が正解の可能性
- 音声アンプ TAS5825M(i2c)、タッチ(eGalax/Atmel mXT)、PCA953x expander の
  ドライバ群は別製品変種向け。うちの個体に載っているかは未確認

## 6. 未検証のまま残るもの

- ~~CAN INT = SAI5_RXD3(GPIO3_IO24)~~ — **解消 (2026-08-13)**: HAT 装着で
  CAN 実受信を確認 (mcp2515 の受信は割り込み駆動のみなので、受信成立が
  INT 配線正当の実証)。HW ガイド 40 ピン表からの推定が正しかった
- DDR の温度・個体ばらつきマージン — ベンダと同一値であることは確定したので
  「ベンダ出荷品と同等のマージン」までは言える(それ以上は実測のみ)
