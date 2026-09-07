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

- **weston 13.0.1 を手載せ**(2026-09-07): weston 本体 + libweston-13 + モジュール一式を rootfs に
  直接展開(12 系一式は `/data/weston12-backup.tar`、12 用パッチ版 kiosk-shell は `/data/kiosk-shell.so.orig`
  が元)。kmm.service に検証用 drop-in `order.conf`(After=weston + sleep 0.3)が残っている。
  カーネルは製品版(BOOTA の `falcon.itb` = g276209957d88)に戻してある。次のフルイメージ
  焼き直し/OTA で正規化される。調査用の `/data/strace`、`/data/libdrm-atomic-dump.so` は
  消してよい。weston.service は「card0 直後起動」版(#10)が /etc に載ったまま

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
9. (解決 2026-09-07 → [06-splash.md](06-splash.md) 「暗ブートの真因と修正」、経緯は [08-dark-boot.md](08-dark-boot.md)):
   **コールド暗ブート(SPL ロゴ後に真っ黒)**。真因は表示ハード/カーネルではなく
   weston 12 kiosk-shell の seat レース(libinput の udev 列挙より前にクライアントが
   commit すると surface がレイヤに載らない)。修正は weston パッチ
   `0003-kiosk-shell-map-without-seat.patch`。製品カーネル + weston card0 直後起動 +
   3 段 AprilTag で 10 コールド暗 0/10(GUI 段を splash の 300ms 後に起動する条件でも 10/10 で
   SPL→splash→GUI の順)。さらに poky 標準の **weston 13.0.1 に切り替えるとパッチ無しで同じく 0/10**
   (`imx8mp-debix.conf` で選択済み。13 は kiosk-shell の構造が変わり穴が無い)。
   カーネル側の 0015〜0020 と kas overlay
   (recover/pixclk/pll/traceevt 等)は不要になりツリーから外した。
10. **card0 ピンポイント待ちによる weston 前倒し(-0.35s、保留)**:
   `ExecStartPre=udevadm trigger --settle /dev/dri/card0` + After=udevd で
   weston 起動が 2.0→1.6s に前倒せる(card0 はカーネル 0.30s で生成済みだが
   weston は coldplug 完了 1.98s を待っている)。#9 が解決したので採用可能になった
   (2026-09-07、#9 の検証はこの構成で行った)。ツリーには入れていない(baseline のまま)
11. (解決 2026-09-07 → [04-falcon.md](04-falcon.md) 「落ち先(proper)が死んでいた」):
   **スプラッシュ中の電源断で起動不能**。デッドマンの落ち先 proper 経路でカーネルが
   console 切替直後に停止していた(SPL が稼働させたままの HDMI 電源ドメインを素の
   blk-ctrl が再シーケンスしてバスごと固まる)。修正 = U-Boot proper の DT fixup で
   `kart,splash-active` を立てて養子縁組(u-boot.itb の差し替えのみ)。実経路 3/3。
   起動中の任意時刻での電源断スイープの結果は 04-falcon.md に追記。
