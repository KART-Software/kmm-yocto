# 06 — SPL スプラッシュと seamless takeover(HDMI 2026-09-02、LVDS 2026-11-11 実機確定)

表示はビルドで LVDS(J10 のパネル、既定)か HDMI を選ぶ(machine の `DEBIX_DISPLAY`、
[../usage/01-build.md](../usage/01-build.md)「DEBIX の表示」)。SPL に入るのは片方の経路だけ
(下記「ROM ブートイメージのローダ全長上限」)。以下の HDMI の記述のあとに LVDS の節がある。

電源投入 **約 +0.5s**(SPL バナーから 0.31s、シリアル実測 N=5)で SPL がロゴを点灯し、falcon 経路ではそのまま
**一度も消えずに** weston → kmm(GUI)へ引き継ぐ。8MM
([../imx8mm-xpi-bringup/](../imx8mm-xpi-bringup/) の SPL 手続き描画 +
seamless takeover)と同型の設計を、8MP の表示チェーンに再実装したもの。
カメラの輝度タイムライン判定(下記「検証手法」)で falcon/proper 両経路 PASS。

## 構成物

| 何 | どこ |
|---|---|
| SPL 側実装(表示チェーン直叩き + ロゴ blit + proper 用停止) | `meta-kart/recipes-bsp-imx/u-boot/files/0005-imx8mp-debix-spl-splash.patch`(spl_splash.c/.h + spl.c フック)。LVDS の経路は `0009-imx8mp-debix-spl-splash-lvds.patch` |
| SPL config | `debix-splash.cfg`(CONFIG_SPL_SPLASH)。LVDS は `debix-splash-lvds.cfg`(CONFIG_SPL_SPLASH_LVDS、machine conf の `DEBIX_SPLASH_UBOOT_CFG` が表示に合わせて足す) |
| ロゴ画素 | `spl_splash_logo.h`(8MM/splash-wl と単一ソース)→ ビルド時に `logo.bin` へ変換(`falcon-itb.bb`)し BOOT 領域に置く(`kas/imx8mp-falcon.yml`。表示やスプラッシュの有無によらず全イメージ)。SPL は A/B の面に関係なく p1 のものを読む(ロゴは更新しない前提) |
| カーネル takeover パッチ | `meta-kart/recipes-kernel-imx/linux/files/` の HDMI 0010〜0013、LVDS 0015〜0018(下記)。表示ごとに常に入る(`linux-fslc-imx_%.bbappend`。SPL の印が無ければ従来動作なので、SPL だけ先に更新した機体でも壊れない) |
| busfreq 無効化 | `imx8mp-debix.dts`(`&{/busfreq} status="disabled"`) |
| fbdev エミュレーション無効 | `slim-imx8mp.cfg`(LVDS の節を参照) |
| kas 配線 | `kas/imx8mp-splash.yml`(u-boot 側のみ) |
| weston 区間の連続化 | `splash-wl`(8MM と共通レシピ。`kart-image.bb` の imx8mp-debix 追加分) |

## 表示チェーン(SPL が直接叩く順)

```
CCM (HDMI AXI/APB/24M ゲート)
→ GPC: HDMIMIX (map bit16 / PGC26) と HDMI_PHY (map bit17 / PGC27) ← 別ドメイン
→ HDMI blk-ctrl @32fc0000 (RESET_CTL0/CLK_CTL0/CLK_CTL1 の ON 儀式 + 各ドメインビット)
→ Samsung HDMI PHY @32fdff00 (33.75MHz の 48 バイト表 = phy-fsl-samsung-hdmi.c の値)
→ DW-HDMI TX v2.13a @32fd8000 (バイトレジスタ stride1、DVI モード)
→ PVI @32fc4000 → LCDIFv3 @32fc6000 (800x480、FB 0xBFE00000 ARGB8888)
→ TFP401 パネル (800x480@33.75MHz、sync 両負)
```

要点(踏んだ罠):

- **ピクセルクロックは PHY の PLL が生成して LCDIFv3 へ「逆流」する**。
  HDMI_PHY の GPC ドメイン(PGC27)を上げ忘れると PLL が回らず、
  LCDIF の CTRLDESCL0_5 で SHADOW_LOAD ビットが落ちない(= vsync が来ていない)
  という形で現れる。デジタル系レジスタが全部正しくても絵は出ない
- 初期化完了まで **24ms**(DDR init 直後に実行)。ロゴは SPL に埋め込まず(下記 ROM 上限のため)、
  eMMC の初期化直後に p1 の `logo.bin` を読んで blit する。env の読み込み(0.14s)と falcon.itb の
  ロードを待たない。面を選ぶ差し替え口(`spl_mmc_fs_boot_partition()`)の先頭で、p1 を FAT 層へ
  直接登録して読む。spl_fat.c の登録済みフラグは立てないので、その後 falcon は選んだ面を登録し直す。
  proper 経路でもロゴは出て、proper へ渡す前に表示を止める
- **ROM ブートイメージのローダ全長上限**: ロゴを SPL に埋め込むと
  pad4(spl.bin)+0x14000+1404 が上限を超え、**DDR firmware の尻尾が黙って切られて
  Training FAILED で文鎮化**する(実測: 全長 0x3c990=OK / 0x3e1c8=NG)。
  SPL のサイズを増やす変更をしたら、ビルド後に全長 < 0x3d000 を確認する。今は HDMI 版が
  u-boot-spl.bin 166,442B・全長 0x3cfa8(残り 88B)、LVDS 版が 165,762B・0x3cd00(残り 768B)。
  HDMI と LVDS の経路を両方入れる余地は無いので、Kconfig(SPL_SPLASH_HDMI / _LVDS)で片方だけ入れる。A/B 統一(04-falcon.md「A/B とスロット選択」)で増えた分を
  詰めるのに、SPL の GPT 読み取りを外し(debix-falcon.cfg)、表示の文字列も削った

## LVDS の経路(J10 のパネル、2026-11-11)

```
J10 の 5 V (LVDS_PWR_EN = GPIO4_IO25、パッド SAI2_TXC) ← パネルの VDD とバックライト (変換基板)
→ VIDEO_PLL1 1039.5 MHz (m 173 / p 2 / s 1 / k 16384、clk-pll14xx と同じ手順)
→ CCM: media_axi 500 MHz、media_apb 200 MHz、media_disp2_pix ÷42 = 24.75 MHz、media_ldb ÷6 = 173.25 MHz
→ GPC: MEDIAMIX (map bit12 / Pxx bit10 / hsk bit14 / PGC22)
→ media blk-ctrl @32ec0000: バス (bit8) → LCDIF2 の区画 (rst/clk bit11/12/24) → hurry (ARCACHE bit13-15)
  → NoC の LCDIF 読み書きの優先度 (0x32700980/0xa00)
→ LCDIF2 @32e90000 (800x480、ポーチ 8、同期 4、sync 反転なし、FB 0xBFE00000)
→ LDB_CTRL (blk-ctrl +0x5c) = 0x21 → LVDS_CTRL (+0x128) = 0x1074 → 15us → 0x1075
```

- 値は LVDS で表示中の Linux の実機レジスタダンプ、手順はカーネルのドライバ(clk-pll14xx /
  gpcv2 / imx8m-blk-ctrl / fsl-imx-ldb / phy-fsl-imx8mp-lvds)。CCM は DT の assigned-clocks と
  同じ親・レートにするので、カーネルの clk_set_rate/set_parent は「同じ値」として何もしない
- パネルの電源 (5 V) を先に入れる。パネルの RESET/STBYB は変換基板の RC で 10 / 47 ms 遅れて
  上がり、その前に LVDS が出始める。SPL の初期化は 4 ms(シリアルの `logo on`)
- カーネルの印は `/chosen/splash-lvds`(HDMI は `splash-active`)。表示ごとに印を分け、SPL と
  Linux の表示が食い違っても、引き継ぎのパッチが電源の入っていない区画を「入っている」と取り違えない。
  LVDS の SPL は、渡すカーネルの DT の `/ldb-display-controller` が無効(表示を HDMI にした
  イメージ)なら、表示を止めてから渡す(`spl_splash_kernel_match`。実機で HDMI のイメージが
  普通に起動することを確認)。HDMI の SPL で LVDS のイメージを起動したときは、LVDS の
  引き継ぎのパッチは働かず、通常どおり起動する(実機で確認)

カーネルの引き継ぎ(`splash-lvds` があるときだけ。無ければ従来どおり):

- **0015 gpcv2**: `mediamix` を「最初から ON + ALWAYS_ON」で登録(0010 の LVDS 版)
- **0016 imx8m-blk-ctrl**: `mediablk-lcdif-2` の区画のクロック (disp2/apb/axi) を恒久ピンし、
  ALWAYS_ON・初期状態 ON で登録。素のままだと最初の power_on が区画のリセットを入れて
  走査中の LCDIF2 を止める(0011 の LVDS 版)
- **0017 ldb**: bind で LDB_CTRL を 0 に戻さない(fsl-imx-ldb.c)。LDB のクロック
  (シリアルクロック)を probe の時点から恒久ピンする(imx8mp-ldb.c)
- **0018 LVDS PHY**: phy_init が LVDS_CTRL を書き直すとき、バンドギャップとチャネルの有効ビットを
  残す(素のままだと LDB の probe で LVDS の出力が止まる)
- **fbdev エミュレーション無効**(`slim-imx8mp.cfg`、8MM の display.cfg と同じ): 有効だと
  imx-drm の束ねの直後(カーネル 0.32 s)に fbcon が表示を取ってモードセットし、ロゴが weston
  まで黒になる(LVDS のパネルは常に接続なので必ず起きた)
- LCDIFv3 のドライバは probe でも runtime resume でもリセットしない(リセットのビットを下ろすだけ)
  ので、HDMI と同じくパッチは要らない。weston の初回 modeset は LDB_CTRL・LVDS_CTRL に同じ値を
  書き、PHY はバンドギャップが立っているので待たずに済む

検証(2026-11-11、製品構成 = falcon + splash + M7):
- AprilTag の 3 段(下記「検証手法」の lcd-validation)をコールド起動で 3 回: SPL の段 →
  weston の段 → GUI の段が、どれも**黒いフレーム 0**(各 約 670 フレーム)で続いた。SPL の段は
  電源の投入の指示から約 1.5 s(DP100 → DC-DC の立ち上がりを含む)、weston の段はその約 2.05 s 後、
  GUI の段はさらに約 0.4 s 後
- 同じツリーの HDMI 版(表示を HDMI にしたイメージ + HDMI の SPL)も、SPL のロゴ → kmm が途切れずに
  出ることを目視で確認(`splash: fb clk pwr phy tx pvi lcdif logo on (24 ms)`、カーネルは HDMI の
  4 区画を引き継ぐ)
- proper 経路(`boot_os=no`): SPL がロゴを出して `splash: off` で止めて渡し、U-Boot proper が
  MEDIAMIX の handshake 要求 (bit14) を見て `splash-lvds` を立て(`splash: display domain live,
  kernel adopts it`)、カーネルが引き継いで kmm まで表示、falcon-rearm が `boot_os=yes` に戻した

## ハンドオフは 2 経路で真逆

| 経路 | SPL の挙動 | 理由 |
|---|---|---|
| **falcon**(通常) | 表示を回したまま渡す。`/chosen` に `splash-active` を注入し、/memory から FB の 2MB(0xBFE00000〜)を隠す | カーネル側 takeover(下記)が引き継ぐ |
| **proper**(フォールバック) | **必ず停止してから渡す**(`spl_splash_quiesce()`: LCDIF EN 落とし → DISP_PARA off → HDMI は PHY 電源断、LVDS は LVDS_CTRL と LDB_CTRL を戻す。シリアルに `splash: off`) | proper U-Boot は **DDR 最上部 = FB 直上へ自己再配置**し、extlinux 経由の DTB には prop も /memory 隠しも無い。表示を回したまま渡すと、ブート途中の恒久ハングやカーネル text 破壊のパニックになる(両方実測)。フォールバック経路の黒画面は許容 |

## カーネル seamless takeover(0010〜0013 + busfreq 無効)

すべて `/chosen splash-active` があるときだけ発火(無ければ完全に従来動作)。

- **0010 gpcv2**: `hdmimix`/`hdmi-phy` ドメインを「最初から ON +
  GENPD_FLAG_ALWAYS_ON」で登録。素のままだと genpd の帳簿(off)と実ハード(on)が
  乖離し、未使用ドメイン一斉電源断や blk-ctrl attach の過渡で PHY PLL ごと落ちる
- **0011 imx8mp-blk-ctrl**: `hdmiblk-lcdif/pvi/hdmi-tx/hdmi-tx-phy` の
  ドメインクロックを prepare_enable で恒久ピン + ALWAYS_ON 登録。
  素のままだと `clk_disable_unused` が走査中の表示ごとゲートを落とす
- **0012 dw_hdmi-imx**: probe 時の無条件 `dw_hdmi_phy_gen1_reset()` を抑止
  (TMDS ごと落ちる)。初回 modeset のリセット+全再設定は従来通り
- **0013 phy-fsl-samsung-hdmi**: probe 時の `device_reset_optional()` を抑止
  (PHY PLL = ピクセルクロック源が落ちて走査ごと死ぬ)
- **busfreq(DTS で無条件無効)**: NXP カーネルの busfreq デーモンは起動 ~10s に
  「ddrc freq set to low bus mode」で DDR を低速へ落とす。**表示 DMA が走った
  ままこの遷移が走るとカーネルが恒久ハング**(initcall の mdio_mux 直後で再現)。
  キオスクで表示は常時稼働 = 低速モードに入れる局面が無いため、遷移自体を消した

引き継ぎの絵: lcdifv3 の modeset はシャドウロード方式でリセットを伴わないため、
mxsfb(8MM)のような DRM ドライバ側パッチは**不要**。weston の初回 modeset が
FB アドレスを書き替え、次の vsync でロゴ → GUI に切り替わる。

**注意**: カーネルパッチを足すと release 文字列の `-g<hash>` が変わる。
Image だけ差し替えるベンチ更新では `/lib/modules/<release>` が空になり、
galcore(GPU)が載らず weston が `_OpenDevice FATAL` で死ぬ。モジュール一式も
セットで配る(正規はイメージ焼き直し/OTA)。

## 検証手法(ベンチ再現手順)

ロゴは目視でなくカメラで機械判定する(シリアルの `logo on` は出画の証拠に
ならない — レジスタが全部合っていても PHY 電源ひとつで絵は出なかった)。
今の判定は tools/lcd-validation の AprilTag の 3 段(SPL の logo.bin・splash-wl・kmm を
段ごとに ID の違うパターンに差し替え、`measure_boot.py --power-cycle` でどの段が前面かを
フレームごとに見る。手順は tools/lcd-validation/README.md)。期待は、各段が順に出て、
タグが 0 のフレーム(黒)が無いこと。proper 経路はシリアルに `splash: off` が出て、
暗いまま GUI まで進み、falcon-rearm が `boot_os=yes` に戻すこと。

HDMI の判定実績(2026-09、輝度タイムライン): falcon = 点灯 4.5s(録画時刻)→ 以後暗転ゼロで
GUI(Y≈120 ロゴ → Y≈165 GUI)。proper = 停止発火 → ハングなしで GUI → falcon-rearm が
boot_os=yes を自動補充。LVDS の実績は上の LVDS の節。

## 保守メモ

- 0005 は「新規 2 ファイル + Kconfig + Makefile + spl.c」の 5 diff 連結の生成物。
  ハンクを手編集せず、ソースを直して diff から作り直す(行数ズレ/fuzz 防止。
  Kconfig ハンクのベースは実 SRCREV `82d4220bc6b8...` — タグ基準だと fuzz QA で落ちる)
- takeover パッチも同様に「実カーネルソースへ改変 → diff」で生成した
  (`0010〜0013`。適用先は linux-fslc-imx = NXP BSP。8MM の 0004〜0009 は
  linux-fslc 用で互いに独立)

### 暗ブート(SPL ロゴ後に真っ黒)の真因と修正 — weston 12 kiosk-shell の seat レース(2026-09-07 確定)

調査の道筋(誤診の経緯、決め手の実験、検証表)は [08-dark-boot.md](08-dark-boot.md)。

**症状**: コールド起動で SPL ロゴの後に真っ黒のまま GUI が出ない(製品構成で ~20〜27%、
weston を card0 直後に起動する構成では ~100%)。`systemctl restart weston` で 100% 復旧。

**真因(weston `--logger-scopes=log,drm-backend,timeline` の journal と、背景色を緑にした
暗ブートの実写で確定)**: 表示ハードは無罪。暗ブート中も LCDIFv3 は weston の初回フレーム
(kiosk-shell の背景 = 黒)を正常に走査しており、初回 commit の flip 完了イベントも weston に
届いている(vblank IRQ は commit 後 5s = `drm_vblank_offdelay` の間 305 回発火して切れる。
これが以前「vblank 凍結・INT_ENABLE_D0=0」と読まれた状態)。問題はその後で、weston 12.0.4 の
kiosk-shell `desktop_surface_committed()` は surface を map するとき
`kiosk_shell_surface_activate()` の中でしかビューをレイヤ(normal_layer)に載せず、
それは `if (seat && kiosk_seat)` 条件付き。起動直後は libinput の udev 列挙(event0 が
2.1〜2.2s)より前にクライアント(splash-wl / kmm)の初回 commit(1.78s)が届くので
weston_seat がまだ無く、surface は is_mapped=true のまま**どのレイヤにも入らず永久に
合成されない**。静的クライアントは二度と commit しないので黒のまま。weston を 1s 遅らせると
seat(2.87s)がクライアント commit(2.95s)より先にできて明。restart weston が必ず直るのは
udev 済みで seat が即座にできるから。drm-image-view(compositor 無し)が無縁なのも同じ理由。
weston 13 は `kiosk_shell_output_set_active_surface_tree` で seat 非依存にレイヤへ載せるため
該当しない(8MM は 13.0.1)。

**修正**: `meta-kart/recipes-graphics/weston/files/0003-kiosk-shell-map-without-seat.patch`
(imx8mp-debix のみ)。seat が無くても normal_layer に挿入して damage し、seat 生成時に
最上位ビューを activate してフォーカスを与える。

**検証(2026-09-07)**: 製品カーネル(g276209957d88、カーネル側パッチ無し)+ weston を card0
直後に起動(After=seatd/udevd + card0 ポーリング)+ 3 段 AprilTag パターン、10 コールドで
暗 **0/10**(同構成で修正前は 8/8・11/11 暗)。LOGO ロゴ → クライアント表示は 2.03〜2.20s。

**weston 13.0.1(poky 標準)への切り替えも検証(2026-09-07)**: `imx8mp-debix.conf` で
`PREFERRED_VERSION_weston:imx8mp-debix = "13.0.1"`(meta-freescale の `:imx-nxp-bsp ??= 12.0.4.imx` を
machine オーバーライドで上書き。オーバーライド無しの代入では負ける)。パッチ無しの upstream 13 で
同条件(製品カーネル、card0 直後起動、3 段パターン、GUI 段は weston READY + 300ms)10 コールド
**暗 0/10、全て SPL → splash → GUI の順で最終 GUI**。LOGO→splash 2.05〜2.13s、LOGO→GUI 2.45〜2.56s
(12 + 0003 パッチと同等)。journal にエラー/警告無し(pixman、kiosk-shell、systemd-notify 全て 13 で動作)。
→ 8MP は 13 に揃えるのが本筋(NXP フォーク依存と 0003 パッチ、G2D の RDEPENDS 細工が不要になる)。
0003 は PV が 12 のときだけ当たるよう条件付けし、12 へ戻す場合の保険として残してある。

**否定した仮説(記録)**: カーネル側 0015〜0020(初回 enable の検証/回復、pixclk 無停止、
PHY/PVI 維持、fb 切替のみ)は全て無効。weston の commit を blocking にする、legacy SETCRTC に
置換する、VRR/max bpc を外す、seatd の VT ioctl を drm-image-view に足す、weston を root +
builtin seat で動かす、いずれも結果を変えない(暗のまま / 明のまま)。カーネルに ftrace/
tracepoint を足すと udev 列挙とクライアント起動の相対タイミングが変わり、暗率が変わる
(観測者効果の正体)。

**注意(調査で判明)**: takeover 配下の生きたパイプラインに devmem で SW_RESET を打つと、
0012/0013 が PHY/ブリッジ再初期化をスキップするため HDMI リンクが崩れ restart でも
戻らない。live 観測は読み取りにとどめること。
