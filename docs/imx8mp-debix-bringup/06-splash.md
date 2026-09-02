# 06 — SPL スプラッシュと seamless takeover(2026-09-02 実機確定)

電源投入 **+0.7s** で SPL がロゴを点灯し、falcon 経路ではそのまま
**一度も消えずに** weston → kmm(GUI)へ引き継ぐ。8MM
([../imx8mm-xpi-bringup/](../imx8mm-xpi-bringup/) の SPL 手続き描画 +
seamless takeover)と同型の設計を、8MP の表示チェーンに再実装したもの。
カメラの輝度タイムライン判定(下記「検証手法」)で falcon/proper 両経路 PASS。

## 構成物

| 何 | どこ |
|---|---|
| SPL 側実装(表示チェーン直叩き + ロゴ blit + proper 用停止) | `meta-kart/recipes-bsp-imx/u-boot/files/0005-imx8mp-debix-spl-splash.patch`(kart_splash.c/.h + spl.c フック) |
| SPL config | `debix-splash.cfg`(CONFIG_KART_SPL_SPLASH) |
| ロゴ画素 | `kart_splash_logo.h`(8MM/kart-splash-wl と単一ソース)→ ビルド時に `logo.bin` へ変換(`kart-falcon-itb.bb`)し boot パーティションから供給 |
| カーネル takeover パッチ | `meta-kart/recipes-kernel-imx/linux/files/0010〜0013`(下記) |
| busfreq 無効化 | `imx8mp-debix.dts`(`&{/busfreq} status="disabled"`) |
| kas 配線 | `kas/imx8mp-splash.yml`(u-boot 側 + `pn-linux-fslc-imx` 側) |
| weston 区間の連続化 | `kart-splash-wl`(8MM と共通レシピ。`kart-image.bb` の imx8mp-debix 追加分) |

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
| **falcon**(通常) | 表示を回したまま渡す。`/chosen` に `kart,splash-active` を注入し、/memory から FB の 2MB(0xBFE00000〜)を隠す | カーネル側 takeover(下記)が引き継ぐ |
| **proper**(フォールバック) | **必ず停止してから渡す**(`kart_splash_quiesce()`: LCDIF EN 落とし → DISP_PARA off → PHY 電源断) | proper U-Boot は **DDR 最上部 = FB 直上へ自己再配置**し、extlinux 経由の DTB には prop も /memory 隠しも無い。表示を回したまま渡すと、ブート途中の恒久ハングやカーネル text 破壊のパニックになる(両方実測)。フォールバック経路の黒画面は許容 |

## カーネル seamless takeover(0010〜0013 + busfreq 無効)

すべて `/chosen kart,splash-active` があるときだけ発火(無ければ完全に従来動作)。

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
