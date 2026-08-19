# M4 コプロセッサと rpmsg

## 1. 構成のおさらい

i.MX8MM は **A53(メイン、Linux)+ Cortex-M4(サブ、400MHz)** の非対称
マルチコア(AMP)。M4 は Linux とは別の小さいファーム(ベアメタル or Zephyr)を
走らせ、リアルタイム I/O(CAN、ADC、GPIO)を担当させる用途。

- **TCM**(Tightly-Coupled Memory)= M4 専用の高速 SRAM。128KB×2
  (TCML=命令、TCMU=データ)。M4 はここから実行する。
- A53 から見ると M4 の TCM は別アドレスに見える(例: M4 の TCMU
  `0x20000000` = A53 物理 `0x00800000`)。デバッグで `devmem 0x800100` で
  M4 のブレッドクラムを覗けたのはこれ。

## 2. remoteproc — Linux が M4 を起動する仕組み

Linux の **remoteproc** サブシステムが M4 のライフサイクルを管理する。

```
echo <fw>.elf > /sys/class/remoteproc/remoteproc0/firmware
echo start    > /sys/class/remoteproc/remoteproc0/state
```
で何が起きるか:
1. Linux が ELF ファイルをパースし、各セグメントを M4 の TCM にコピー
2. ELF 内の `.resource_table` セクションを読む(下記)
3. ATF に `IMX_SIP_SRC_M4_START` の SMC を投げて M4 の reset を解除
   → M4 が走り出す

**起動経路は 3 通り**あり、今回はずっと (a):
- (a) **Linux remoteproc + ATF SIP**(上記)
- (b) **U-Boot の bootaux**(Linux より前に M4 を起動)
- (c) **SPL の falcon.itb に loadable として同梱**(Linux より前・U-Boot proper も
  経由せず、電源投入 ~数百 ms で M4 起動)。(b)(c) はどちらも「Linux が起動した
  ときには M4 が既に走っている」ので、Linux は attach する形になる(§3・下記)

### M4 ファームを loadable に載せられるか(can-gw = Zephyr で実測)

can-gw の `zephyr.elf` を読んで確認した事実(`readelf -l`):
- LOAD は実質 TCML 起点 `0x1FFE0000` の 1 本(code+rodata 0x90F0B)。
  **Zephyr は .data のロード元をコード直後に置き、起動時に自分で TCMU
  (`0x20000000`)へコピーし bss もゼロ化する**(自己再配置)。
- つまり `zephyr.bin`(実測 37KB、TCML 128KB に余裕)は
  **「`0x1FFE0000` 起点の連続イメージ 1 本」**で、これを falcon.itb の
  loadable 1 個(A53 視点 `0x007E0000` へロード)にするだけで配置は完了する。
  ベアメタルで想定した「code / data の 2 loadable」より簡単。
- `.resource_table` もイメージ内(実測 `0x1FFE937C` = TCM)に一緒に運ばれる。
  **ただしこのアドレスはビルドごとにずれる**。

**結論の切り分け**: loadable 化(FIT の作り方)は容易。難所は 2 つ — ① attach
(下記)と、② **M4 を SPL で起動できない**。当初は「SPL は EL3 だから
SRC_M4RCR 直書きで解除できる」と考え、次に「電源ドメイン」と誤診したが、
真因は **SPL 自身が TCM で実行されているため、M4 を TCM にロードすると走行中の
SPL を自己上書きしてハングする**ことだった(下記「SPL 起動の壁」で確定)。
M4 のロード+起動は TCM 外(OCRAM)で走る **ATF(BL31)側**でやるのが正解。

### attach の実機検証(2026-08-19、can-gw で実施)

「M4 を先行起動 → Linux が attach」経路を実機で切り分けた結果:

- **DT は attach 対応済み**。reserved-memory に `rsc-table@b80ff000` /
  `vdev0vring0@b8000000` / `vdev0vring1@b8008000` /
  `vdevbuffer@b8400000`(shared-dma-pool)が宣言済み。ドライバは
  `imx-rproc`(`fsl,imx8mm-cm4`)、カーネル 6.12.20-fslc。
- **rsc_table を書くのは Linux(load 時)であって M4 ではない** ← attach の核心。
  実測: `0xb80ff000` をゼロ化して stop→start すると version=1/num=1 に
  **再populate される**(Linux が ELF から読んで DT の rsc-table 領域へ書く)。
  一方 **M4 稼働中**にゼロ化して 3 秒待っても**ゼロのまま**(M4 は書き直さない)。
  → 現行 can-gw は attach 非対応。attach では Linux は ELF をパースせず
  `0xb80ff000` を**読む**側に回るので、**M4 firmware 自身がそこへ
  rsc_table を発行する**改修が要る(Zephyr のリンカで .resource_table を
  この固定 DDR 番地に置く等)。
- **rsc_table は setup 時のみ使用**。稼働中にゼロ化しても rpmsg は無事
  (can0 は UP のまま)= steady-state のデータ経路(vring)には無関係。
- **software だけでは attach 経路を再現できない**。sysfs の `detach` は
  この build で非対応(`echo detach > state` → "Unrecognised option")、
  imx-rproc は built-in で boot 時に probe する。attach の完全再現には
  **M4 を Linux より前に起動する実物**(SPL loadable か bootaux)が要る。

### attach を bootaux で完全実証(2026-08-19)

上記の firmware 改修(**M4 が rsc_table を 0xB80FF000 に自己 publish**、有効な
テーブルが無いとき=attach のときだけコピー。LOAD 時は Linux が先に version=1 を
書くので上書きしない)を入れ、**stock U-Boot の `bootaux`**(flash.bin 無傷で
RAM 起動、attach を安全に試せる)で全経路を通した:

- bootaux で M4 起動 → M4 が `rsc_table published to 0xB80FF000 (attach mode)`
  を出力(改修が発火)、`peer 0xffffffff / started=0` で Linux 待ち
- eMMC カーネル起動 → dmesg `attaching to imx-rproc` → `is now attached`、
  `remoteproc state = attached`
- `kart-can channel bound`、**can0 UP**、M4 側 `peer 0x400 / started=1`(双方向確立)

→ **「M4 先住 → Linux attach → can0 稼働」は完全に成立**。imx_rproc は
稼働中 M4 を probe 時に検出して attach する(`imx_rproc_attach` 実在)。

### SPL 起動の壁 — 電源ドメイン(2026-08-19、実機で確定)

falcon.itb に M4 loadable を積み、**SPL で M4 を起動**しようとしたら
**デッドハング**した(コンソールが `falcon_args...default` の直後で沈黙)。

**真因(2 転して確定)**: 最初「SPL は EL3 だから SRC 直書きで起動」と考え、
次に「ATF 前は M4 電源ドメイン OFF で TCM に書けない」と誤診した。実際は
**SPL 自身が TCM 内で実行されている**:

- flash.bin の IVT の entry = **`0x007E1000`**(実測)。imx8mm の TCM は
  `0x7E0000`〜`0x820000`(ATF `IMX_TCM_BASE=0x7E0000 / SIZE=0x40000`)。
  つまり **SPL は TCM の中で動く**(imx8m SPL は OCRAM/TCM を実行 RAM に使う)。
- M4 loadable を TCML(`0x007E0000`〜)に置くと、**走行中の SPL(`0x7E1000`)を
  自己上書き**して即ハング。「電源ドメイン OFF」ではなく「自分を消す」だった。
- **DDR 経由でも同じ**: SPL が DDR→TCM へ memcpy しても、その memcpy コード
  自体が TCM にあり途中で消える。**TCM への配置は TCM 外で走るコードからしか
  できない**。
- bootaux が成功したのは **U-Boot proper が DDR(`0x40200000`)で走る**から
  (TCM を書いても自分は消えない)。ATF/電源ドメインは無関係だった。
  ちなみに imx8mm の ATF `IMX_SIP_SRC_M4_START` は **SRC 書き込みのみ**
  (GPC 電源ドメイン操作も GPR0x58 も無し)= M4 ドメインは元々 ON。
- **結論: M4 の TCM 配置+起動は、TCM 外(OCRAM `0x920000`)で走る
  ATF(BL31)側でやる**。SPL は loadable を DDR に運ぶだけ、BL31 が
  DDR→TCM コピー + SRC 解除する。

## 3. リソーステーブル

M4 ファームが「Linux と何を共有したいか」を宣言する構造体。ELF の
`.resource_table` セクションに置く。主に **vdev**(仮想デバイス)を宣言し、
vring とバッファの位置を伝える。Linux はこれを読んで rpmsg を張る。

- remoteproc 起動なら Linux が ELF から読む
- bootaux 起動なら M4 が自分で DT の rsc-table 領域(0xB80FF000)に書く必要
  (Linux は「稼働中の M4 に attach」する形になる)

## 4. rpmsg / virtio / MU / vring — Linux ↔ M4 通信

**rpmsg = 共有メモリ(vring)+ 通知(MU)による軽量メッセージング。**
Linux 標準の virtio の上に乗っている。要素を分解:

```
┌─────────── DDR(共有メモリ)───────────┐
│  vring0 / vring1  = メッセージのリング   │  ← データはここに置かれる
│  vdevbuffer       = バッファ本体         │
└──────────────────────────────────────┘
        ▲ 書く/読む            ▲ 書く/読む
       A53(Linux)            M4
        │                      │
        └──── MU(通知)───────┘  ← 「置いたよ」のドアベルだけ
```

- **vring**(DDR 上)= 実データが載るリングバッファ。生産者が書き、消費者が読む。
- **MU**(Messaging Unit)= コア間の**ドアベル**。データは運ばない。
  「vring に置いたから見て」の合図だけ。

### MU はレジスタ書き込み
- M4→A53 のキック = **M4 が MU の TR(送信)レジスタに write** → A53 に割り込み
- A53→M4 のキック = A53 が write → **M4 が MU の SR/RR を read**(ISR で)

重要な非対称性(今回のバグの鍵):**MU への write は安全、MU の read も安全。
だが「MU 受信機構が動いている状態 × M4 の他ペリフェラル read」が毒**だった。

### メモリ属性の注意
M4 はキャッシュ無し、vring は非キャッシュ/コヒーレント領域にマップ。
インデックス更新にはメモリバリアが要る(lock-free リングの定石)。

## 5. 「セッション」とは(rpmsg にセッションはあるのか)

会話で「セッション稼働中」と略記したが、正確には**プロトコル的な
接続/切断のあるセッションではない**。指すのは:

> **virtio リンクが確立した状態** = Linux の virtio_rpmsg が probe し、
> リソーステーブルの vdev に **DRIVER_OK を書き**、vring が生きていて、
> **MU ドアベルが往来している**状態。

- この状態は remoteproc 起動時に Linux が**自動的に**作る。ユーザ空間不要。
- 「切断」= 解体 = remoteproc stop = **M4 ごと止まる**。だから「SPI を触る
  たびにセッションを切る」は実質不可能(= M4 停止)。
- 実験で「rsc table 無し(= Linux が MU を触らない)」なら同じ GPIO read が
  通ったのは、この**セッションが張られていない**から。

## 6. CAN を Linux に渡す 2 つの設計(検討した案)

M4 が受けた CAN フレームを Linux に届ける方法:

### 案 A(検討時の呼称そのまま): vcan + ユーザ空間 rpmsg ブリッジ
- Linux に vcan(仮想 CAN)を立て、ユーザ空間デーモンが rpmsg エンドポイントを
  読んで vcan に流す。
- 素朴だが、ユーザ空間を挟むぶんレイテンシ/オーバーヘッドが乗る。

### 案 B(採用しかけた): カーネル rpmsg ドライバ → CAN netdev(rpcan0)
- カーネルモジュール `kart-rpmsg-can` が rpmsg チャネル "kart-can" に bind し、
  **CAN netdev `rpcan0` を生やす**(vcan 風だがバックエンドが rpmsg)。
- Linux から見れば普通の CAN インターフェース。`candump rpcan0` がそのまま
  使える。設計が綺麗。
- rpmsg_tty がチャネル名で bind するのと同じ仕組み。rpmsg バスは多重化
  されているので、他サービスは別名チャネル(ept)を並行利用できる。

どちらも rpmsg(= MU)前提。今回のバグで一時ブロックされたが、ATF の RDC
修正([04](04-case-study-mu-read-reset.md))で道が開けた。

## 7. MU を使わない代替(バグ回避策として検討)

RDC 修正が見つかる前に検討した、MU に依存しない設計:

- **ポーリング**: M4 が CAN を共有 DDR リングに write、Linux が ~1kHz で
  ポーリング read。MU 不使用。遅延 ~1ms、CPU <0.5%。
- **案 A(GPIO ドアベル)**: M4 が DDR に write + 空き GPIO をトグル(write)
  → 同一ピンの入力側 GPIO 割り込みで Linux 起床(配線不要、ヘッダー非搭載
  ピンで可)。MU 不使用で割り込み駆動、遅延 ~10-30µs。

レイテンシ比較は [04 の該当節](04-case-study-mu-read-reset.md#レイテンシ比較)。
最終的には RDC 修正で rpmsg(MU)がそのまま使えるようになったので、これらは
保険(後回しの宿題)になった。
