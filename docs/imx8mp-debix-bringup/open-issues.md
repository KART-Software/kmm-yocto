# DEBIX Infinity — 未解決事項と暫定対応(2026-08-31 時点、A/B 移植後)

確定した内容は 00〜03 に置き、ここには**まだ暫定のもの・未解決のもの**だけを置く。
解決したらこのファイルから消して、確定した知見だけを該当 docs に移す。

## 実機(ベンチの eMMC)に残っている暫定状態

なし(2026-08-31、A/B レイアウトの wic を焼き直し、`/data` は p7 の永続パーティション。
`/data/kmm.env` は local/kmm.env を手で置いたもの = 本番のプロビジョニング手順と同じ)。

## 未解決

1. **DDR 3732MTS のマージン**: ベンダーは同じ DRAM を 3264MTS で運用している。室温の
   パターンループ 20 周(128GB)は化けゼロだが、温度をかけた長時間試験は未実施。
   製品化前に NXP RPA + DDR Tool で本機用に正規生成する(NXP アカウントが必要)か、
   3264MTS 版の単一表を作って比較する
2. **U-Boot の ADV7535 プローブがカーネル HDMI TX を殺す機序**: 未特定
   (I2C 0x3c/0x3d への書き込み、または DSI/mediamix 側のクロック・電源ドメイン残留が疑い)。
   現状は U-Boot video を無効にして回避
3. **D8BJG 専用表(3264MTS)がコールドで training ハングする理由**: 未特定
   (DRAM 側 Mode Register の残留依存が疑い)。現状は Model A ベース表で回避しており実害なし
4. **TFP401 LCD 用 EDID の恒久化**: 33.75MHz 版 EDID(03 §3)を `kart-edid-firmware` の
   8MP 対応 + カーネル cmdline(`drm.edid_firmware=HDMI-A-1:edid/...`)で配る
5. **スプラッシュ**: 8MM の SPL 手続き描画 + seamless takeover を 8MP(LCDIFv3 + HDMI TX)
   向けに再実装する。Falcon 構成を 8MP でも組むかの判断込み
6. **uuu 標準フロー(emmc_all)の再検証**: TCPC 無効化後は自前 U-Boot の SDPV まで通ることを
   確認済みだが、fastboot 段は未検証。今は Linux 稼働中の `dd` で書いている
7. **M7**: remoteproc ノード未整備(01-m7.md)。CAN を M7 に持たせるかの設計判断待ち
8. **起動時間**: 初期値 kernel 4.1s + userspace 11.2s = 15.3s(最適化未着手。8MM で
    確立した udev 間引き・ユニット間引き・Falcon 等は未移植)
