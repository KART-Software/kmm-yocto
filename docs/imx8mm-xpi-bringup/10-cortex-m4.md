# 10 — Cortex-M4 (リアルタイムコア) の使い方

XPI-iMX8MM の M4 を Linux から使えるようにした記録と手引き。
CoreECU (R-Car S4) の「CR52 が先住するハードを Linux が引き継ぐ」問題を
反対側 (Linux が M4 を配下に置く) から実装した形。実機検証済み (2026-08)。

## TL;DR — 開発ループ

```bash
cd m4/hello-world
vim hello.c
make deploy      # ビルド → scp → remoteproc 再起動 (数秒)
# J64 (ttyACM1, 115200) に printf が出る
make stop        # M4 停止
```

必要ツール: `apt install gcc-arm-none-eabi` のみ (MCUXpresso SDK 不要)。

## ハードウェア (調査確定事項)

- **M4 の外部配線は UART4 = J64 だけ** (基板左端 4P: 1=RXD 2=GND 3=TXD、
  3.3V、115200 8N1)。JTAG/SWD はコネクタも文書も無し → printf デバッグ前提
- 手元環境: J64 → Teensy pin7/8 (=Serial2) ブリッジ → **/dev/ttyACM1**
- 40 ピンヘッダの全ペリフェラル (I2C2/I2C4, UART1/3, ECSPI2, SAI2, PDM,
  PWM1/2) は原理上 M4 からも使える。IOMUX/CCM は共有、排他は RDC。
  GPIO の RDC 割当はバンク単位 (SEMA4 無し) なので混在共有は不可
- **RDC は既に UART4 を M4 ドメインに割当済み** (NXP ATF 既定)。
  A53 から 0x30A60000 は読めない — これは正常
- TCM: TCML 128KB (M4 視点 0x1FFE0000 / A53 視点 0x007E0000)、
  TCMU 128KB (0x20000000 / 0x00800000)。M4 はキャッシュ無しなので
  TCM 実行が基本。電源断で揮発

## 起動経路 — SIP 必須 (生レジスタでは起動しない)

M4 は ROM から直接ブートせず、A コアが起こす。**起動は ATF の SIP コール
(`IMX_SIP_SRC_M4_START`) 経由が必須**。この結論は実測:

- devmem で TCM ロード + SRC_M4RCR bit0 クリア → state 上は解除されるが
  **M4 は 1 命令も実行しない** (TCMU スタックマーカー不変で確認)
- SRC_M4RCR は書き値が反映されないビットもある (0xA9 を書くと 0xAB に戻る)
- SMC は EL1 以上専用なので userspace からは原理的に届かない

使える経路は 2 つ:
1. **Linux remoteproc (採用)** — `fsl,imx8mm-cm4` は SMC メソッドで
   imx_rproc が SIP を呼ぶ。ロード (ELF)・起動・停止・差し替えが
   ランタイムに自由。暴走ファームも `echo stop` で確実に止まる
2. U-Boot `bootaux` — falcon は proper を飛ばすため通常起動では使えない

## Linux 側の配線 (このリポジトリで追加済み)

- `meta-kart/recipes-kernel-imx/linux/files/imx8mm-xpi-kart.dts` —
  末尾の M4 ブロック: `imx8mm-cm4` ノード + reserved-memory
  (vring/vdevbuffer/rsc-table、NXP BSP 実績配置 0xb8000000 帯。
  mem=2042M の splash 構成でも可視域内)
- `m4-remoteproc.cfg` — `CONFIG_IMX_REMOTEPROC=y` + rpmsg 系 (=m)
- ノードがあるだけでは何も走らない (auto-boot 無し)。ブート影響ゼロ

操作:
```bash
echo -n /tmp > /sys/module/firmware_class/parameters/path   # 置き場所変更
echo -n fw.elf > /sys/class/remoteproc/remoteproc0/firmware
echo start > /sys/class/remoteproc/remoteproc0/state        # stop で停止
```

remoteproc は **ELF のみ受理**。ベアメタル .bin しか無い場合は
`local/bin2elf-m4.py` で包む (p_paddr=0x1FFE0000 の PT_LOAD 1 本)。
NXP プリビルトデモ 4 種はベンダイメージ boot パーティションから採取済み。

## ベアメタルの書き方 (m4/hello-world が雛形)

SDK 無しで完結する。必須要素は 3 つだけ:
1. ベクタテーブル (`.vectors` 先頭: SP=TCMU 上端, Reset_Handler)
2. リンカスクリプト (TCML に text/data、TCMU に bss/stack)
3. ペリフェラル直叩き (レジスタ値の出典は必ずコメントに残す)

ELF ローダが配置と bss ゼロ化までやるので、スタートアップは main を
呼ぶだけでよい。

### クロックの罠 (重要 — pitfalls #25)

**CCGR (クロックゲート) はドメイン権限制御付き**。M4 から Linux と同じ
`0x3` (bits[1:0] = domain0 設定) を書いても**無言で棄却される**。
M4 の実効フィールドは bits[5:4] で、SET レジスタ (+4) に **0x30** を書く。
root スライス (例: uart4 = 0x3038B080) は普通に書ける。この値は
SDK デモが残した実効値のダンプ・リプレイで確定した。

### デバッグチャネル: TCMU ブレッドクラム

UART が出るまでの間 (あるいは UART 自体を疑うとき) は、TCMU の固定番地に
進行状況を書いて A53 から覗く:

```c
#define DBG ((volatile unsigned int *)0x20000100)
DBG[0] = 0x11111111;   /* フェーズマーカー */
DBG[1] = SOME_REG;     /* レジスタ読み戻し */
```
```bash
ssh root@<board> 'devmem 0x800100'    # A53 視点 = 0x20000100 - 0x1F800000
```

- 「実行しているか」はスタックマーカーでも分かる: TCMU 上端 (A53 0x81FFxx)
  に DEADBEEF を敷いて start → 変化すれば実行中 (初期 LR 0xFFFFFFFF の
  push が最初に現れる)
- プリビルトが動くのに自作が動かないときは、**プリビルト実行後に
  ダンプ専用ファームで実効レジスタを読む** (M4 stop はコアのみで
  ペリフェラル設定は残る) → その値をリプレイするのが最短

## SPL 起動 (常駐化) — loadable 可否と attach の実測 (2026-08-19)

M4 を Linux より前に・U-Boot proper も経由せず起動する = falcon.itb に
loadable として同梱し SPL がリセット解除する構想。実機で 2 点を切り分けた。

**① loadable 化は容易(検証済み)**。can-gw の `zephyr.elf` を `readelf -l`
した結果、LOAD は実質 TCML 起点 `0x1FFE0000` の 1 本。Zephyr は .data を
コード直後から TCMU へ自己コピー・bss ゼロ化するので、`zephyr.bin`
(実測 37KB)は「`0x1FFE0000` 起点の連続イメージ 1 本」。falcon.itb の
loadable 1 個(A53 視点 `0x007E0000` へロード)にするだけ。

> ⚠️ **当初「SPL は EL3 だから SRC_M4RCR 直書きで解除でよい」と書いていたが
> 実機で覆った** — 真因は **SPL 自身が TCM 内で実行**されており、M4 を TCM に
> 置くと走行中の SPL を自己上書きしてハングする(下記「③」)。M4 起動は
> TCM 外で走る ATF 側へ。

**② 難所は attach。現行 can-gw firmware の改修が 1 点必須**。M4 が先住だと
Linux は「起動」ではなく稼働中 M4 への **attach** になり、ELF をパースしない。
実測で所有関係を確定:

- DT は attach 対応済み: reserved-memory に `rsc-table@b80ff000` /
  `vdev0vring0@b8000000` / `vdev0vring1@b8008000` / `vdevbuffer@b8400000`。
- **rsc_table を書くのは Linux(load 時)で、M4 ではない**。`0xb80ff000` を
  ゼロ化 → stop/start で version=1/num=1 に再populate(Linux が ELF から書く)。
  M4 稼働中にゼロ化して 3 秒待ってもゼロのまま(M4 は書き直さない)。
  → attach では Linux が `0xb80ff000` を**読む**側になるので、**M4 firmware
  自身がそこへ rsc_table を発行**する改修が要る(Zephyr リンカで
  .resource_table を固定 DDR 番地へ)。
- rsc_table は setup 専用: 稼働中ゼロ化でも can0 は UP のまま(vring は別)。
- software だけでは attach 完全再現は不可: このカーネル(6.12.20-fslc)は
  sysfs `detach` 非対応、imx-rproc は built-in。完全検証には SPL loadable か
  bootaux で M4 を先行起動する実物が要る。

**attach を bootaux で完全実証**(2026-08-19): firmware に「rsc_table を
`0xB80FF000` に自己 publish(attach のときだけ)」を実装し、stock U-Boot の
`bootaux`(flash.bin 無傷で RAM 起動)で M4 を先行起動 → eMMC カーネル起動
→ dmesg `attaching to imx-rproc` → `is now attached`、**can0 UP**、M4 側
`peer 0x400 started=1`(双方向確立)。imx_rproc は稼働中 M4 を probe 時に検出
して attach する(`imx_rproc_attach` 実在)。**「M4 先住 → attach → can0」成立**。

**③ SPL 起動の壁 — SPL は TCM 内で実行(2026-08-19、実機で確定)**。falcon.itb に
M4 loadable を積み SPL で起動しようとしたら**デッドハング**
(`falcon_args...default` 直後で沈黙)。真因は **SPL 自身が TCM で走っている**
こと: flash.bin の IVT entry = `0x007E1000`、imx8mm の TCM は `0x7E0000`〜
`0x820000`。M4 loadable を TCML(`0x007E0000`)に置くと**走行中の SPL を
自己上書き**して即ハング(電源ドメインではない — 当初の誤診を訂正)。DDR 経由の
memcpy も、その memcpy コード自体が TCM にあり途中で消えるので不可。bootaux が
成功したのは U-Boot proper が DDR で走るから。**M4 の TCM 配置+起動は TCM 外
(OCRAM `0x920000`)で走る ATF(BL31)側でやる**のが正解 → ④ で実装・実証済み。

**④ BL31 版 M4 起動 — 実装・実機実証済み(2026-08-19)**。kas overlay
`imx8mm-m4.yml` を付けると、cold boot で以下が全自動で成立する
(※ M4 の運び方はその後 falcon.itb 埋め込み → **boot パーティション上の
独立ファイル m4-fw.img** に変更した — [12](12-m4-standalone-bin-design.md)。
BL31 側の仕組みは不変):

1. **SPL**: falcon.itb の M4 loadable を **DDR ステージング `0x46000000`**
   にロード(TCM に置かない = 自己上書き回避)
2. **BL31**(`imx-atf` パッチ `0001-...-bl31-start-m4`、OCRAM で走る):
   `bl31_platform_setup` で ① **`0xB80FF000` をゼロ化**(下記 rsc_table 残存
   対策)② DDR→TCML コピー ③ `SRC_M4RCR` で M4 解除。A53 コンソールに
   `NOTICE: kart: Cortex-M4 released from BL31 (SP=... PC=...)`
3. **M4**: `rsc_table published to 0xB80FF000 (attach mode)` → CAN gw 起動
4. **Linux**: `attaching to imx-rproc → is now attached →
   kart-can channel bound (ept 0x400)` → **can0 UP、kmm active、restart 0**

**踏んだバグ: DDR の rsc_table 残存**。DDR は warm reboot で消えないため、
前回の LOAD 起動が書いた `0xB80FF000` の version=1 が残っていると、M4 が
「Linux が書いた」と誤判定して publish をスキップ → 古い vring da/status で
attach が不成立(state=attached になるが can0 が出ない)。**BL31 が M4 起動
直前に `0xB80FF000` をゼロ化**して、M4 に必ず fresh table を publish させる。

構成: `kas/imx8mm-m4.yml`(`KART_M4` + BL31 パッチ)、
`meta-kart/recipes-bsp-imx/kart-falcon-itb`(M4 loadable を DDR staging へ)、
`meta-kart/recipes-bsp-imx/imx-atf/files/0001-...-bl31-start-m4.patch`。
firmware の rsc_table 自己 publish は data-logger-zephyr の can-gw。

概念の詳細は [learning/03](../../learning/03-m4-coprocessor-rpmsg.md) §2-3。

## M4 のクロック確認手順 (2026-08-23 実測)

M4 のコアクロックは Linux の clk ツリーに現れない (`clk_summary` に m4 は無い)
ので、**CCM レジスタ直読み**で確認する。

```sh
devmem 0x30388080 32     # CCM_TARGET_ROOT1 = ARM_M4_CLK_ROOT
```

デコード: bit28=ENABLE / bits26:24=MUX / bits18:16=PRE_PODF (÷N+1) /
bits5:0=POST_PODF (÷N+1)。MUX の対応表はカーネルソース
`drivers/clk/imx/clk-imx8mm.c` の `imx8mm_m4_sels[]`:

| MUX | ソース | 周波数 |
|---|---|---|
| 0 | osc_24m | 24MHz |
| 1 | sys_pll2_200m | 200MHz |
| 4 | sys_pll1_800m | 800MHz |

実測値の読み方:

- `0x11000000` = ENABLE + MUX1 = **200MHz** — **ブートデフォルト。M4 が起動して
  いない時に見える値**
- `0x14000001` = ENABLE + MUX4 + POST_PODF1 = 800÷2 = **400MHz (定格上限)** —
  Zephyr 稼働時の値

### ⚠️ 罠: M4 不在時に読むと「200MHz で動いている」ように見える

M4 クロックは **Zephyr の SoC init が自分で設定する**
(`zephyr/soc/nxp/imx/imx8m/m4_mini/soc.c`: `CLOCK_SetRootDivider(kCLOCK_RootM4,
1, 2)` + `SysPll1` = 400MHz)。つまり:

- M4 稼働中 → 400MHz (ファームが設定済み)
- M4 不在 (BL31 が M4 を起動しなかった等) → ブートデフォルト 200MHz が残る

2026-08-23 に「M4 は 200MHz で動いている、倍にできる」と誤診したのは、
stock BL31 (M4 起動パッチ抜きビルド) で **M4 が起動していない板**のレジスタを
読んだため。クロックを読む前に必ず M4 の稼働をセットで確認する:

```sh
cat /sys/class/remoteproc/remoteproc0/state    # attached であること
ip -s link show can0                            # rx が増えていること (can-gw 稼働時)
```

タイマー整合の傍証: can0 の RX レート実測 (10 秒間のカウンタ差分) が
60 frames/s (= ADC 0x700/0x701 の 30Hz×2) ぴったりなら、Zephyr の
`SYS_CLOCK` 前提と実クロックが一致している (ズレていれば周期が 2 倍/半分になる)。

## A53 のクロック確認手順 (SPL overdrive 1.8GHz の検証、2026-08-24 実測)

定常運転の確認は cpufreq sysfs で足りる:

```sh
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq        # 現在値
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies  # 1.2/1.6/1.8GHz
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor        # schedutil (負荷連動)
```

**起動時クロック (SPL が設定した値)** は事後の sysfs では見えない (cpufreq
probe 後は kernel が上書きする) ので、以下を組み合わせて検証した
(u-boot パッチ 0012 = SPL overdrive、kmm-yocto#10):

### 1. SPL 自身の検証ログ

```
kart: A53 1.8GHz (VDD_ARM 1.00V)
```

このメッセージは「BD71847 BUCK2 への書き込みが**読み戻し一致**し、かつ
`intpll_configure()` が **ARM PLL の LOCK ビット待ちを通過**した」場合にのみ
出る。失敗時は各段のメッセージ (`VDD_ARM set failed` 等) で 1.2GHz 続行。
※初版は REGLOCK を知らず "set failed" になった — BD718xx は電圧レジスタが
REGLOCK_VREG (0x2F, bit4) でロックされているのがデフォルトで、書く前に解除が要る。

### 2. ARM PLL レジスタの実値デコード (kernel の設定値との同一性)

```sh
D=$(devmem 0x30360088 32)   # ANAMIX ARM_PLL_DIV_CTL (GNRL_CTL=0x84 は周波数によらず一定なので注意)
M=$(( (D >> 12) & 0x3FF )); P=$(( (D >> 4) & 0x3F )); S=$(( D & 0x7 ))
echo "$(( (24 * M / P) >> S )) MHz"
```

- 1.8GHz OPP 時: `0x000E1030` = 24×225÷3÷2⁰ = **1800MHz**
- 1.2GHz 固定時 (governor=powersave): `0x0012C031` = 24×300÷3÷2¹ = **1200MHz**

読む前に **governor を切り替えて値が追従することを先に確認する** (デコード
手法の陽性/陰性対照)。SPL パッチが書く値は u-boot の MHZ(1800) テーブル
そのもので、kernel の 1.8GHz OPP 設定値とバイナリ一致する。
⚠ devmem と `scaling_cur_freq` の読み取りは別時刻 — ssh コマンド自体の負荷で
schedutil が昇圧するので、「アイドルのはずが 1800」に見えることがある。
固定 governor (powersave/performance) で読むこと。

### 3. VDD_ARM 電圧 (regulator sysfs)

```sh
for r in /sys/class/regulator/regulator.*; do
  [ "$(cat $r/name)" = "buck2" ] && cat $r/microvolts
done
```

1.8GHz 時 **1000000** (=1.00V、SPL が書いたのと同じ BUCK2_VOLT_RUN)、
1.6GHz 時 950000。kernel OPP 表 (imx8mm.dtsi) と一致していること。

### 4. タイミングによる物理効果の確認

fresh boot 後 uptime ~15s 時点で:

```sh
cut -d" " -f1 /proc/uptime
cat /sys/devices/system/cpu/cpu0/cpufreq/stats/time_in_state   # 単位 10ms
```

`uptime − time_in_state 合計 = cpufreq 有効化前の区間`。SPL 1.2GHz 起動では
**2.2s**、1.8GHz 起動で **1.6〜1.8s** (×0.73 ≈ CPU バウンド分が 1.2/1.8 倍に
なる予測と整合)。GUI 到達 (`systemctl show kmm.service -p
ActiveEnterTimestampMonotonic`) は平均 3.33s→2.98s (n=3/5)。

限界: 以上はレジスタ実値・電圧実値・時間効果の 3 点によるもので、ブート中の
クロックを周波数カウンタで直接測ったわけではない。

## 未踏 (次にやるなら)

- **CAN bitrate**: BL31 起動の cold boot で M4 が `set_bitrate 1000000 rc=-34`
  (ERANGE)を返す。can0 は UP・bound するが 1Mbps がぴったり設定できていない
  可能性(MCP2515 12MHz osc の分周端)。CAN 実通信検証で詰める。
- **Linux 落ちても CAN 生存**: M4 は BL31 起動で Linux ライフサイクル外に居る。
  Linux 再起動中に M4 を止めない(remoteproc detach / stop 抑止)を検証すれば
  「Linux 再起動をまたぐ CAN 常駐」が成立する。
