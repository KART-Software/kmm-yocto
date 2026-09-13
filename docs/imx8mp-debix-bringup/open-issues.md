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
- **2026-09-14: env 2 面化を実機正規化完了**(#13)。移行(手書きの新 imx-boot + 2 面 env)後、
  proper 経路の安全化(両 BOOT の u-boot.itb を冗長版に差し替え)→ 冗長 env 版フルイメージを
  **両スロット OTA**(A/B とも tryboot→commit 成功)。両スロットとも rootfs 新版・recipe の 2 行
  fw_env.config・冗長 u-boot.itb・冗長 falcon.itb、imx-boot A=冗長 SPL / B=前版(ロールバック)、
  env 2 面。**手載せ無し**。/data の移行残置物(env-migrate.*, imx-boot-new, u-boot-redund.itb,
  fix-bootb-uboot.sh, env-region-backup.bin, u-boot.itb.bootb.orig)は消してよい

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
6. (解決 2026-09-13 → [01-m7.md](01-m7.md)「M7 の役割(確定)」): M7 が FlexCAN1 を所有する
   can-gw 構成を製品構成として確定(08-31 の「廃止も含めて判断」は事前リサーチ時の
   メモで、実装は一貫してこの構成)。BL31 diag NOTICE 1 行は残す、flexcan2(`can0`)は
   予備として残す。falcon 統合まで実機動作、rpmsgcan0 UP は 1.6〜1.7s(kmm 起動前)
7. **起動時間**: weston 13 + seed credit 前倒し + card0 直後起動(30-boot-time.md #12〜#14)で
   **電源→GUI = 3.17s(σ0.07、N=10、外れ値なし)**。内訳は同 md「現在の内訳」。
   M7 統合 + coldplug を seed 後に回す #16 で **3.16s(σ0.05、N=10、3.07〜3.21)**。二峰は
   coldplug と data-mount/seed の eMMC 取り合いが真因で #16 で根絶(30-boot-time.md)。
   **2026-09-14: kernel→PID1 を 0.77→0.56s に短縮**(30-boot-time.md #18)。initcall_debug
   プロファイルで FEC(Ethernet)probe が MAC 201ms + PHY 89ms = ~290ms を PID1 前で同期消費と
   判明 → `CONFIG_FEC=m`(boottune-imx8mp.cfg)で coldplug ロードに回し GUI 3.14→2.95s、
   ecspi2/usdhc2 無効化で 2.93s。**電源→GUI 2.93s(σ0.04、N=10)が現行**。
   残りの候補:
   - **表示 lcdifv3 ~88ms**(GUI 必須の probe)。async 化すれば PID1 を先へ出せる可能性があるが、
     dark-boot リスクで **lcd-validation(カメラ+AprilTag)必須** — カメラ未接続のため未実施。
     起動時間計測(kmm "First window expose")は compositor が動けば dark でも記録されるので
     表示健全性の代理にできない
   - jitterentropy(jent_mod_init 27〜33ms)は CONFIG_CRYPTO_DRBG が force-select で単独無効化不可
   - audio_blk_ctrl(~12ms)無効化は起動ハング(AudioMIX 電源/クロック provider)→ 有効のまま
   - カーネル→PID1 の残り(現行 0.56s)。deferred_probe に eMMC/表示/PMIC 等の必須 probe が残る
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

13. (解決 2026-09-13、実機検証済み): **U-Boot env の 2 面化**。単一コピーだと 1 起動 2 回の
   env 書き(SPL デッドマン `boot_os=no` +0.5s、falcon-rearm `boot_os=yes` +3.6s、各数 ms)中の
   電源断で CRC 不良 → デフォルト env → slot A 固定に退化し得た。`CONFIG_SYS_REDUNDAND_ENVIRONMENT`
   で 2 面化(commit 45d92bc: debix-ab.cfg `CONFIG_ENV_OFFSET_REDUND=0x704000`、ab-tools の
   fw_env.config 2 行、uboot-env を `mkenvimage -r` の 2 面連結)。保存は常に未使用面へ書くので、
   書き込み中に落ちても直前 1 変更を失うだけで A/B 状態は無傷。SPL loader 増は +0x400(1KB、
   boot_data.size 0x42860→0x42c60、OCRAM 余裕内)。**実機検証**: 移行後 4 起動で flags が
   copy1 03→05→07→09 / copy2 02→04→06→08 と交互・単調増加(= 各 save が反対面に書かれる)、
   ab_slot/boot_os 無傷、falcon/kmm/M7 正常。移行手順は local/tools-handoff/env-redund-migrate/。
14. (解決 2026-09-14、実機検証済み): **デッドマン窓の短縮**。falcon-rearm が
   `After=dev-mmcblk2.device` で coldplug 完了(kernel ~2.3s)まで待たされ、補充が電源 +3.76s、
   窓(電源 +0.5〜)が ~3.3s あった。単に `After=systemd-random-seed` に替えても
   `DefaultDependencies=yes` の暗黙 `After=sysinit.target/basic.target`(coldplug 待ち)が律速で
   無効(実測 rearm 依然 2.62s)。**`DefaultDependencies=no` + `After=systemd-random-seed.service`**
   で sysinit 順序から外し、seed の直後に撃つ(falcon-rearm.service)。実測: rearm 完了が
   kernel 2.71s→**1.5s**(電源 +2.55s)、窓 ~3.3s→**~2.05s**。起動時間は **3.14s σ0.05 N=10**
   で非回帰(rearm の eMMC 書きが kmm ロード 1.5s と同時間帯でも影響なし)、ordering cycle 0・
   failed 0。env 2 面化(#13)済みなので補充書き込み中の電源断でも安全。両スロット OTA 済み。

