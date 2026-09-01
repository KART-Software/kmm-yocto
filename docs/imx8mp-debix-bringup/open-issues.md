# DEBIX Infinity — 未解決事項と暫定対応(2026-09-01 時点、falcon 移植後)

確定した内容は 00〜04 に置き、ここには**まだ暫定のもの・未解決のもの**だけを置く。
解決したらこのファイルから消して、確定した知見だけを該当 docs に移す。

## 実機(ベンチの eMMC)に残っている暫定状態

- **falcon の再アームが手動**: 起動成功時に `boot_os=yes` を書き戻す systemd unit が
  まだ無く、ベンチは手で `fw_setenv boot_os yes` してある(コールドブート 1 回ごとに
  消費される。未アームなら proper 経由で普通に起きるだけで実害なし)

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
4. **スプラッシュ**: 8MM の SPL 手続き描画 + seamless takeover を 8MP(LCDIFv3 + HDMI TX)
   向けに再実装する。falcon 基盤は整った(04-falcon.md)
5. **uuu 標準フロー(emmc_all)の再検証**: fastboot 段は未検証。SPL/imx-boot の更新は
   Linux からの dd、または 04-falcon.md のリカバリ経路(tftp)で運用中
6. **M7**: remoteproc ノード未整備(01-m7.md)。can-gw の 8MP ポートは
   data-logger-zephyr の dev/imx8mp-m7 ブランチにビルド確認済み(実機未検証)。
   CAN を M7 に持たせるかの設計判断待ち
7. **起動時間**: falcon + SPL HS400 化後 **電源→GUI ≈ 6.0s**(SPL+env ~1.0s /
   falcon.itb ロード 0.86s / kernel 1.3s / userspace→kmm READY 2.8s)。
   **残る謎: SPL の FAT 読みが HS400(ES) 有効でも 41MB/s 止まり**(モード/クロックは
   実測で mode=HS400_ES・200MHz を確認済み。proper の fatload は同一ファイル
   302MiB/s。断片化でもない)。SPL の spl_load/FIT/ドライバ経路のどこかに ~8 倍の
   オーバーヘッド。次に削るならここをプロファイルする。
   networkd-wait-online 5.9s は GUI 非ブロックのまま
8. **falcon 再アーム unit**: 起動成功(kmm READY 後が候補)で `fw_setenv boot_os yes`
   する小 unit を kart-image / falcon 構成に追加する。OTA の upgrade_available との
   干渉整理も含めて設計してから入れる
9. **imx-pgc-domain.8 の正体**: fslc DTB の pgc `power-domain@8`(reg 0x08)は
   Quad Lite でヒューズアウトされた VPU 系 mix と推定して無効化した(実測: これで
   PGC エラー 0)。dt-bindings 上の正式名との突き合わせは未実施
