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
(OCRAM `0x920000`)で走る ATF(BL31)側でやる**のが正解。詳細は
[learning/03](../../learning/03-m4-coprocessor-rpmsg.md) §「SPL 起動の壁」。

概念の詳細は [learning/03](../../learning/03-m4-coprocessor-rpmsg.md) §2-3。

## 未踏 (次にやるなら)

- **M4 起動を ATF(BL31)側で実装**: SPL は M4 loadable を DDR(`0x46000000`)
  に運ぶだけ(falcon.itb 設定済み)。BL31 は OCRAM(`0x920000`)で走る = TCM を
  書いても自分は消えないので、BL31 の plat 初期化で **DDR→TCML コピー + SRC 解除**
  (`SRC_M4RCR`: NON_SCLR_RST クリア + M4_ENABLE セット。GPC 操作は不要)。
  falcon.itb の M4 loadable(DDR staging 版)と firmware の attach 対応
  (0xB80FF000 自己 publish)は実証済みで流用可。SPL 起動アプローチ
  (旧 0011 パッチ)は「SPL が TCM で走る」ため原理的に不可。
- 用途の本命は CAN 早期化・Linux 再起動をまたぐ常駐 (ECSPI2 の
  MCP2515 は既に M4 所有に移済 = can-gw)。次は「Linux 落ちても CAN 生存」
