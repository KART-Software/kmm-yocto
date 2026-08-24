# 11 — スプラッシュ最適化(暗転ゼロ + ロード実質ゼロ)

[Falcon Mode](08-falcon.md) の起動スプラッシュ(SPL が [eLCDIF](00-glossary.md#g-elcdif)/DSIM/LT9611
を直叩きしてロゴを出す。表示チェーン確立の経緯は [04-pitfalls](04-pitfalls.md) #22/#23)を、
**「ロゴ → GUI 間の暗転をゼロ」**かつ**「SPL のスプラッシュコストを実質ゼロ」**にするまでの記録。
すべて XPI-iMX8MM 実機で実測(2026-08-17)。

**結論(実測):**
- ロゴ → GUI の暗転を **seamless takeover** で除去(カーネルが SPL 駆動中の表示を殺さず引き継ぐ)。
- SPL がスプラッシュ画像を運ぶ時間を **1887ms → 0(手続き描画で画像を運ばない)** に。固有コストは blit **~10ms** のみ。
- HDMI 出力 ON を前倒しし、ロゴ表示を **~631ms 前倒し**(電源投入直後にほぼ即ロゴ)。

配布は **flash.bin(SPL)の書き換えが必要**(OTA では配れない。後述)。

---

## 課題 — 2 つの独立した問題

1. **暗転**: SPL が描いたロゴと、カーネルの [DRM](00-glossary.md#g-drm) が表示を握り直すまでの間に画面が黒くなる。
2. **ブートコスト**: スプラッシュ画像(1920×792 XRGB = 6MB)を [falcon.itb](08-falcon.md) の FIT loadable
   として [FB](00-glossary.md#g-framebuffer) にロードするのに **~1.4s** かかっていた。

この 2 つを別々の機構で潰す。

---

## ⓪ 前提 — そもそも SPL で画像を出す(表示チェーンを SPL から直叩き)

最適化以前に、**電源投入直後に画面を光らせること自体**が最大の難関だった
(詳細は [04-pitfalls](04-pitfalls.md) #22/#23)。

**なぜ SPL でやるしかないか**: カーネルの fbcon ロゴを試すと、初回モードセット
(mxsfb→LT9611→HDMI の有効化チェーン)が **~2s** かかり、これがブート序盤に
前借りされて kernel→GUI が +1.6s 悪化した(#22、実測棄却)。この表示チェーンでは
「電源→約 2.4s より前に画面が光る」のはカーネル段では無理。**早期ロゴは
SPL/U-Boot 段で eLCDIF を直叩きするのが唯一の道**。

**SPL には表示ドライバが無い**ので、表示チェーン全段をレジスタ直書きで叩く:
GPC(DISPMIX/MIPI 電源)→ ANATOP/CCM(VIDEO_PLL1・各クロック)→ DISP blk-ctrl
→ **eLCDIF**(タイミング・FB アドレス・RUN)→ **Samsung DSIM**(MIPI DSI 4-lane,
648Mbps/lane の初期化列)→ **LT9611**(DSI→HDMI ブリッジ、I2C 設定・PLL ロック)。
定数は全て **Linux 動作中の実機レジスタダンプから移植**した(SPL は DT も
ドライバも使えないため、動いている状態を丸ごと再現する)。

**最大の落とし穴 — LT9611 PCR の位相抽選**(#23): LT9611 の PCR(Pixel Clock
Recovery)は**周波数だけを合わせ、位相はロック瞬間に 1 回捕捉したものが持続**する。
アクティブ 800×480 を素直に出すと DE 充填率 36% で、FIFO と DE 窓の位相関係に
複数の安定点(多安定)が生まれ、**再ロックごとにどれかに落ちる=抽選**。症状は
~1/4 の確率でロゴ/GUI 全体が横に ±46px(≈hsync 幅)ずれる。カーネルのレジスタ
完全一致再現・温間コールド化・PCR リセット連打・密ラスタ化…全部試しても消えず。

**最終解 — 黒埋め広 DE**: アクティブを **1920×792 の黒埋めラスタ**に拡張
(ラスタ 2200×818 @ **108MHz**、充填率 **87%**)。充填率だけを上げると
ロックが一意化して抽選が消えた(実績クロック値は全部維持)。パネルが物理表示
するのは左上 800×480 だけで、残りは黒で埋める。

→ **この「黒埋め」が SPL の fill そのもの**。SPL が fill で FB 全面を先に塗るのは
「背景色を出す」ためだけでなく、**この表示ロックを一意化する**ため。fill を抜く
実験(§⑨)でブートが非決定的になったのは、まさにこの位相抽選が復活するから。

---

## ① 暗転ゼロ化 — seamless takeover

カーネルの表示ドライバは通常、probe/modeset でパイプラインを**リセットして初期化し直す**。
これが SPL 駆動中の表示を一度殺し、暗転を生む。以下のパッチで「SPL が同一モードで駆動中なら
リセットせず**引き継ぐ**」ようにする(`kas/imx8mm-splash.yml` が配線):

| パッチ | 対象 | 効果 |
|---|---|---|
| 0004 gpcv2 | 電源ドメイン | dispmix/mipi を ALWAYS_ON 養子縁組(ADB400 電源断失敗の根治)|
| 0005 blk-ctrl | ドメイン/クロック | LCDIF/DSI ドメイン養子縁組 + クロック恒久ピン |
| 0006 lt9611 | probe | ハードリセット抑止(ロゴ即死防止)|
| 0007 lt9611 | 初回 enable | `msleep(500)` + PCR リセットを回避 |
| 0008 samsung-dsim | 初回 enable | SWRST 付き再初期化と MDRESOL 書き直しをスキップ |
| 0009 mxsfb | 初回 modeset | eLCDIF リセットを回避し、初回モードセットをフリップ扱いに(`cur_buf` を触らず SPL の FB を維持)|

**発動条件**: falcon DTB の `/chosen` に `kart,splash-active` があり、**かつ実機レジスタが要求モードと
一致**する時だけスキップ。不一致なら従来のフル再初期化へ**安全にフォールバック**(= 暗転はするが確実に映る)。

`kart,splash-active` は `kart-falcon-itb.bb` が falcon DTB へ `fdtput` で焼き込む
(SPL 実行時セットは未実装のため。splash 無しビルド・他マシンは無変更)。

dmesg で発火を確認:
```
kart splash: adopting running domain            (0004/0005)
kart splash: chip alive, skipping reset          (0006)
kart splash: seamless LCDIF takeover             (0009)
kart splash: seamless takeover (1920x792)        (0007)
```

---

## ② splash ロードが遅い真因

素朴には「6MB のロードなんて 40MB/s なら 0.15s」のはず。ところが実測は **~4MB/s**。理由:

- スプラッシュ画像は生ピクセル(XRGB8888)を **FB 物理アドレス(0xBFA00000)へ直接ロード**する。
- SPL は fill → 表示チェーン init で **eLCDIF の RUN を立てる**(スキャン開始)。その後に FIT が
  画像をロードする。つまり **eLCDIF が同じ FB を全力でスキャン中(1920×792×4 × ~60Hz ≈ 365MB/s)**に、
  CPU が同じ FB へ書き込む。表示 DMA が DDR/NoC 帯域を食い、CPU 書き込みが餓死する。
- fill(全面 BG 塗り)は RUN 前なので競合せず速い(285ms の "ready" に収まる)。**遅いのはロードだけ。**

→ 対策は「**FB へ書くバイトを減らす**」か「**RUN 前(競合前)に書く**」。

---

## ③ 最適化の推移(実測 FIT ロード時間)

計測点は SPL ログの `spl: falcon_args_file …`(FIT ロード開始) → `Falcon:`/`splash: logo on`(完了)。

| 方式 | raw サイズ | FIT ロード | vs no-splash(495ms)| 配布 |
|---|---|---|---|---|
| 元・全面 | 6MB(1920×792)| **1887ms** | +1392ms | OTA |
| crop(可視域 rows 0–479)| 3.69MB | 1388ms | +893ms | OTA |
| ロゴ帯(rows 185–289 + load offset)| 0.81MB | 699ms | +204ms | OTA |
| **手続き描画(1bit マスク SPL 埋め込み)** | **画像を運ばない** | **499ms ≈ no-splash** | +4ms | **flash.bin** |

パネルは 1920×792 DE の**左上 800×480 しか物理表示しない**(#22/#23)。ロゴは 560×93 でその中央。
SPL の fill が全面 BG を塗るので、**raw はロゴ帯だけあればよい**(帯以外は fill の BG が残る)。
crop・帯版はこの原理で OTA(falcon.itb)だけで配れる。

---

## ④ 手続き描画(最終形)

画像を「運ぶ」のをやめ、**ロゴを 1bit マスクとして SPL コード(flash.bin)に埋め込み**、
`kart_splash_prepare()` の fill 直後・**RUN 前**に `bit=1` の画素だけ FB へ白を書く。

- `scripts/gen-splash-raw.py` が `logo/kart_logo.png`(純白の線画 + alpha)を alpha 閾値で 1bit 化し、
  `kart_splash_logo.h`(幅/高さ/パネル内座標 + packed ビット列、**6.5KB**)を生成。
- u-boot 側パッチ `0010` の `kart_splash_blit_logo()` が RUN 前に blit(競合ゼロ、6.5KB のみ)。
- `kart-falcon-itb.bb` は falcon.itb の splash loadable を**廃止**(画像を運ばない)。
- ヘッダは `u-boot-fslc_%.bbappend` の `do_configure:prepend` で SPL ソースへ配置。

結果: falcon.itb 21.5MB(元 27MB)、SPL の splash 固有コストは **blit ~10ms**("ready" 285→295ms)のみ。

---

## ⑤ 出力 ON 前倒し

手続き描画ではロゴが `prepare()` 時点で FB に載る。そこで **HDMI 出力 ON(`lt_wr(0x8130,0xea)`)を
`finish()`(FIT ロード後)から `prepare()` 末尾へ前倒し**した(0010 に同梱)。

| イベント(SPL banner 相対)| 旧 | 新 |
|---|---|---|
| ロゴ表示(logo on)| 1244ms | **613ms** |

**−631ms**。表示 init が終わった瞬間にロゴが出て、その裏でカーネルの FIT ロード(~500ms)が走る。

---

## ⑥ 配布の現実 — flash.bin は OTA 不可

手続き描画・出力前倒しは **SPL コード = `flash.bin`**。[OTA](../archive/rpi5/ab-ota.md) は rootfs + falcon.itb + U-Boot env
しか触らないので、**この最適化は OTA では配れない**。更新には eMMC のブートローダ書き換えが要る。

- **falcon 版 flash.bin は [UUU](00-glossary.md#g-uuu-universal-update-utility) で RAM 起動できない**
  (falcon SPL は SDPV ハンドシェイクを受けない)。UUU 経路は常に stock 退避版
  (`local/recovery/flash.bin-stock`、`scripts/kart-boot.uuu`)。
- **eMMC への flash.bin 書き込み(A コピーは 33KiB オフセット):**
  - **Linux 起動中**: `dd if=flash.bin of=/dev/mmcblk2 bs=1k seek=33`(busybox は `conv=` 非対応。plain dd + `sync`)。
    SPL は起動時しか読まれないので実行中書き込みは安全。**最も簡単。**
  - **SDP(S1=Serial)時**: stock U-Boot を `uuu scripts/kart-boot.uuu` で上げ、`ums 0 mmc 2` で eMMC を
    PC に露出 → dd。
  - 失敗しても既知 flash.bin を書き戻せば復旧可(ブリックしない)。手順詳細は `imx8mm-xpi-bench` skill 参照。

---

## ⑦ 最終 timing 内訳(電源 → GUI、手続き描画 + 前倒し)

SPL(banner 相対、シリアル実測):
```
0ms      U-Boot SPL banner
319ms    SEC0/RNG(SPL 早期 init)
613ms    ready(fill + ロゴ blit + LCDIF/DSIM/LT9611 init、295ms)→ ★ロゴ表示
756ms    falcon_args(eMMC/env)
1253ms   Falcon:(FIT ロード = atf+kernel+fdt 完了、~499ms。この裏で既にロゴ表示中)
~1341ms  kernel-0(BL31 → カーネル)
```
カーネル(kernel-0 相対、systemd 実測):
```
511ms    userspace 開始
3040ms   weston 稼働
3070ms   seamless takeover(SPL ロゴ → カーネル DRM、暗転なし)
3539ms   kmm 稼働 = GUI 描画
```
| フェーズ | 時間 |
|---|---|
| BootROM + DDR 訓練 + SPL ロード | ~1.0–1.5s(推定・シリアル前で無音)|
| SPL(banner → kernel)| ~1.34s(splash 固有は ~10ms)|
| カーネル → GUI | ~3.54s |
| **電源 → GUI** | **~6s** |

---

## ⑧ weston カーテンの 0.5s — kart-splash-wl で解決 (2026-08-24)

seamless takeover は「SPL ロゴ → カーネル DRM」の暗転を消す。だが **weston(kiosk-shell)が起動
して自分の背景色 `#10141c` で画面を塗り、kmm が初回フレームを描くまでの ~0.5s** は、ロゴが消えて
無地の紺になる(Web カメラ 10fps 実測: SPL ロゴ 2.4s → 暗転 0.5s → GUI)。

### 検討した選択肢と決着

- **kiosk-shell に background-image をパッチで足す** — 当初の本命だったが、weston 13 の
  kiosk-shell 背景は `weston_curtain` = **単色専用**で、compositor 内部から任意画像バッファを
  surface に貼る公開 API が無い(SHM buffer は wl_client 前提)。renderer 直叩きの大工事に
  なるため撤回。
- **kmm の初回フレームをロゴに(app 側)** — Qt 初期化の後にしか描けないので 0.5s の
  後半しか縮まない。
- **採用: 専用スプラッシュクライアント `kart-splash-wl`**(`recipes-graphics/kart-splash-wl/`)。
  SPL と同一の絵(BG `#10141c` + 白ロゴ、`kart_splash_logo.h` を u-boot と FILESEXTRAPATHS で
  単一ソース共用、同一座標)を描くだけの極小 wl_shm クライアント(C 約 200 行、Qt 不使用)。
  weston 直後に起動し、**kiosk-shell は最後にマップされた surface を前面に置く**ため、
  kmm 表示で自然に背面へ隠れる。

### 結果 (カメラ実測)

暗転 **0.5s → 約 60ms の一瞬き**。遷移は「SPL ロゴ → 一瞬 → クライアント版ロゴ
(同一の絵)→ GUI」となり、6fps タイルでは暗転コマゼロ。副次効果: クライアントは
常駐なので **kmm が再起動する間もロゴが出る**(ダークトーン画面の根絶)。

### 残る ~60ms の正体と、hold-first-repaint パッチの試行と撤回 (2026-08-25)

残る一瞬き (30fps 解析で Y 132→118 の 2 フレーム谷) はコンポジションの内容では
なく **weston 初回 KMS コミットのモードセット瞬断**: weston は初回に自分の知らない
plane/CRTC を一度リセットする (state_invalid) 設計で、imx の LCDIF/DSIM は同一
モードでも fastset せず CRTC を disable→enable するため、DSI→LT9611→パネルの
信号が数十 ms 途切れる。

これを消そうと「最初のクライアントがマップされるまで初回リペイントを保留する」
kiosk-shell/libweston パッチ (hold-first-repaint) を実装・実機比較したが、
**hold あり Y→118 / なし Y→120 の同型 2 フレーム谷**で肉眼・計測とも区別不能
(hold が消せるのは紺カーテンのフレームだけで、splash-wl 導入後それは元々
1-3 フレームしかなく、モードセット瞬断に埋もれていた)。利得ゼロのパッチを
weston コアに抱える価値は無いと判断し**撤回**した。

根絶するなら (将来課題): weston drm-backend の「既存 KMS 状態の継承」
(state_invalid をやめ現状を取り込んで pageflip で入る) か、LCDIF/DSIM の
fastset 実装。どちらも重く、表示チェーンは位相抽選 (#17/#22/#23) の前科がある
リスク地帯なので、60ms は受容が現実解。

### 測定手法 (再利用可)

`imx8mm-xpi-bench` skill の Web カメラ節そのまま: 録画(bg)→ dp100 cycle →
`ffprobe signalstats` の YAVG 遷移で区間時刻を出す(SPL ロゴ Y~115 / 暗転 Y~75 /
GUI Y~145)→ `fps=6 tile` のモンタージュで目視。

---

## ⑨ 補足実験 — fill を抜くとどうなるか

⓪の「fill は表示ロックの決定化のため」を実機で確認した(SPL から fill ループを
外した flash.bin を焼いて観測):

- **コールドブート(電源投入)では通る**: 電源断直後の DRAM はほぼゼロ(黒)なので、
  ロゴが黒背景に出て GUI まで起動する。**砂嵐(garbage)は出ず、見た目は fill あり
  とほぼ同じ**(#10141c と 0 はカメラで見分けられない暗色)。`ready (294 ms)` も
  fill あり(295ms)と変わらない — fill 自体はキャッシュ内で数 ms、遅くはない。
- **ただし非決定的**: leftover の DRAM(ウォームリブート等で FB 領域に前の内容が
  残る)だと DE 充填が崩れて位相ロックが揺れ、**SPL の splash init 途中でハング**する
  事例を観測(`splash: fb clk pwr …[rev e2]` の後で 75s 無出力)。

→ 結論: **fill は必須**。見た目(背景色)のためではなく、⓪の位相抽選を潰して
ブートを決定的にするため。消すと「コールドは通るがウォームで稀にハング」という
不安定なブートローダになる。

---

## 関連
- [08-falcon.md](08-falcon.md) — Falcon Mode(この最適化の前提)
- [04-pitfalls.md](04-pitfalls.md) #22/#23 — SPL 表示チェーン確立(LCDIF/DSIM/LT9611 の高クロックラスタ)
- [09-boot-sequence.md](09-boot-sequence.md) — 電源→GUI のブートシーケンス全体
- [A/B OTA (archive/rpi5)](../archive/rpi5/ab-ota.md) — OTA(flash.bin を触らない理由)
- `imx8mm-xpi-bench` skill — 電源(DP100)/シリアル/UUU/eMMC flash.bin 書き込みの操作手順
- コミット `b3f4903` — 実装一式
