# 06 — SPL スプラッシュと seamless takeover(2026-09-02 実機確定)

電源投入 **+0.7s** で SPL がロゴを点灯し、falcon 経路ではそのまま
**一度も消えずに** weston → kmm(GUI)へ引き継ぐ。8MM
([../imx8mm-xpi-bringup/](../imx8mm-xpi-bringup/) の SPL 手続き描画 +
seamless takeover)と同型の設計を、8MP の表示チェーンに再実装したもの。
カメラの輝度タイムライン判定(下記「検証手法」)で falcon/proper 両経路 PASS。

## 構成物

| 何 | どこ |
|---|---|
| SPL 側実装(表示チェーン直叩き + ロゴ blit + proper 用停止) | `meta-kart/recipes-bsp-imx/u-boot/files/0005-imx8mp-debix-spl-splash.patch`(spl_splash.c/.h + spl.c フック) |
| SPL config | `debix-splash.cfg`(CONFIG_SPL_SPLASH) |
| ロゴ画素 | `spl_splash_logo.h`(8MM/splash-wl と単一ソース)→ ビルド時に `logo.bin` へ変換(`falcon-itb.bb`)し boot パーティションから供給 |
| カーネル takeover パッチ | `meta-kart/recipes-kernel-imx/linux/files/0010〜0013`(下記) |
| busfreq 無効化 | `imx8mp-debix.dts`(`&{/busfreq} status="disabled"`) |
| kas 配線 | `kas/imx8mp-splash.yml`(u-boot 側 + `pn-linux-fslc-imx` 側) |
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
- 初期化完了まで **24ms**(DDR init 直後に実行)。ロゴ blit は falcon の FAT が
  使える時点で `logo.bin` から(下記 ROM 上限のため)
- **ROM ブートイメージのローダ全長上限**: ロゴを SPL に埋め込むと
  pad4(spl.bin)+0x14000+1404 が上限を超え、**DDR firmware の尻尾が黙って切られて
  Training FAILED で文鎮化**する(実測: 全長 0x3c990=OK / 0x3e1c8=NG)。
  SPL のサイズを増やす変更をしたら、ビルド後に全長 < 0x3d000 を確認する

## ハンドオフは 2 経路で真逆

| 経路 | SPL の挙動 | 理由 |
|---|---|---|
| **falcon**(通常) | 表示を回したまま渡す。`/chosen` に `splash-active` を注入し、/memory から FB の 2MB(0xBFE00000〜)を隠す | カーネル側 takeover(下記)が引き継ぐ |
| **proper**(フォールバック) | **必ず停止してから渡す**(`spl_splash_quiesce()`: LCDIF EN 落とし → DISP_PARA off → PHY 電源断) | proper U-Boot は **DDR 最上部 = FB 直上へ自己再配置**し、extlinux 経由の DTB には prop も /memory 隠しも無い。表示を回したまま渡すと、ブート途中の恒久ハングやカーネル text 破壊のパニックになる(両方実測)。フォールバック経路の黒画面は許容 |

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
ならない — レジスタが全部合っていても PHY 電源ひとつで絵は出なかった):

```bash
# カメラは udev 安定名 /dev/kart-debix-cam (C930e、/etc/udev/rules.d/99-kart-cam.rules)
./boot-visual-check.sh /dev/kart-debix-cam out 30   # 録画 + dp100 cycle + 輝度タイムライン
# 期待 (falcon): 電源 ON ~0.7s 後に Y が跳ね、GUI まで暗転イベントなし
# 期待 (proper): 「splash: off (proper handoff)」がシリアルに出て、暗いまま ~11s で GUI
```

判定実績: falcon = 点灯 4.5s(録画時刻)→ 以後暗転ゼロで GUI(Y≈120 ロゴ →
Y≈165 GUI)。proper = 停止発火 → ハングなしで GUI → falcon-rearm が
boot_os=yes を自動補充。

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
