# 04 — 詰まった箇所と回避策(全部)

bring up 当日に実際に踏んだ罠。同じ所で止まらないための記録。時系列。

## 1. UART 無音 → 実は電源が入っていなかった

症状: どの [UART](00-glossary.md#g-uart) からも無音。最初「出荷状態だと何も出ないのか?」と疑った。
真因: **LED 消灯 = 通電していない**。GPIO 給電に切り替えたら LED 点灯 + 出力開始。

教訓: UART デバッグの前に **LED(電源)を確認**。USB-C の C-to-C + PD 充電器は
CC 抵抗の実装次第で 5V が出ないことがある。GPIO 給電か USB-A + A-to-C が確実。

## 2. UART 文字化け → アダプタ抜き差し中の接触不良

症状: `ef bf bd`(UTF-8 置換文字)と `00` だらけ。ボーレート不一致を疑ったが、
真因は付け替え作業中の接触・断線(カーネルログに USB disconnect イベント)。
[FTDI](00-glossary.md#g-ftdi) に替えてブリッジ化したら解消。

教訓: 化けたら即ボーレートを疑う前に、**物理接続の安定**をまず確認。
J63(A コア)と J64(M コア)の取り違えもここで疑う(M コアは無音が正常)。

## 3. USB シリアルのデバイス名が挿抜で変わる

`ttyUSB0` ⇄ `ttyUSB1`、Teensy は `ttyACM0`/`ttyACM1`。挿し直すたびに ACL も消える。
→ **[udev](00-glossary.md#g-udev) ルールで権限恒久化** + `by-id` パス。詳細 [02](02-debug-setup.md)。

## 4. リブート → ipaddr 未設定で TFTP 失敗

症状: `booti` が Image magic エラー。
真因: リブートで [U-Boot](00-glossary.md#g-u-boot) env の `ipaddr` が消え、`tftp` が `*** ERROR: 'ipaddr' not set`
で失敗 → RAM に何もロードされないまま booti。

教訓: netboot 前に **serverip / ipaddr / netmask を毎回 setenv**。env は揮発する。

## 5. シリアルの `reboot` がユーザー名として食われる

症状: シリアルに `reboot\r\n` を送ったら `Password:` を聞かれて弾かれた。
真因: ベンダ Linux が **login プロンプト**を出していて、`reboot` がユーザー名扱い。
回避: **SSH 経由でリブート**(シリアルの login 迷路を避ける)。ただし ↓ の罠。

## 6. ベンダイメージに `reboot` コマンドが無い

`which reboot` が空([systemd](00-glossary.md#g-systemd) 237)。`systemctl reboot -f` は非対話 SSH から
効かないことがある。**確実に落とすには [sysrq](00-glossary.md#g-sysrq):**

```bash
ssh ... 'echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger'
```

## 7. autoboot 割り込みのタイミング勝負

症状: [SPL](00-glossary.md#g-spl) バナーは見えるのに `u-boot=>` を掴めず、ベンダ Linux が起動してしまう。
真因: スペース送信を「SPL 検出後」にしていたため、U-Boot 段の "Hit any key"
カウントダウン(SPL より後、数秒)に間に合わない。
回避: **開始直後から常時スペース連打**(SPL 中の空白は無害)。
→ より確実なのは **[SDP](00-glossary.md#g-sdp)/[UUU](00-glossary.md#g-uuu-universal-update-utility) 経路**(無限に待てるのでタイミング不要)。

## 8. UUU: `SDP: boot` だけでは U-Boot 本体が起動しない

症状: `uuu SDP: boot -f imx-boot` は Okay を返すが UART 無音。SPL は
`Trying to boot from USB SDP` で U-Boot 本体を待ったまま。
真因: SPL 後段([SDPU](00-glossary.md#g-sdpu)/[SDPV](00-glossary.md#g-sdpv))を送っていない。`uuu <flash.bin>` のデフォルト
内蔵スクリプトも `SDP: boot` + `SDP: done` までで後段が無い。
回避: **`SDPV: write -skipspl` + `SDPV: jump` まで書いた uuu スクリプト**
([03](03-boot-flow.md) の `kart-boot.uuu`)。

## 9. UUU スクリプトのパスが二重連結で壊れる

症状: `Error: can't find ext name in path: >/.../scratchpad//home/.../flash.bin`
真因: **uuu はファイルパスをスクリプトのあるディレクトリからの相対で解決**。
絶対パスを書くと `<scriptdir>/<絶対パス>` に連結される。
回避: **画像ディレクトリにスクリプトを置き、ファイル名だけ書く**。

## 10. 「無音 = ハング」の誤判断

症状: シリアル完全無音、SSH も無反応 → 「16 秒でカーネルハング」と判断。
真因: 実は前セッションの起動が刺さっていただけ / タイミングで先頭を取り逃していた
だけ、のことが複数回あった。`uptime` や wlan scan のタイムスタンプ(増え続けるか)、
`ping` の可否、`/proc/cmdline` の root= で**今どの OS が動いているか**を確定させると
誤判断が減る。

## 11. 「16 秒の壁」= NFS root + systemd-networkd の競合(重要)

症状: 自作カーネルが systemd 16〜17 秒地点(`Load/Save OS Random Seed` の手前)で
毎回停止。ネットワーク断。
真因: カーネルが `ip=` で eth0 を上げて [NFS](00-glossary.md#g-nfs) root をマウント → その後
**systemd-network-generator が `ip=` から .network を生成 → [systemd-networkd](00-glossary.md#g-systemd-networkd) が
eth0 を掌握して一度落とす → NFS root(= /)が読めなくなり全停止**。

試して効かなかった対処:
- `KeepConfiguration=yes` の .network 投入 → 不十分
- `net.ifnames=0`(eth0→end0 改名を止める)→ これも根本ではない

効いた対処: **systemd-networkd スタックを丸ごと mask**(networkd 本体 + socket +
wait-online)。netboot では eth0 はカーネル `ip=` 設定のままでよく networkd 不要。
→ 16 秒の壁を突破し login まで到達。

> **これは netboot 特有の問題で、実機の [eMMC](00-glossary.md#g-emmc) 起動イメージには存在しない**
> (ローカル root なら networkd が eth0 を再構成しても何も起きない)。
> netboot オーバーレイ側にだけ mask を入れるのが正しい([05](05-next-steps.md))。

## 12. tee /dev/pts/15 が exit 144 で落ちる

`| tee /dev/pts/15` がシグナルで落ち、複合コマンド全体を巻き込むことがあった
(前段のバックグラウンドキャプチャ終了シグナルの波及)。
回避: **Python スクリプト内で [pts](00-glossary.md#g-pts) へ直接 write**、キャプチャと本処理は
**別コマンドに分離**。

## 13. 自作 U-Boot は MAC を持たない

`Error: ethernet@30be0000 No valid MAC address found.`。ベンダは独自 eeprom
パーティションから読むが自作 U-Boot にはその処理が無い。
回避: netboot 時に `setenv ethaddr ac:db:da:69:be:8e`(個体の実 MAC)。
恒久化するなら U-Boot 側で eeprom 読み出しを実装 or env に焼く。

## 14. 「login 後にネットワーク断でハング」の正体はウォッチドッグリセット (重要)

症状: login 到達後しばらくして無反応。「networkd mask が不十分でまだ eth0 を
触る奴がいる」と誤診していた(#10 の変種)。
真因: **U-Boot が WDOG1 を 60 秒タイムアウトで武装したまま Linux に渡すが、
誰もサービスを引き継いでいなかった**。ホスト側 ping 監視 + シリアルの
`MARK $(uptime)` ループで、uptime ≈55s(= U-Boot の WDT 武装から 60s)で
毎回**無言のハードリセット**(panic 無し、SPL バナーから再開)することを確認。
`devmem 0x30280002 16 0x5555` / `0xAAAA` の手動サービスで生存することも確認。

カーネル側の敗因は二重:
- `imx2_wdt` は `module_platform_driver_probe()`(**一発勝負・deferred probe
  不可・成功しても無言**)。initcall_debug で `returned -19`(-ENODEV)を確認 —
  t=0.24s の時点では supplier (iomuxc/clk) が未 probe なので必ず失敗し、
  ドライバごと登録解除される。
- そもそも素の arm64 defconfig は `IMX2_WDT=m`(モジュール)で、このビルドだけ
  =y になっていた。=m ならロード時 (rootfs 到達後) に supplier が揃っており
  確実に probe し、`WDOG_HW_RUNNING` 検出 → watchdog core が userspace の
  open まで代打 ping する (`CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED=y`)。

修正: `watchdog.cfg` で `CONFIG_IMX2_WDT=m`。pet 無しで uptime 233s+ を実証。
教訓: **「ハング」を見たら uptime の値を疑え** — 毎回同じ uptime で死ぬなら
タイマー(ウォッチドッグ)を疑う。U-Boot の `WDT: Started watchdog@30280000
(60s timeout)` の行が起点の証拠になる。

## 15. スリム化 cfg の依存崩壊で PINCTRL/GPIOLIB がカーネルごと消える (重要)

症状: LT9611 / MCP2515 / PMIC / cpufreq が「wait for supplier
.../pinctrl@30330000/<グループ名>」で永久 deferred。グループ名の定義漏れを
疑ったが、**DTB には全グループが存在していた**。
真因: `slim-imx-arch.cfg` が他ベンダー SoC (ARCH_*) を削った結果、
`CONFIG_PINCTRL` / `CONFIG_GPIOLIB` の**ゲートを select する構成が全滅**し、
defconfig が明示していた `PINCTRL_IMX8MM=y` / `GPIO_MXC=y` も依存不成立で
olddefconfig に黙って落とされた。**fragment には一行も書いていないのに消える**
(`.config` には `# CONFIG_PINCTRL is not set` が残るだけ)。
UART2/ENET/eMMC が動いていたのは **U-Boot が mux したパッドの残り物**。

切り分け: `fw_devlink=off` でブートすると pinctrl 待ちが全て消え、代わりに
GPIO 参照 (reset-gpios / interrupt-parent) の deferred に変わった → 「特定
グループの問題」ではなく「pinctrl/GPIO サブシステム自体が不在」と確定。
`/sys/kernel/debug/pinctrl` が存在しないことが直接証拠。

修正: `pinctrl-gpio.cfg` で PINCTRL / PINCTRL_IMX8MM / GPIOLIB / GPIO_MXC を
明示 =y。教訓: **スリム化で「大きな塊」を削ったら、defconfig の =y が
.config に生き残っているか差分チェックする**(select 崩壊は黙って起きる)。
検出コマンド: defconfig の `=y` 行を回して `.config` に無いものを列挙する。

## 16. 6.12 の lontium-lt9611 は NO_CONNECTOR 前提 (mxsfb と組めない)

症状: `lt9611: failed to parse device tree` 連発(実体は port@2 の
`drm_of_find_panel_or_bridge` が -EPROBE_DEFER)。`CONFIG_DRM_DISPLAY_CONNECTOR=y`
を足すと今度はチェーン全体が `drm_bridge_attach ... -22 (-EINVAL)`。
真因: display-connector ブリッジと 6.12 の lt9611(自前コネクタ機構が削除済み)
は `DRM_BRIDGE_ATTACH_NO_CONNECTOR` 前提だが、**mxsfb (lcdif) は旧式の
flags=0 で attach する**(lt9611 の主戦場は Qualcomm msm で、mxsfb との
組み合わせは mainline に存在しない)。
修正: `0001-drm-mxsfb-attach-bridge-with-NO_CONNECTOR.patch` — mxsfb を
NO_CONNECTOR + `drm_bridge_connector_init()` に変更。EVK の adv7535 経路も
NO_CONNECTOR 対応済みなので共存できる。
罠の続き: `drm_bridge_connector_init()` は `DRM_DISPLAY_HELPER` 内にあり、
これは**プロンプト無しシンボル**なので cfg fragment の `=y` は無視される
(=m のまま組み込み mxsfb からリンクできず undefined reference)。
パッチ内で mxsfb の Kconfig に `select DRM_BRIDGE_CONNECTOR` /
`select DRM_DISPLAY_HELPER` を足すのが正解 (upstream の msm と同じ流儀)。
検証結果: `mxsfb-drm initialized`、`card1-HDMI-A-1` が出現
(モニタ未接続なので status=disconnected)、devices_deferred は空。

## 17. LT9611 は低ピクセルクロックで使い物にならない — 高クロックラスタ + 小アクティブ領域が正解 (重要)

症状: 800x480 パネル (TFP401 系ドライバ基板) に向けて native 32MHz を送ると
真っ黒 or 横揺れ (上端数 mm だけ正常で下に行くほど横に流れる)。

**実測で確定した LT9611 TX の動作マップ** (受信ロックは常に完璧な状態での結果):

| pclk | 結果 |
|---|---|
| 27〜33MHz | 映るが横揺れ (PCR/TX のジッタ。フレーム内で位相ドリフトが蓄積) |
| 40〜74.25MHz | 無信号 (寛容なスケーラ基板ですら映らない) |
| **108MHz (postdiv=2, M=40)** | **完全に安定** (最終採用値) |
| **148.5MHz (1080p)** | **完全に安定** (ただし 800x480 ガラスのシフト限界超えでノイズ) |

試して全て無効だったもの: PCR M の整数割り切り (pclk=M×1.35MHz に調整)、
M 手動/±1、MK limit (0x832d) 変更、PCR リセット連打、ブランキング増減、
リフレッシュ変更。= **タイミングパラメータでは回避不能な silicon 特性**。
ベンダ自身も `lt,preferred-mode = "1920x1080"` の 1080p 固定で使っており、
低クロック域は未検証領域。

**最終解 (実機検証済み)**: 「**高クロックのラスタに小さいアクティブ領域だけ
置く**」カスタムモード。

```
mode=108.0 800 888 932 2200 480 484 489 818 +hsync +vsync
```

ピクセルクロックはラスタ全域 (ブランキング込み) の速度であり、DE 駆動の
パネルは DE 期間の画素しか取り込まない。そこで 2200x818 のラスタ (108MHz、
行 49kHz・60Hz) にアクティブ 800x480 だけ載せると:
- LT9611 には 108MHz (安定域、PCR M=40 割り切り、VCO 1080MHz) が見える
- ガラスには native 相当の行/フレーム構造が見える
- KMS モードの可視領域 = フレームバッファサイズ = Wayland 経由でアプリの
  描画サイズなので、**weston.ini 1 行だけで kmm の描画も 800x480 になる**
  (アプリ・コンポジタ無改造、描画コストも 480p 級)

調整過程の知見:
- 148.5MHz (1080p レート) でアクティブ 800x480: 映るが黒線・かすれ・
  1px ズレ = **ガラスの画素シフトが 148.5MHz に追従できない**。108MHz で解消
- htotal を 4200 に伸ばして行レートを native に寄せる案: 同期喪失
  (ガラスは行周期の許容も狭い)。**htotal は 1080p と同じ 2200 を維持**が正解
- スケーラ内蔵ドライバ基板 (RTD 系、EDID に多モードが並ぶ) なら
  1080p 固定 + 縮小で無調整で映るが、**スケーラの同期に時間がかかる**ため
  起動時間要件から不採用 (切り分け用途には有用)
- weston.ini は machine override (`files/mx8mm-generic-bsp/weston.ini`) で
  このモードを固定。1080p モニタ運用時は mode=1920x1080@60 に差し替え

副産物 (`0002-drm-lontium-lt9611-dsi-lanes-from-dt.patch`): lt9611 の
DSI レーン数を endpoint の `data-lanes` から設定可能にした (省略時 4)。
2 レーンにするとレーン当たりレートが倍になり、LT9611 の **MIPI RX ロック
下限 (実測 280〜312Mbps/lane の間)** を低 pclk でも回避できる (800x480
native 直送実験で使用。ただし TX 側の揺れは解決しないため最終構成では 4 レーン)。

デバッグの教訓:
- **LT9611 のハードリセット (GPIO) は driver probe 時のみ**。weston 再起動
  ではチップはリセットされないので、i2c でレジスタを触った後は再起動必須
  (「同じ設定なのに映らなくなった」の原因)。
- i2c-tools はイメージに無い。deploy/rpm から抽出して scp すれば
  `-f` (force) でドライバと共存してレジスタを覗ける。
- PCR ロック品質は `video check` の `h_total_sysclk` ≈ 27e6×htotal/pclk
  で数値評価できる。

**UPDATE (2026-08)**: このモードは後に「アクティブ 800x480」→「黒埋め
1920x792」へ拡張した (ラスタ 2200x818/108MHz は不変)。疎な DE (充填 36%)
だと PCR のロック位相が多安定になり再ロックごとに横位相が抽選になるため。
経緯・機構・最終構成は #23 参照。

## 18. libubootenv の fw_setenv -s はスペース区切りを黙って無視する

症状: `fw_setenv -s <batch>` が rc=0 なのに何も書き込まれない
(fw_printenv で旧値のまま)。単発の `fw_setenv name value` は成功する。
真因: **libubootenv のバッチ形式は `名前=値`**。旧来の u-boot-tools 流の
「名前 値」(スペース区切り) の行はエラーにならず捨てられる。
ota-update.sh と kart-ab-commit (mx8mm 版) が両方これを踏んでいた —
どちらも**読み戻し検証を実装していたおかげで無言破壊にならず検出できた**。
修正: バッチファイルを `kart_slot=b` 形式に。
教訓: fw_setenv 系は必ず読み戻し検証をセットにする (今回それが仕事をした)。

## 19. i.MX8MM の PERSIST_SECONDARY_BOOT は「入力」ではない — ソフトから B を試し起動する術は無い (重要)

症状: SRC_GPR10[30] (PSB) を devmem で立てて reboot しても、次回起動は
必ず A copy (プライマリ)。U-Boot の PSB ドキュメント (imx7 向け) を根拠に
した「PSB セット → reboot で B 起動 → 確認して昇格」フロー
(旧 kart-uboot-try) は成立しない。

実機で確定させた事実 (2026-08-12):

- **SRC_GPR10 はあらゆるリセットで消える**。PSCI reboot でも WDOG SRS
  ソフトリセット (devmem 0x30280000 16 0x1D2F) でも、魔法値 (0x0A5A) ごと
  0 に戻る。「POR のみでクリア」という imx6/7 の常識は 8MM には当てはまらない
- **ROM のフォールバックは inline**。A copy の IVT を破壊して再起動すると、
  同一起動内で SIT (sector 0x41) → B copy (sector 0x1042) が選択される。
  リセットを挟む PSB 機構は 8MM では使われていない
- **PSB は ROM が「フォールバック起動中」に立てる出力**。B で起動した瞬間の
  GPR10 は 0x40000000 になっており、その起動内での検出には使える
  (次のリセットでまた消える)
- **確実な起動元判定は ROM イベントログ**。ポインタ @0x9e0 (ROM 定数、
  Linux の devmem からも読める) → OCRAM 上のログを走査し、event 0x50 =
  プライマリ / 0x51 = セカンダリ。U-Boot の
  imx8m_detect_secondary_image_boot() と同じ方法。パラメータ付きイベント
  (0x8x/0x9x = 1 語、0xA0/0xC0 = 2 語) の読み飛ばしを忘れると誤検出する

対応: ツールを実仕様に合わせて再設計 (kart-uboot-try / -commit は廃止)。
**B 面に一つ前の版を残す方式**に統一:

- **kart-uboot-update <flash.bin>**: ①現行 A を B へ退避 → ②新版を A へ。
  結果 A=新版 / B=直前まで動いていた版 (フォールバック先 & ロールバック元)。
  UBOOT_COPIES=DIFFER が正常状態になる
- **kart-uboot-rollback**: B (前版) を A へ書き戻す
- **kart-uboot-selfheal** (systemd oneshot, boot 時): フォールバック起動を
  検出したら自動で rollback — B 起動は無症状なので人間の気づきに頼らない
- **kart-uboot-status**: 起動コピーをイベントログで判定
- 安全ガード:
  - **退避スキップ**: update 時に A が不正なら退避しない (壊れた A を B へ
    複写して唯一の健全コピーを潰す事故を防ぐ)。判定は A 先頭の IVT ヘッダ検査
  - **フォールバック起動中の update 禁止**: B 起動は事故の痕跡なので、先に A を
    修復して正規状態へ戻す (boot 時 selfheal との A 同時書き込みレースも塞ぐ)
  - **flock** (`/run/kart-uboot.lock`) で update/rollback/selfheal を相互排他。
    mkdir だと SIGKILL でロック残留 = プロセス途中死のときに壊れるので不可
- 実機検証: DP100 で各局面に実電源断を当てて全て再実行一発で収束、統合検証は
  OTA → A破壊 → コールドブート → selfheal 自動修復 (journal) →プライマリ起動まで
  人間の介入ゼロで完走 (詳細は migration-design の U-Boot A/B 節)
- 全書き込みは **header-last**: 先に書き込み先の IVT セクタを潰し、
  本体 → IVT の順で書く。ROM の正当性検査は実質 IVT ヘッダだけなので、
  素朴に先頭から dd すると「途中で電源断 → IVT は正当だが後半欠損 →
  ROM が通してしまい SPL が死んで watchdog ループ = UUU でしか復旧
  できない」穴がある。header-last なら書きかけの面は常に「きれいな
  IVT 不正」で、必ずもう片方の面で起動する

限界も明記: IVT が正当なまま起動しないバイナリはこの仕組みでは救えない
(前版 B で立ち上がるが A を直すまで毎回フォールバック)。U-Boot 更新は
ベンチ検証してから配布する (最終復旧は UUU/SDP)。
なお「ソフト切替できる本物の A/B」が要るなら、SPL に env を読ませて
U-Boot proper (FIT) を選択させる設計になる — Falcon Mode (SPL が直接
カーネルを選ぶ) の前提工事と同じ内容なので、やるなら Falcon と同時が良い。

余談: 旧 kart-uboot-try の読み戻し検証は busybox に無い `head -c` で即死する
バグも抱えていた (「busybox 構文のみ」と自称しながら)。デバイス側スクリプト
の検証はセクタ単位 + パディング書きで行うこと (CLAUDE.md の coreutils 罠)。

## 20. ベンダローダ (boot0) の env は kart env と同一オフセット 4MiB — ベンダ復帰中の saveenv は A/B 状態を破壊する

ベンダ U-Boot (eMMC boot0 に温存している 2018.03) の環境変数は
`CONFIG_ENV_OFFSET = 64*64K` = **eMMC user 領域の 4MiB オフセット** (size 0x1000)。
kart の U-Boot env も**同じ 4MiB** (`fw_env.config`: 0x400000, size 0x2000) にある。

- ベンダローダは kart env を CRC 不一致として無視しデフォルト env で動く
  (読みだけなら無害)
- しかしベンダローダのプロンプトで **`saveenv` すると kart env
  (kart_slot / upgrade_available / bootcount) が上書き破壊**され、
  自作 U-Boot の A/B スロット選択が初期化される
- 対処: ベンダ復帰 (`mmc partconf 2 0 1 0`) 中は saveenv 禁止。壊した場合は
  kart-env.bin を 4MiB オフセットへ書き戻す (wic 再 dd、または ums で
  該当 8KiB だけ dd)

なおベンダローダは eMMC p1 の FAT から `boot.scr` を最優先で実行するため、
BOOTA に boot.scr を置けばベンダ復帰状態からでも自作システムを起動できる
(リカバリフック。詳細は [07-vendor-bsp-audit](07-vendor-bsp-audit.md) §4)。

## 21. udev coldplug の遅延は「モジュールロード」と「エントロピー」を道連れにする (二段 coldplug の敗戦記録)

起動短縮のため systemd-udev-trigger を GUI クリティカルなサブシステムに絞り、
残りを kmm 起動後に回す「二段 coldplug」を試したところ、3 つの罠を連続で踏んだ
(全て実機で確定。毎回 A/B の試行ブート監視が 84s でフォールバックして救済):

1. **=m ドライバのロードは udev が起点** (MODALIAS→modprobe)。mcp251x (=m) の
   ロードが stage2 送りになり、can0 が現れず kmm (After=can0-up) が凍結
2. **バスドライバも =m だった**: spi-imx (=m) が居ないと ecspi2 バスごと不在。
   ビルトイン化 (CONFIG_SPI_IMX=y + CONFIG_CAN_MCP251X=y) で解決したら—
3. **今度は builtin spi-imx が SDMA (=m のまま) を待って probe 保留**
   ("can't get the TX DMA channel")。DT で ecspi2 の dmas を削除して PIO 固定で解決
4. さらに **coldplug は隠れたエントロピー源**だった: デバイス登録イベントが減り
   CRNG 初期化が ~4.6s までずれ、weston の EGL 初期化が getrandom() で ~1.3s
   ブロック (`crng init done` のタイムスタンプと weston ログのギャップが一致。
   ブロックした正確な関数までは未特定だが、CRNG を早めたらギャップが消えた
   ことで因果は実測確定)。
   systemd-random-seed の SYSTEMD_RANDOM_SEED_CREDIT=1 + /data 上の seed で解決

エントロピー問題の背景 (このボードが枯渇しやすい理由):
`getrandom()` は CRNG が初期化されるまで**仕様としてブロック**する。
PC が持つ乱数源 (RDRAND 命令、キーボード/マウス/ディスクシークのジッタ) が
この板には無く、CAAM (ハード TRNG) もドライバ =m で寝ているため、起動直後の
エントロピーは実質「デバイス初期化の割り込みラッシュ」頼み — だから coldplug を
遅らせただけで枯渇した。credit は「seed は毎起動+シャットダウンで書き換わる
ので再利用は電源断時のみ、/data はデバイス個体別」を根拠に許容している。
さらに前倒ししたければ CAAM ビルトイン化 (ハード乱数) が次の一手。

結末: ここまで直しても二段化の GUI 短縮は誤差程度 (-46ms) でばらつきが 10 倍に
なったため**二段 coldplug 自体は撤収**。副産物の
「udev ルール/hwdb 削減 (-10MB)」「CAN/SPI ビルトイン化 + ecspi2 PIO 固定」
「random-seed credit」だけを残したところ、kernel→GUI は 3.98s → **3.82s**
(N=5, stdev 0.07) と正味 -0.16s + 決定論性向上で着地した。

教訓: クリティカルパス上のドライバは =y にする (udev を信路に入れない)。
coldplug を痩せさせるならエントロピーの手当て (seed credit) をセットで。

### PIO 固定の性能面の妥当性 (1Mbps CAN 飽和まで見た解析)

ecspi2 の dmas 削除 (PIO 固定) が性能問題にならない根拠:

- 1Mbps 飽和バスのフレームレートは 8 バイトフレームで ~8k/s、最小フレーム
  連打の理論最悪で ~20k/s
- フレーム 1 個の処理は SPI 25 バイト前後 = **ワイヤ時間 ~20µs (10MHz)** +
  割り込み/threaded IRQ/spi_sync のオーバーヘッドで実質 60〜100µs/フレーム。
  8k/s 飽和で 1 コアの 5〜8 割 (動くが重い)、20k/s は取りこぼす
- **この数字は DMA でもほぼ変わらない**: ワイヤ時間は SPI クロック上限
  (MCP2515 は 10MHz) で頭打ちで、DMA が肩代わりする「25 バイトの書き写し」は
  数 µs。一方 DMA には記述子設定/キャッシュ操作/完了割り込みの固定費があり
  この転送サイズでは差し引きゼロ以下
- 真の律速は MCP2515 のアーキテクチャ: **フレーム毎に割り込み + SPI 往復が
  必須**で、**チップ上の RX バッファが 2 個**しかない (連続 2 フレーム分 =
  8 バイトフレームで ~240µs 以内のサービス保証が要る — 非 RT Linux では
  飽和時の無損失は PIO/DMA を問わず保証できない。RPi5 の同 HAT も同条件)
- 現実のカート負荷 (数百〜2k フレーム/s) では CPU 数 % で余裕。
  **1Mbps 飽和が本当に要件になったら直すのは PIO ではなくチップ**:
  MCP2518FD (RX FIFO 2KB、まとめ読み可、mainline mcp251xfd) への置き換え、
  さらに上は FlexCAN 内蔵 SoC (i.MX8M Plus)。キャリア基板検討 (07 §CAN) と同文脈

## 22. カーネルブートロゴ (fbcon) は「初回モードセット ~2s」を GUI 前に前借りする (実測棄却)

電源投入直後にロゴを出す試みとして CONFIG_DRM_FBDEV_EMULATION +
FRAMEBUFFER_CONSOLE + LOGO を有効化したところ、**kernel→GUI が 3.59s →
5.23s (+1.6s, N=5)** に悪化して棄却した。

- dmesg の `Console: switching to colour frame buffer device` が **2.44s** に出現。
  fbcon の takeover がカーネル内で LT9611 の初回モードセット (ブリッジ有効化
  チェーン) を同期実行し、これが**約 2 秒**かかる
- EDID をファームウェア供給にして DDC 読取 (~1.2s) は既に消してあるが、
  **モードセット自体が重い**のは別問題 — fbdev エミュレーション無効なら
  初回モードセットは weston 起動後 (GUI 直前) に 1 回だけ走り、カーネル
  ブートと並行処理される。fbcon 有効だとこれをブート序盤に direct に払う
- ばらつきも悪化 (stdev 0.07 → 0.55)。ロゴ表示自体も weston の奪取と近接し
  安定して視認できなかった
- `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER` (最初の出力まで takeover を
  遅らせる) なら logo は「最初の出力時」に出る仕様なので `quiet` と併用すると
  **そもそもロゴが出ない**。ロゴ目的では使えない

教訓: この表示チェーン (mxsfb→LT9611→HDMI) では「電源→約 2.4s より前に
画面が光る」ことはカーネルロゴでも達成できず、GUI 到達時間だけ悪化する。
早期スプラッシュを本気でやるなら SPL/U-Boot 段での LCDIF 直叩きが唯一の道
→ その後実装した (kas/imx8mm-splash.yml + u-boot 0002 パッチ + kernel
0004-0006、電源→ロゴ約 1〜2s)。weston kiosk-shell の background-color
ダークトーン (0xff10141c) はブート連続感のため継続 (kiosk-shell は画像背景
非対応 — weston 13 ソース確認済み)。

## 23. LT9611 の PCR は「周波数ロックのみ」— 疎な DE では横位相が抽選になる (重要・最終構成の根拠)

SPL スプラッシュ (#22 の続き、LCDIF/DSIM/LT9611 を SPL から直叩き) を
実装したところ、**ロゴ/GUI の横位相がブートごとに変わる**問題に遭遇した。
症状: ~1/4 の確率で画面全体が横にずれ、端が反対側に回り込む。ズレ量は
±46px (≈hsync 幅) の量子化。weston 再起動 (温間再ロック) でも同様の抽選。

### 機構 (実測と資料調査で確定)

- LT9611 の PCR (Pixel Clock Recovery) は**周波数だけを合わせるサーボ**で、
  位相はロック瞬間に 1 回捕捉したものが持続する。出力ラスタは自走
- DSI の sync はバイトクロック量子化されたパケット (~1.3px 粒度) で、
  **画素精度の位相を保証しない**。普通のモニタは DE 基準で自己整列するため
  業界的に顕在化しない。うちのパネル (TFP401 系直結) は DE 先頭から
  800 列を並べるだけの dumb 構成なので位相ズレがそのまま見える
- ラスタ 2200x818 にアクティブ 800x480 (#17 旧構成) だと **DE 充填率 36%**。
  FIFO と DE 窓の位相関係に複数の安定点が生まれ (多安定)、再ロックごとに
  どれかに落ちる = 抽選。1080p 級 (充填 87%) の検証済みモードは一意
- コールドロック (電源断後の初回) は決定的、温間再ロックが抽選という
  非対称もこのモデルで説明がつく (温度相関もあり)

### 試して駄目だったもの (全て実機)

| 対策 | 結果 |
|---|---|
| カーネルのレジスタ列と完全一致再現 | 抽選残存 |
| 温間→コールド化 (enable 時ハードリセット + 0x80ee アンロック) | 1/4→1/16 に減るがゼロにならず、暗転+白フラッシュの副作用 |
| VSYNC 同期・PCR リセット連打・PCR M 固定 (ベンダ式) | 効果なし or 映像崩壊 |
| 密ラスタ化 (htotal 縮小で充填率を上げる、4 モード) | パネルの行レート上限 (~100kHz) と VIDEO_PLL の端数 ppm スリップ (clk-pll14xx は最初の (p,s) 候補を採用し k≠0 になりがち)。全整数化 (VIDEO_PLL 24×72/16, DSIM 648M, PCR M=40) しても未知の斜めスキューが残存 |

### 最終解: 黒埋め広 DE (充填率だけを上げ、実績値は全部維持)

```
mode=108.0 1920 1988 2032 2200 792 796 801 818 +hsync +vsync
```

ラスタ 2200x818/108MHz (実績) のままアクティブを 1920x792 に拡張し、
右と下を黒画素で埋める。充填率 87% でロックが一意化し、温間 8/8・
ドリフトなしを確認。パネルは DE の左上 800x480 だけを物理表示する
(実測でクロップ動作を確認。DE>800 の拒否はしない)。

嵌まりどころ:
- **mxsfb は hdisplay>1920 を EINVAL で拒否**する。このとき weston は
  モード一覧に "current" と表示したまま画面だけ暗い。
  `journalctl -u weston` の `atomic: couldn't commit new state` が真実
- クライアントを 800x480 のまま左上等倍に置くため **kiosk-shell に
  `[shell] client-size=WxH` を追加するパッチ**を当てた
  (`weston_%.bbappend` + `0001-kiosk-shell-client-size.patch`、mx8mm 限定)。
  アプリ (kmm) は無改修
- 負荷は実質同一: buffer age 有効なので GPU 再描画はダメージ領域
  (≤800x480) のみ、CPU 実測差なし。増えるのはスキャンアウト DMA の
  DRAM 帯域 92→365MB/s (LPDDR4 総帯域の数%) とバッファ +数 MB のみ
- SPL スプラッシュも同ラスタに変更 (u-boot 0002 パッチ)。ロック一意化で
  旧構成に必要だった H_COMP=-56 位相補正が不要になった。0006 パッチの
  「enable 時リセット」も撤去 (抽選が消えたので純粋に有害 = 暗転+白の原因)。
  FB は 1920x792x4=5.8MB になり 0xBFA00000 / mem=2042M に変更

### 計測の教訓

- 単発フレームの静止画比較は連続スリップを見逃す (エイリアシング)。
  「ロック→1 秒かけて右に流れて黒転→復帰」の繰り返しは人間の目でしか
  見つからなかった。**判定は目視 > 自動相関**
- 「モードが変わった」ことの確認は lt9611 の `video check` dmesg 行
  (enable のたびに必ず出る) の hactive 実測値で行う。出ていなければ
  ブリッジまで届いていない

## 24. M4 は SRC レジスタ生叩きでは起動しない — 起動だけはセキュアモノポリー

devmem で TCM にコードを置き SRC_M4RCR bit0 をクリアしても、M4 は
**1 命令も実行しない** (TCMU スタックマーカー不変で実証)。M4RCR は
書き値が部分的にしか反映されないビットもある (0xA9 → 読み戻し 0xAB)。
起動は **ATF の SIP コール (IMX_SIP_SRC_M4_START) 経由が必須**で、
これを呼べるのは U-Boot bootaux か Linux imx_rproc (remoteproc) だけ。
SMC は EL1 以上専用なので userspace からは原理的に届かない。

副次的な教訓:
- **TCM へのロード自体は devmem で完璧にできる** (リセット保持中は保持)。
  「ロードできた ≠ 起動できる」を混同すると、シリアル無音の原因を
  配線のせいにして迷走する (実際 1 晩迷走した — 配線は最初から正しかった)
- busybox の dd は `conv=notrunc` を **usage エラーで丸ごと拒否**する。
  「dd が黙って何もしない」ではなく rc≠0 なので、`2>/dev/null` で
  捨てているとロードが空振りしたことに気づけない (CLAUDE.md の
  「デバイス側 busybox 制約」の新パターン)
- 詳細と remoteproc の正規経路: [10-cortex-m4.md](10-cortex-m4.md)

## 25. CCM の CCGR は「書いた奴のドメインの設定ビット」にしか書けない (M4 ベアメタルの罠)

M4 のベアメタルから UART4 のクロックゲート CCGR76 (0x303844C0) に
Linux クローンの感覚で `0x3` (bits[1:0] = SETTING0/domain0) を書くと、
**無言で棄却される** (SET レジスタ +4 経由でも同じ。読み戻し 0 のまま)。
CCM はゲートレジスタにドメイン権限制御を持ち、各バスマスタは自分に
対応する SETTING フィールドしか書けない。

- M4 からの実効フィールドは **bits[5:4]** — `CCGR_SET = 0x30` が正解
  (MCUXpresso SDK デモが残した実効値のダンプ・リプレイで確定)
- root スライス (0x3038B080 等) は普通に書けるので、「クロック設定は
  半分効いている」という中途半端な壊れ方になり気づきにくい
- 症状の見え方: UART の ipg 側は生きてレジスタは読めるのに、ソフト
  リセット (UCR2 SRST) が完了せず設定書き込みが消える → 無出力
- デバッグ手法 (TCMU ブレッドクラム / ダンプ・リプレイ) 込みの記録:
  [10-cortex-m4.md](10-cortex-m4.md)
