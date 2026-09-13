# 05 — 起動時間の短縮記録(DEBIX / i.MX8MP)

「電源 ON → GUI(kmm READY = 画面表示)」の実測を主指標にした短縮の記録。
1 施策 = 1 行で、効かなかった施策も残す(再挑戦の無駄を防ぐ)。
各施策の技術詳細はリンク先。計測はシリアルのタイムスタンプ
(ts-serial)+ `journalctl -o short-monotonic` の kmm Started。

| # | 日付 | 施策 | 電源→GUI | 差分 | 備考・参照 |
|---|---|---|---|---|---|
| 0 | 08-31 | (移植直後・未最適化) | — | — | systemd-analyze **15.3s**(kernel 4.1 + userspace 11.2)。さらに NXP defconfig の FW user-helper fallback により、見つからない firmware 要求が各 **60s 停止**(EDID cmdline 追加で顕在化、sdma 2 件も該当) |
| 1 | 08-31 | 第 1 弾: FW fallback 無効・quiet(kernel 4.1→1.3s)・udev/hwdb 削減・ユニット間引き・CPU 配分(8MM の道具を imx-generic-bsp へ共通化) | **≈7.0s** | — | SPL 0.6 / U-Boot 1.8 / kernel 1.3 / userspace ~4.2。analyze 11.5s。FW: `meta-kart/recipes-kernel-imx/linux/files/edid-firmware.cfg`、udev/CPU 配分: `meta-kart/recipes-support/udev-slim/`、ユニット間引き: `kart-image.bb` の boot_trim_units。コミット 69773a8 |
| — | 08-31 | weston-early(basic.target を待たない 8MM 変種) | 7.0s | **±20ms = 効果なし、不採用** | 律速は basic 待ちでなく seatd 後の dispatch/exec + weston 初期化 0.8s。経緯コメント: `meta-kart/recipes-graphics/weston/weston-init.bbappend`(weston-early.service)。8MM 側の weston 区間の知見は [../imx8mm-xpi-bringup/11-splash-optimization.md](../imx8mm-xpi-bringup/11-splash-optimization.md) ⑧ |
| — | 08-31 | FlexCAN ビルトイン化 | ≈7.0s | 微小 | kmm のクリティカルパスから udev を排除(定性的効果)。`meta-kart/recipes-kernel-imx/linux/files/can-builtin.cfg`、コミット 5ec449d |
| 2 | 09-01 | **Falcon mode**(U-Boot proper 1.8s をスキップ) | **6.6s** | -0.4s | ただし SPL の低速 eMMC 読みで falcon.itb 35MB に 1.54s かかり効果が相殺気味。設計・落とし穴①〜③: [04-falcon.md](04-falcon.md)、SPL のメモリ知識: [../../learning/08-uboot-spl-memory.md](../../learning/08-uboot-spl-memory.md) |
| 3 | 09-01 | SPL eMMC を **HS400(ES) @200MHz** 化 | **6.0s** | -0.6s | ロード 1.54→0.90s。config 2 行(`debix-falcon.cfg`)+ 高速 pinctrl の bootph パッチ(`0003-imx8mp-debix-spl-usdhc3-fast-pinctrl.patch`)。[04-falcon.md](04-falcon.md) 実測結果の節 |
| 4 | 09-01 | **35MB の隠れ memmove 除去**(blob 64B パディング + in-place memcpy スキップ) | **5.2s** | -0.8s | ロード 0.90→**0.19s**(読み自体は 119ms=295MB/s だった)。機序: [04-falcon.md](04-falcon.md) ④、教訓(アラインと隠れコピー・バス vs CPU の切り分け): [../../learning/08-uboot-spl-memory.md](../../learning/08-uboot-spl-memory.md)。パディング: `falcon-itb.bb`、スキップ: `0004-spl-fit-skip-inplace-memcpy.patch` |
| 5 | 09-02 | **SPL スプラッシュ + seamless takeover + splash-wl** | **5.2s(維持)** | ±0 | 数値でなく体感の施策: **電源 +0.8s でロゴ点灯**し、GUI まで暗転ゼロ(SPL 描画 24ms、kmm READY はシリアル+journal 実測で 5.2s 維持)。カメラ輝度タイムラインで falcon/proper 両経路 PASS。設計・パッチ・落とし穴: [06-splash.md](06-splash.md) |
| 6 | 09-02 | **カーネル減量**(slim-imx8mp.cfg: 仮想化/SND/BT/無線/V4L2/NFS/IPv6 ほか一掃) | **4.9s** | -0.3s | kernel 1.18→1.08s、userspace も probe/udev 減で -0.34s(kmm READY 3.99→3.65s)、Image ≈35→25.9MB で falcon.itb ロードも短縮(SPL 区間 627→595ms)。**罠**: PINCTRL を select するのは ARCH_S32 だけで、他 SoC 削りで PINCTRL ごと消える(8MM pitfalls #15 の 8MP 版 — cfg 内コメント参照)。NXP defconfig 特有の VIRTIO_VIDEO は XEN/KVM/VIRTIO と一塊で消すこと |
| 7 | 09-02 | **カーネル減量 第二弾**(表示系の他人: DCSS/LDB/IT6263/NWL-DSI/ADV7535/EVK パネル群 + MTD) | **4.8s** | -0.1s | kernel 1.08→**0.97s**、kmm READY 3.65→3.57s、Image 25.9→**24.2MB**。**罠**: LDB ドライバを消すなら DTS で `&ldb`/`&ldb_phy` も disabled にすること — ノードが有効なままだと imx-drm のコンポーネント束ねが揃わず **display-subsystem ごと消えて weston が「no drm device found」**(実測。card0 が galcore だけになる)。dmesg の ldb/it6263/spi-nor ノイズも消滅 |
| 8 | 09-02 | **weston を pixman レンダラに**(CPU 合成) | **4.7s** | -0.13s | クライアントは kmm (Qt Widgets = raster) と splash-wl (wl_shm) のみで GPU 合成の出番が無い。Vivante EGL/GL 初期化 ~130ms が消え kmm READY 3.57→**3.44s**。CPU 負荷アイドル ~0%、カメラ判定で暗転ゼロ維持。`weston-debix.ini` の [core] renderer=pixman。weston 初期化の残り = exec+リンク ~290ms(難) |
| 9 | 09-03 | **kmm を weston と並行起動**(app 側で wayland ソケット待ち + unit の After=weston 除去) | ≈4.5〜4.7s | **-0.18s** | weston READY→GUI が 0.50→**0.32s**(3 ブートで再現)。Qt ライブラリロード 0.5s が weston 初期化と完全に重なった。見込み -0.3s に届かなかった理由: 旧構成のロードは空き時間帯で実は 0.2s しかなく、初期化+初回フレーム 0.3s が定数だった(計装実測: QApplication 82ms / MainWindow 構築 65ms / show 81ms / expose 44ms — フォント犯人説は外れ)。app d32e66b + `kmm.service`。**残る床**: sysinit 完了 2.44s(fork の門、DefaultDependencies=no も無効)と weston READY のばらつき ±0.3s |
| 10 | 09-03 | **DT の死にノード掃除**(EVK 遺産 30 ノード: eqos/音声一式/カメラ一式/flexspi/lcdif1・2/pca6416/lvds_backlight/VPU・NPU の pgc) | **≈4.4s** | -0.25s | kernel 0.96→**0.74s**(builtin probe 減)、coldplug 0.79→0.70s、uevent 815→692、kmm READY 3.43→**3.17〜3.20s**。副産物: 「failed to command PGC」×3・ov5640/pca953x/csis の probe エラー・毎ブートの systemd-backlight failed が**全滅**(dmesg エラー 0・failed unit 0)。旧 open-issue #8(pgc@8 の正体)も vpumix と確定して解決。**効かなかった**: udev ルール 12 本退避は -16ms = 誤差で撤回(規則数でなく uevent 数が支配)。rootfs デバイス帳簿(blame の dev-mmcblk2p5 0.96s)は /data 早期マウント済みのため GUI 臨界パス外と確認 |
| 11 | 09-03 | **GUI 特急レーン**(seatd/weston/kmm/splash-wl を DefaultDependencies=no + 最小 After に — basic/sysinit/dbus への依存を切断) | **3.96s(σ0.08)** | **-0.4s + 二峰性根絶** | 10 回統計で判明した二峰(±0.15s)の犯人 = /var/volatile マウントジョブと coldplug 洪水の PID1 発行順コイントス → GUI チェーンを local-fs/sysinit/basic から独立させて根絶。weston は After=seatd+**udev-trigger 完了**のみ(早すぎると no drm device found)、seatd は After=journald.socket のみ、kmm は data-mount のみ。8 サイクル実測: **電源→GUI min 3.82 / mean 3.96 / max 4.03s**。前回 kmm での DefaultDependencies=no 空振りは After=sysinit を残した自業自得だった。カメラ検証でロゴ→GUI 連続性維持(ロゴ点灯前 0.2s の暗転はパネル通電過渡で従来から存在、回帰でない) |
| — | 09-03 | SPL バイナリ縮小(ROM ロード時間 ∝ サイズ狙い: GPT/SHA/RSA config 削除 + proper 用 board ファイルの SPL 除外) | 3.96s | **±0 = 効果なし、撤回** | -1.7KB(165→163KB)しか縮まず、電源→banner は 1.364〜1.372s で基準と完全一致。機序: **LTO が未使用コードを既に捨てていた**(16KB の board ファイル混入は LTO 前のシンボルサイズの誤読)+ CAAM は `select FSL_CAAM if HAS_CAAM` で外れず + SPL_HASH/CRYPTO も select 連鎖で残存。ゼロ利得で 0006 パッチ + board_early_init_f 複製を抱えるのは負債なので撤回(再現ビルドで BUILD63 と md5 一致確認)。ROM 区間を削る現実的な残り手は eMMC fast boot 化(boot0 + 8bit DDR)のみ |
| — | 09-03 | eMMC boot0 ブート(fuse なし・partconf のみ) | 3.96s | **±0 = 効果なし(RM の予言どおり)、原状復帰** | 調査として実施: boot0 へ現行 imx-boot を置き PARTITION_CONFIG で起動 → 成功(バナー 1 バイト刻印で出所証明)だが電源→SPL は user 領域と完全一致(差分計測 mean 0.353 vs 0.352s)。normal boot は fuse 既定で既に 8bit SDR 20MHz のため置き場所では変わらない。fast boot fuse は「最後の爆弾」として保留決定。全容: [07-emmc-boot-rom.md](07-emmc-boot-rom.md) |
| — | 09-04 | weston を card0 ピンポイント待ちで前倒し(-0.35s)+ 0014(lcdifv3 quiesce) | 3.96s | **保留 — 暗ブート未解決のため不採用** | card0 前倒し自体は weston 起動 2.0→1.6s の効果あり(open-issues #10)。だが AprilTag 判定で**約 4 割のコールドブートが暗転(GUI が出ない)**と判明。当初「輝度判定で 24/24 明・0014 で解決」としたが**輝度 crop がバックライト黒を明と誤判定した完全な誤り**。正しい AprilTag 判定では **baseline After=udev-trigger でも約 4 割暗転** = これは card0 の回帰でなく**元からある takeover bring-up の暗ブート**(open-issues #9)。0014 も効かず。ツリー変更は全て revert。教訓: 表示判定は必ず tools/lcd-validation の AprilTag で(systemd active と輝度 crop は暗ブートを見抜けない) |
| — | 09-02 | SPL 中の A53 overdrive 1.2→1.6GHz | 5.2s | **-12ms = 効果なし、撤回** | 1.6GHz 化自体は成功(proper バナーが `at 1600MHz`。VDD_ARM は vendor SPL が元々 OD 0.95V なので PLL 切替のみ: spl_board_init で CCM 退避→ARM_PLL 1600→復帰)。しかし SPL バナー→falcon ジャンプ 627→615ms と CPU 律速でなく、さらに **proper 経路の Linux がカーネル極初期以降で沈黙する退行**(2/2 再現、falcon は健全。機序未特定)。利得ゼロ+フォールバック退行のため撤回。再挑戦するならまず proper 退行の機序(U-Boot proper の regulator sync と 1.6GHz の組か)を潰すこと |
| 12 | 09-07 | **weston 13.0.1 へ切り替え**(暗ブート #9 の解決。NXP フォーク 12.0.4.imx の kiosk-shell は seat レースでクライアントを表示しない) | **3.81s(σ0.06)** | -0.15s | 製品 unit のまま。実ロゴ/splash-wl/Qt kmm、製品カーネル、5 コールド。計測法は下記「再計測」 |
| — | 09-07 | card0 直後起動(#10)の再計測(weston 13、暗ブート解決後) | **3.34s(σ0.17)** | **-0.47s** | 5 本中 1 本が 3.65s(weston は最速 2.70s なのに kmm READY が +0.95s)。外れ値の原因は #13 で判明・解消(CRNG 未初期化で kmm の getrandom() がブロック)。採用は #14 |
| 13 | 09-07 | **seed credit を udev 洪水の前へ**(systemd-random-seed を丸ごと差し替えて /var/lib overlay 待ちを外し /data マウント直後に実行、volatile-binds の逆向き Before= も除去) | **3.71s(σ0.08)** | -0.10s | 製品 unit、5 コールド。card0 直後起動は **3.17s(σ0.07、10/10 単峰)** = 前回 3.34s(σ0.17)の二峰性が消滅。crng init done は全 15 boot で 1.45〜1.56s(従来 1.62〜2.48s)。機序は下記「card0 直後起動の外れ値」 |
| 14 | 09-07 | **weston を card0 直後起動に**(#10 採用。After=udev-trigger → After=udevd + ExecStartPre で /dev/dri/card0 出現待ち) | **3.17s(σ0.07)** | -0.54s | N=10 コールド、外れ値なし(3.08〜3.27)。weston 起動 1.99→1.65s(kernel 原点)。#9・#13 が前提 |
| 15 | 09-07 | **seed の creditable 印を即 sync**(systemd-random-seed に ExecStartPost=/bin/sync) | 3.14〜3.32s | 電源断直後の起動 4.2→3.2s | GUI 表示直後(3.2〜4.5s)に電源断した次の起動が 4.2s に落ちる件の修正。機序は下記「電源断直後の起動が 1 秒遅い」。短時間断 6/6 で 3.09〜3.32s、crng init 1.43〜1.51s |
| — | 09-11 | **Cortex-M7 統合**(kas/imx8mp-m7.yml: BL31 が M7 起動、Linux は remoteproc attach、CAN は rpmsg-can の rpmsgcan0。01-m7.md) | **3.31s(σ0.09、N=5)** | ±0(対照 3.26s σ0.05 と差はノイズ内) | 対照 = 同ツリーで m7 オーバーレイだけ外した像。初版は 3.35〜3.48s(+0.10s)だった: remoteproc attach の `imx_rproc_kick` が M7 の MU 未応答で tx_tout=100ms タイムアウト(err -62)し、root マウント前の `wait_for_device_probe()` に乗って PID1 が 0.76→0.85s に遅れていた(can0-up/modules-load をマスクしても不変 → userspace 無罪)。M7 側で MU-B RRn を読み捨てて即 ACK する修正(data-logger-zephyr 9e4d7aa)で kick failed 0 件、PID1 0.77s に戻った。CAN は rpmsg-can を modules-load.d で早期ロードして UP 1.66〜1.75s(kmm 起動前)= GUI と同時に値が入る。残る二峰は #16 で解消 |
| 16 | 09-11 | **coldplug を seed 後に**(udev-slim: `systemd-udev-trigger.service.d/after-seed.conf` = After=systemd-random-seed.service) | **3.16s(σ0.05、N=10、3.07〜3.21)** | -0.18s + 二峰根絶 | 二峰(3.19〜3.25 / 3.34〜3.42)の真因 = coldplug(1.20〜2.0s、blkid/モジュールロード)が data-mount(電源断起動で毎回 ext4 recovery)+ seed(load/write + sync)と **同じ eMMC を取り合う**。差は data-mount 完了→seed 完了の区間だけに出て、PID1・ジョブ投入・weston は同じ。#11 で GUI レーンを sysinit から切っても I/O の物理競合は残っていた。直列化で data-mount 1.28→1.39、seed 1.46〜1.56、kmm 起動 1.45〜1.57。coldplug 完了 2.02→2.3s だが GUI レーンは coldplug 非依存(weston は card0 の devtmpfs ノード、kmm は wayland ソケット、rpmsgcan0 は modules-load)で、遅れるのはネット IF 等ノイズ系のみ。タッチ入力は元から無い(TOUCHSCREEN=n、kmm は表示専用、weston は powerkey しか見ていない) |
| 17 | 09-14 | **falcon-rearm を seed 直後に前倒し**(`DefaultDependencies=no` + After=systemd-random-seed。open-issues #14。GUI 短縮でなくデッドマン窓の短縮) | **3.14s(σ0.05、N=10)= ±0** | GUI ±0 / デッドマン窓 3.3→2.05s | rearm(boot_os=yes 補充)が旧 `After=dev-mmcblk2.device` で coldplug 完了(kernel ~2.3s)待ち = 補充 +3.76s だった。単なる After=seed は `DefaultDependencies=yes` の暗黙 basic.target 順序(coldplug 待ち)で無効(実測 2.62s)。`DefaultDependencies=no` で sysinit 順序を外し seed 直後(kernel 1.5s、電源 +2.55s)に。rearm の eMMC 書きが kmm ロード 1.5s と同時間帯に入るが GUI は 3.14s σ0.05 単峰で非回帰。ordering cycle 0・failed 0。窓の上限は rearm 完了時刻 = 電源 +2.55s(journal 実測)|
## 現在の内訳(2026-09-07、#14 後。シリアル ts + journal 実測。現行 3.17s / 旧 unit 3.71s)

電源 ON からの積算(wall)。SPL 区間はシリアルの行時刻、カーネル以降は kernel 時刻原点
(電源 +1.02s)に journal の monotonic を足したもの。代表 1 boot(現行 3.19s / 旧 3.59s)。

| 区間 | 旧 unit(udev-trigger 待ち) | 現行(card0 直後、#14) | 備考 |
|---|---|---|---|
| 電源 → SPL バナー | 0.21s | 0.21s | BootROM の imx-boot ロード(eMMC boot0/fast boot 化は保留、07-emmc-boot-rom.md) |
| DDR init + PHY training | 0.20s | 0.20s | |
| SPL スプラッシュ点灯 | 0.02s | 0.02s | 表示チェーン全段 24ms(06-splash.md) |
| RNG/GIC + eMMC init | 0.04s | 0.04s | |
| env ロード | 0.14s | 0.14s | 16KB のインポート処理(dcache OFF)が主 |
| デッドマン env_save | 0.03s | 0.03s | |
| falcon.itb ロード + ロゴ blit | 0.15s | 0.15s | itb 読みが主。ロゴはファイルから |
| SPL ジャンプ → カーネル時刻原点 | 0.22s | 0.22s | BL31 + カーネル head(電源 +0.80 → +1.02s) |
| カーネル → PID1 | 1.13s | 1.13s | 累計 2.15s。最大の単一区間。**現行 0.77s**(falcon の /memory を実 DRAM バンクに直した 8d1bcac、09-08。open-issues #7) |
| PID1 → /data マウント + seed credit | 0.37s | 0.42s | 累計 ~2.55s。crng init done 1.45〜1.56s(kernel 原点) |
| udevd 起動 + coldplug 完了 | 1.45 → 1.96 | 1.45 → 2.13 | kernel 原点。旧 unit の weston はこれを待っていた |
| weston 起動 → READY(systemd-notify) | 1.99 → 2.11 | 1.65 → 1.81 | kernel 原点。card0 直後版は coldplug を待たず card0 出現で起動 |
| kmm: wayland socket → READY(初回 expose) | 2.10 → 2.58 | 1.83 → 2.17 | kmm 本体は 1.52〜1.56 に並行起動済みで socket を待つ。Qt/fontconfig 初期化 0.34〜0.47s |
| **合計(電源 → GUI)** | **3.59s** | **3.19s** | 平均は 3.71s(σ0.08、N=5)/ 3.17s(σ0.07、N=10) |

読み方: SPL 区間 0.80s、カーネル 1.35s(ジャンプ→PID1)、userspace 1.44s / 1.04s。
残る大物はカーネル→PID1(この boot では 1.13s、/memory 修正 8d1bcac 後の現行は 0.77s。旧 unit が coldplug を待っていた 0.34s は #14 で回収済み)。kmm の socket→READY 0.35〜0.47s は Qt 初期化そのもの。

## 残り候補

最新の残り候補と採否は open-issues #7 を正とする(この節の旧リストは
全施策消化済みのため削除)。ROM 区間の eMMC fast boot 化は fuse 不可逆の
わりに上限百 ms 級のため**保留を決定**(2026-09-03、調査の全容:
[07-emmc-boot-rom.md](07-emmc-boot-rom.md))。

- (2026-09-07) 再計測の方法: t0 = DP100 の出力 ON 送信(HID フレーム送出の瞬間)、電源→SPL バナー/
  カーネル時刻原点はシリアル(/dev/ttyUSB1、chunk ごとに epoch)、GUI = journal の kmm READY
  (Type=notify、初回ウィンドウ表示)を kernel 原点に足す。電源→SPL 0.21s、→カーネル 1.02s は両構成で同一。
  weston 起動: 製品 unit 3.22〜3.52s / card0 直後 2.70〜2.87s。weston→kmm READY: 0.35〜0.51s /
  0.36〜0.49s(外れ値 0.95s が 1 本)。
- (2026-09-07、#13 後) 旧 unit: weston 3.13〜3.48s、READY 3.59〜3.80s。card0 直後(#14): weston 2.72〜2.85s、
  READY 3.08〜3.27s、weston→READY 0.33〜0.43s で外れ値なし(N=10)。
- (2026-09-07、名前一掃 7d3a64e 後の再計測、同構成) **3.19s(σ0.06、N=10、3.11〜3.27)**、
  10/10 で SPL ロゴ blit あり。

## 電源断直後の起動が 1 秒遅い(解決、2026-09-07)

GUI 表示直後(電源 ON から 3.2〜4.5s)に電源を切ると、次の起動が 4.2s(通常 3.2s)になる。
falcon 経路のままで(bos=1)、遅れは userspace: systemd-random-seed が 1.44→2.65s、
`crng init done` 2.65s、weston 起動 2.70s(通常 1.58s)。journal に
"Kernel entropy pool is not initialized yet, waiting until it is." = seed が credit されなかった。

機序(systemd v255 `src/random-seed/random-seed.c`): load は二重 credit 防止のため
先に seed ファイルの xattr `user.random-seed-creditable` を外して **fsync** し、credit した
あと新 seed を書いて fsync、最後に xattr を付け直すが**付け直しは fsync しない**。
ext4(/data、commit 既定 5s)の journal commit 前に電源が切れると「印が無い」状態だけが
永続化され、次回は credit なし → CRNG はジッタ初期化(~1.1s)待ち → weston/kmm
(seed の Before=)がその分遅れる。perf-boot の通常計測(前回起動が 26s)では commit 済みで
再現せず、手動の短い電源入れ直しで見える。

修正(#15): seed unit に `ExecStartPost=/bin/sync` を追加し、印を即座に永続化する。
残る窓は xattr を外して付け直すまでの数十 ms のみ(その場合も次回 1 回だけ 1 秒遅く、自己回復)。

## card0 直後起動の外れ値(解決、2026-09-07)

card0 直後起動で kmm READY が 2.18s と 2.55〜2.68s(kernel 原点)の二峰になっていた原因:

- **kmm 主スレッドが fontconfig 初期化の `getrandom(16, 0)` で CRNG 初期化待ちにブロック**
  (全 syscall strace で 354ms、遅い boot のみ)。カーネルは `wait_for_random_bytes()` →
  `try_to_generate_entropy()` で呼び出しスレッド上をスピンするため、遅い boot で kmm の
  stime が 3 倍(70〜86 tick vs 23〜26)に見えていた。READY は `crng init done` の時刻に
  1:1 で追従(無摂動 18/18 boot)。
- CRNG は systemd-random-seed の seed credit(8MM 由来、[04-pitfalls #21](../imx8mm-xpi-bringup/04-pitfalls.md))で
  初期化されるが、その unit は `RequiresMountsFor=/var/lib/systemd/random-seed` と
  volatile-binds が張る `var-volatile-lib.service: Before=systemd-random-seed.service` で
  /var/lib の volatile overlay → var-volatile.mount → local-fs-pre.target にゲートされていた。
- 遅い boot では var-volatile.mount のジョブが 1.40s でなく udev coldplug 終了+約 300ms(2.25s)
  まで dispatch されない。PID1 を strace した結果、PID1 は 1.4〜3.0s の間一度も idle にならず
  systemd タグ付き udev デバイス 49 個(tty 22 / block 21 / net 4)のイベントを連続処理していた。
  systemd v255 の sd-event でジョブ run queue は最低優先(IDLE=100)、udev device monitor は
  NORMAL(0)なので、イベントが途切れない間 run queue は飢餓する。local-fs-pre 到達(約 1.40s)が
  イベント流入開始より先か後かの約 20ms のレースで遅速が決まる(無摂動 10 boot で 4/10 遅)。
- 修正(#13): seed の実体は /data/random-seed で /var/lib を待つ必要がないため、
  systemd-random-seed.service を `/etc` に丸ごと置き(udev-slim)`Requires/After=data-mount.service`
  に直結、volatile-binds の bbappend で var-volatile-lib.service から Before=/WantedBy= を剥がす。
  drop-in では依存を消せない(空代入 no-op)ので両方とも unit 差し替え/sed。
- 8MM のエントロピー枯渇(pitfall #21)とは「CRNG 未初期化で getrandom がブロック」の末端が同じで、
  8MM は種そのものの不足、8MP は種はあるが蒔く係が udev の行列に並ぶ問題。8MM で未特定だった
  ブロック関数はこれで確定。
- 残課題(open-issues): udev の systemd タグ対象(tty 22 個)削減による PID1 負荷低減、
  CAAM ビルトイン化で seed 自体を不要にする案。
