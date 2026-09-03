# DEBIX Infinity — 未解決事項と暫定対応(2026-09-02 時点、スプラッシュ移植後)

確定した内容は 00〜(連番)と 30-boot-time.md(起動時間の継続記録)に置き、ここには**まだ暫定のもの・未解決のもの**だけを置く。
解決したらこのファイルから消して、確定した知見だけを該当 docs に移す。

## 実機(ベンチの eMMC)に残っている暫定状態

- **falcon-rearm.service が hot-install**(2026-09-02): rootfs へ手で置いて enable
  してある(動作は実機確認済み)。レシピ版(falcon-rearm)は kart-image に
  組み込み済みで、次のイメージ焼き直し/OTA で正規化される
- **検証中の手配布が多数**(2026-09-02 時点、いずれもツリーの最新ビルドと機能同等):
  boot の Image/DTB/falcon.itb と rootfs のモジュール一式(GPU 削減後の
  BUILD73 相当)、imx-boot(BUILD63 相当)、weston.ini の renderer=pixman
  手編集。また GPU 削減の runtime 実験で rootfs から退避したライブラリ群は
  復元/削除処理済み。GUI 特急レーンのユニット群 (seatd/weston/kmm/splash-wl) も
  /etc 上書きで手載せ (ツリーへは反映済み・同内容)。
  次のイメージ焼き直し/OTA で /etc 上書きごと完全に正規化される
- **kmm 並行起動は正規化済み**(2026-09-03): app リポジトリ d32e66b
  (waitForWaylandSocket)+ レシピの SRCREV/unit 更新でツリーに反映。
  ボード上の手載せ(/usr/bin/kmm + /etc の unit 上書き、kmm.orig 残置)は
  同内容なので、次の焼き直しで /etc 上書きと kmm.orig を掃除するだけ

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
4. (解決 → [06-splash.md](06-splash.md)): SPL スプラッシュ + seamless takeover は
   falcon/proper 両経路で実機確定。残タスクはスプラッシュ導入後の起動時間再計測
   (30-boot-time.md への追記)のみ
5. **uuu 標準フロー(emmc_all)の再検証**: fastboot 段は未検証。SPL/imx-boot の更新は
   Linux からの dd、または 04-falcon.md のリカバリ経路(tftp)で運用中
6. **M7**: remoteproc ノード未整備(01-m7.md)。can-gw の 8MP ポートは
   data-logger-zephyr の dev/imx8mp-m7 ブランチにビルド確認済み(実機未検証)。
   CAN を M7 に持たせるかの設計判断待ち
7. **起動時間**: GUI 特急レーン(30-boot-time.md #11)まで終えて
   **電源→GUI = 3.96s ± 0.08(min 3.82)**。userspace は掃討済み。
   残りの候補は ROM ロード区間の eMMC fast boot 化のみだが、**fuse は
   不可逆のわりに上限百 ms 級のため「最後の爆弾」として保留を決定**
   (2026-09-03。fuse なしの boot0 起動は成功するが速度 ±0 を実機でも確認済み。
   調査の全容と決定: [07-emmc-boot-rom.md](07-emmc-boot-rom.md))— SPL 縮小は実測 ±0 で
   撤回済み(30-boot-time.md 参照)。他は weston の exec+リンク 0.29s、
   udev-trigger 完了 1.87〜1.93s(weston の唯一の前提)。
   networkd-wait-online は GUI 非ブロックのまま
8. (解決 2026-09-03): pgc power-domain@8 = **pgc_vpumix** と確定
   (@11/12/13 = vpu_g1/g2/vc8000e、@4 = mlmix)。Quad Lite でヒューズアウトの
   ため DTS で無効化し、「failed to command PGC」と deferred 群は根絶
   (imx8mp-debix.dts の該当コメント参照)
