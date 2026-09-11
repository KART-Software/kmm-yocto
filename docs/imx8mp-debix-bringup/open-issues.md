# DEBIX Infinity — 未解決事項と暫定対応(2026-09-07 時点、weston 13 + card0 直後起動後)

確定した内容は 00〜(連番)と 30-boot-time.md(起動時間の継続記録)に置き、ここには**まだ暫定のもの・未解決のもの**だけを置く。
解決したらこのファイルから消して、確定した知見だけを該当 docs に移す。

## 実機(ベンチの eMMC)に残っている暫定状態

- **2026-09-07 に両スロットをビルド済みイメージで正規化**(名前一掃後の
  `kart-image-imx8mp-debix-emmc`、OTA で A/B とも書き換え、imx-boot も `uboot-update` で
  更新、saved env は `ab_*` へ移行済み)。それまでの手載せ(weston 13、seed unit、
  トレース unit、3 段パターン、/data の調査残骸 strace / libdrm-atomic-dump.so 等)は
  rootfs 側は全て消えた。/data に残る `weston12-backup.tar` / `kiosk-shell.so.orig` /
  `investigation/` / `strace` は消してよい
- **2026-09-08: falcon の /memory 修正入りイメージで両スロットを OTA 正規化**
  (カーネル ge32abde26f10 + 一致モジュール、imx-boot A copy = 修正版 SPL、B copy は前版)。
  暫定状態なし。/data/memtest(memtester と結果ログ)は消してよい

## 未解決

1. **DDR 3732MTS のマージン**: ベンダーは同じ DRAM を 3264MTS で運用している。室温の
   パターンループ 20 周(128GB)は化けゼロだが、温度をかけた長時間試験は未実施。
   2026-09-08: Linux 上の memtester 2000M 1 周(全 16 パターン、33 分)エラー 0。
   続けて **memtester 3000M × 2 周 + CPU 3 コア常時負荷(SoC 温度 79〜81℃、
   1 時間 40 分)でもエラー 0・リセットなし**。ベンチで出せる温度域(ヒータ無し、
   SoC 内蔵センサ)ではマージン問題は見えない。工業温度域(105℃)や低温は未試験。
   それ以前に「memtester 開始 20s でリセット」があったが DDR ではなく falcon の
   /memory 決め打ちバグ(04-falcon.md「DRAM バンクと /memory」)だった。
   製品化前に NXP RPA + DDR Tool で本機用に正規生成する(NXP アカウントが必要)か、
   3264MTS 版の単一表を作って比較する
2. **U-Boot の ADV7535 プローブがカーネル HDMI TX を殺す機序**: 未特定
   (I2C 0x3c/0x3d への書き込み、または DSI/mediamix 側のクロック・電源ドメイン残留が疑い)。
   現状は U-Boot video を無効にして回避
3. **D8BJG 専用表(3264MTS)がコールドで training ハングする理由**: 未特定
   (DRAM 側 Mode Register の残留依存が疑い)。現状は Model A ベース表で回避しており実害なし
4. (解決 → [06-splash.md](06-splash.md)): SPL スプラッシュ + seamless takeover は
   falcon/proper 両経路で実機確定。スプラッシュ導入後の起動時間は 30-boot-time.md
   #12〜#14 で再計測済み
5. **uuu 標準フロー(emmc_all)の再検証**: fastboot 段は未検証。SPL/imx-boot の更新は
   Linux からの dd、または 04-falcon.md のリカバリ経路(tftp)で運用中
6. **M7**: falcon 統合まで実機動作(01-m7.md「falcon 統合」。BL31 起動 → Linux attach →
   rpmsgcan0 で外部 CAN 受信 → kmm 表示)。`kas/imx8mp-m7.yml` + data-logger-zephyr dev/imx8mp-m7。
   残りは CAN を M7 に持たせるかの設計判断と、BL31 diag NOTICE の扱い(現状 1 行)。
   rpmsgcan0 は M7 の rpmsg 告知後(~2.9s)に生えるため kmm より遅い — kmm 側は遅延 bind で
   吸収済みだが、CAN 表示開始は can0-up の UP(~3.8s)以降になる
7. **起動時間**: weston 13 + seed credit 前倒し + card0 直後起動(30-boot-time.md #12〜#14)で
   **電源→GUI = 3.17s(σ0.07、N=10、外れ値なし)**。内訳は同 md「現在の内訳」。
   M7 統合後は 3.35〜3.48s(+0.10s、30-boot-time.md の 09-11 行)。
   残りの候補:
   - **M7 attach の `imx_rproc_kick` 100ms タイムアウト**(M7 が MU を drain しないため。PID1 が
     0.09s 遅れる。M7 側で MU RX を処理すれば消える — data-logger-zephyr 側の作業)
   - カーネル→PID1 1.13s(最大の単一区間、未着手)
   - kmm の wayland socket→READY 0.34〜0.47s(Qt/fontconfig 初期化そのもの)
   - udev の systemd タグ対象(tty 22 / block 21 / net 4)削減で PID1 のイベント処理を軽くする
     (#13 の機序の副産物。効果は未計測)
   - CAAM ビルトイン化で seed credit 自体を不要にする(8MM pitfall #21 からの持ち越し)
   - ROM ロード区間の eMMC fast boot 化は **fuse が不可逆のわりに上限百 ms 級のため保留を決定**
     (2026-09-03。fuse なしの boot0 起動は速度 ±0 を実機確認。[07-emmc-boot-rom.md](07-emmc-boot-rom.md))。
     SPL 縮小は実測 ±0 で撤回済み(30-boot-time.md)
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
10. (採用 2026-09-07 → ツリーの weston.service。30-boot-time.md #14)
   **card0 ピンポイント待ちによる weston 前倒し**:
   `ExecStartPre=udevadm trigger --settle /dev/dri/card0` + After=udevd で
   weston 起動が 2.0→1.6s に前倒せる(card0 はカーネル 0.30s で生成済みだが
   weston は coldplug 完了 1.98s を待っている)。#9 が解決したので採用可能になった
   (2026-09-07、#9 の検証はこの構成で行った)。ツリーには入れていない(baseline のまま)。
   再計測(weston 13)で 5 本中 1 本の +0.4s 外れ値があったが、原因(CRNG 未初期化で kmm の
   getrandom() がブロック、seed credit が udev イベント洪水の後ろに回る)は #13 の
   seed credit 前倒しで解消し、10/10 単峰 3.17s(σ0.07)を確認(30-boot-time.md #13)。
   旧 unit(udev-trigger 待ち)は 3.71s。派生の残課題:
   udev の systemd タグ対象(tty 22 / block 21 / net 4)を減らして PID1 のイベント処理を
   軽くする、CAAM ビルトイン化で seed 自体を不要にする
11. (解決 2026-09-07 → [04-falcon.md](04-falcon.md) 「落ち先(proper)が死んでいた」):
   **スプラッシュ中の電源断で起動不能**。デッドマンの落ち先 proper 経路でカーネルが
   console 切替直後に停止していた(SPL が稼働させたままの HDMI 電源ドメインを素の
   blk-ctrl が再シーケンスしてバスごと固まる)。修正 = U-Boot proper の DT fixup で
   `splash-active` を立てて養子縁組(u-boot.itb の差し替えのみ)。実経路 3/3。
   起動中の任意時刻での電源断スイープの結果は 04-falcon.md に追記。

12. **OTA の rootfs dd 中に ssh が切れることがある**(2026-09-07、4 回中 2 回):
   `ota-update.sh` の「rootfs -> /dev/mmcblk2p{5,6} (dd over ssh)」の途中で
   `Connection reset by peer` / `Timeout, server not responding`。1 回目はその直後に
   ボードが応答不能(ただし同時に SPL/カーネル契約不整合のハングが重なっており切り分け
   不能)、2 回目はボードは生きたまま ssh だけ切断。成功時は 1.5GB を約 70s で書く。
   RuntimeWatchdogSec=15 のハード WDT リセットか、eMMC 書き込み中の sshd/ネットワーク
   の問題かは未特定。再現時はシリアルを並行記録して SPL バナーの有無(= リセットか否か)
   を先に確定すること
