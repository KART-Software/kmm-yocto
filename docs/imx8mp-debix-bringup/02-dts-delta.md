# 02 — DEBIX 実機用 DTS 差分(工場 5.10 DTS vs うちの 6.6 EVK DTB)

工場イメージの実行中 FDT(carve 済み live FDT、
実体は `/boot/imx8mp-evk.dtb` = `imx8mp-debix-core-board.dtb`)と、
スキャフォールドビルドが deploy した 6.6.101-fslc の `imx8mp-evk.dtb` を
ノード status + pinmux で突き合わせた結果。**自前 `imx8mp-debix.dts` を起こすときの作業リスト**。

## 結論サマリ

DEBIX 工場 DTS は EVK 派生(compatible も `fsl,imx8mp-evk` のまま)なので、
6.6 の EVK DTS をベースに **有効化 4 件 + pinmux 修正 1 件 + 無効化 4 件**が最低ライン。

## 有効化・修正が必要(DEBIX で使うのに 6.6 EVK のままでは動かない)

| ノード | 工場 | 6.6 EVK | 作業 |
|---|---|---|---|
| **flexcan1**(can@308c0000) | okay | okay **だが pinmux が別物** | **pinmux を SPDIF_TX/RX → `SAI5_RXD1__CAN1_TX`/`SAI5_RXD2__CAN1_RX` に変更**(J2 ヘッダー Pin31/33 行き)。`xceiver-supply` を削除(下記) |
| **flexcan2**(can@308d0000) | okay | disabled | 有効化。pin group(`SAI5_RXD3__CAN2_TX`/`SAI5_MCLK__CAN2_RX` = J2 Pin35/37)は 6.6 EVK に定義済みで工場と一致。`xceiver-supply` を削除 |
| **usdhc1**(mmc@30b40000) | okay | disabled | 有効化 = **WiFi 88W8987(SDIO)**。bus-width 4 / non-removable / keep-power-in-suspend / `nxp,wifi-wake-host` 割り込みノード。使わないなら disabled のままでも可 |
| **ecspi1**(spi@30820000) | okay | disabled | J2 ヘッダーの SPI。ADS8688 を A53 に繋ぐ場合のみ有効化(M7 案なら Linux 側は disabled のまま) |

**CAN の重要事実**: 工場 DTS の flexcan に `xceiver-supply` が**無い** = ボード上に
CAN トランシーバは**載っていない**。J2 に出ているのはコントローラレベルの
TXD/RXD(3.3V デジタル)なので、**外付けトランシーバが無いとバスに出られない**。
6.6 EVK の `xceiver-supply`(EVK の standby GPIO レギュレータ)は DEBIX では別用途の
ピンを触りかねないので必ず削除。

実バス確認(2026-08-31): J2 Pin31(CAN1_TXD)→ トランシーバ TXD、Pin33(CAN1_RXD)←
トランシーバ RXD の**ストレート接続**(UART と違いクロスしない)で、絶縁型 CA-IS3050G
モジュール経由 CANable と 500kbps 双方向送受信、2000 フレーム連続受信でロス/エラーなし。
配線をクロスすると「送信で即 bus-off、listen-only でも受信ゼロ」になる。
can1(J2 Pin35/37)は loopback のみ確認。

## 無効化すべき(6.6 EVK が okay にしているが本構成では不要・有害)

| ノード | 工場 | 6.6 EVK | 理由 |
|---|---|---|---|
| pcie(33800000) | disabled | okay | DEBIX は 19pin FPC のみ。未接続でリンク待ちのプローブエラー/起動遅延の元 |
| mipi_dsi / dsi(32e6) | disabled | okay | パネル無し。HDMI 運用 |
| dsp(audio) | disabled | okay | 未使用 |
| ldb/lvds 系 | disabled(パネル変種のみ okay) | 混在 | HDMI 運用なので disabled 側に揃える |

## そのままで良さそう(実機ブートで最終確認)

- **eqos + fec**: 両方 okay、PHY は**両方 RTL8211F**(工場 dmesg 実測。eqos=ens33 rgmii-id)。
  6.6 の EVK 定義のまま end0(fec)は 1Gbps リンク、end1(eqos)は PHY 認識まで確認(ケーブル未接続)
- **uart1/2/3**: okay(uart2 = コンソール ttymxc1、J2 Pin9/11)
- **uart4**: 工場は A53 のシリアルとして okay、**6.6 EVK は disabled — 本設計では
  M7 コンソールに割り当てるので disabled のままが正解**(8MM の uart4=M4 と同じ構図)
- hdmi/lcdif1-3/gpu/vpu: HDMI チェーンは両方 okay で工場実機の動作確認済み

## 独自に追加するもの(工場 DTS にも無い)

- `imx8mp-cm7` remoteproc ノード + vdev/rsc_table 予約メモリ([01-m7.md](01-m7.md)。
  雛形は 6.6 ツリーの `imx8mp-evk-rpmsg.dts`)
- FlexCAN を M7 に持たせる場合は Linux 側 flexcan を disabled に戻して RDC 割り当て
  (plan #5 の設計判断待ち)
