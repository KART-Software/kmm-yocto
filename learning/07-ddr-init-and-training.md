# 07 — DDR 初期化と training(lpddr4_timing.c の正体)

i.MX8M 系 SoC が電源投入直後に DRAM を使えるようにするまでの仕組み。
「timing テーブルとは何か」「training とは何か」「なぜ他ボードの設定が
半分だけ動いたりするのか」を理解するためのノート。i.MX8MP(DEBIX)で踏んだ
実例は docs/imx8mp-debix-bringup/03-first-boot.md、ここには一般論だけを書く。

## 1. なぜ SPL が DRAM を初期化するのか

リセット直後、DRAM は電気的に「何も設定されていない」状態で読み書きできない。
そのため最初に走るコード(BootROM → SPL)は **SoC 内蔵 SRAM(OCRAM)だけで動き**、
SPL の主要な仕事の一つが DRAM を立ち上げて U-Boot 本体とカーネルを置ける場所を
作ることになる([01-arm-boot-and-atf.md](01-arm-boot-and-atf.md) のブートチェーン参照)。

DRAM の立ち上げには 2 つの当事者がいる:

| 部品 | 役割 |
|---|---|
| **DDRC**(DDR Controller、Synopsys uMCTL2) | CPU からのアクセスを DRAM コマンド(ACT/RD/WR/REF…)に変換。タイミング規則・アドレスマップ・リフレッシュを司る |
| **DDR PHY**(Synopsys DWC PHY) | DDRC のコマンドを実際の高速信号(CK/CA/DQ/DQS)にして DRAM に届ける物理層。ディレイライン・ドライバ・終端を持つ |

## 2. timing テーブル = 数百個のレジスタ値の羅列

i.MX8M 系の U-Boot では、DDRC/PHY の初期化内容を C の配列として持つ:

```c
/* board/<vendor>/<board>/lpddr4_timing.c — 1,800 行前後 */
struct dram_cfg_param ddr_ddrc_cfg[] = {       /* DDRC レジスタ: {アドレス, 値} */
	{ 0x3d400304, 0x1 },
	{ 0x3d400000, 0xa1080020 },
	...
};
struct dram_cfg_param ddr_ddrphy_cfg[] = { ... };   /* PHY レジスタ */
struct dram_fsp_msg ddr_dram_fsp_msg[] = {          /* training 用パラメータ(後述) */
	{ .drate = 3732, .fw_type = FW_1D_IMAGE, ... },
	...
};
struct dram_timing_info dram_timing = { /* 上記をまとめた入口。ddr_init() が受け取る */ };
```

重要な性質:

- **手書きするものではない**。NXP の **DDR Register Programming Aid(RPA、Excel)** と
  **DDR Tool / Config Tools for i.MX** に「DRAM チップの型番・密度・構成・動作レート・
  基板の配線(バイト/ビットの入れ替え)」を入力して生成する
- したがって **テーブルは「ボード配線 + DRAM チップ」の組み合わせに固有**。
  同じ SoC でもチップが違えば別物になる
- **MTS** = MegaTransfers/秒。DDR はクロックの両エッジで転送するので
  4000MTS = クロック 2000MHz、3732MTS = 1866MHz
- **fsp**(frequency set point)= レートのプリセット。P0 = 定格(3732 等)、
  P1/P2 = 低速(400/100MTS)。省電力時にレートを落とすために複数持ち、
  training も各 fsp について行う

## 3. テーブルの中身は 3 系統 — 混ぜて考えると誤診する

同じファイルに性質の違う情報が同居している。何が壊れているかを考えるときは
どの系統の話かを分けること。

| 系統 | 決まる要因 | 間違えたときの症状 |
|---|---|---|
| **信号タイミング**(tRCD/tRP/tRAS/tRFC…、PHY のディレイ・ドライブ強度・ODT・VREF) | DRAM の速度グレード + 動作レート + 基板の信号品質 | training 失敗、または通っても不安定(ストレスで散発エラー) |
| **アドレスマップ**(DDRC ADDRMAP: 物理アドレスの各ビット → row/column/bank/rank) | DRAM の密度・構成(×16/×32、ダイ数、ランク数) | **training は通る**のに一部アドレス範囲が化ける/エイリアスする |
| **初期化シーケンス**(Mode Register 値、CKE/リセットのタイミング) | JEDEC 規格 + チップの推奨値 | 初期化途中で応答なし(ハング) |

とくにアドレスマップは要注意で、**「training 通過 = メモリ全域が正しい」ではない**。
U-Boot は DRAM の先頭付近しか使わないので無症状のまま進み、カーネルが起動時に
全ページを触った瞬間に死ぬ、という潜伏の仕方をする。

## 4. training とは — PHY ファームウェアによる実基板校正

レジスタ値を流し込んだだけでは数 GHz 級の信号は安定しない。配線長・温度・個体差で
ビットごとの到着タイミングがずれるため、DDR PHY 上で **NXP 配布の training
ファームウェア**(`lpddr4_pmu_train_1d/2d_{imem,dmem}.bin`。imx-boot に同梱される)を
実行して、実基板の上で遅延を校正する。

- **1D training**: 書き込み/読み出しの遅延(ビットごとのディレイライン)を、
  実際にパターンを読み書きしながら合わせ込む
- **2D training**: 電圧軸も含めて信号の「アイ(eye)」の中心を探す精密版
- SPL のログでは成功が `DDRINFO: ddrphy calibration done`、失敗が `Training FAILED`

training が通るということは「信号品質・タイミングの前提(基板とチップの電気的相性)が
合っている」ことの証明で、それ以上でもそれ以下でもない(§3)。

## 5. 初期化が「前回の状態」に依存しうる理由

`ddr_init()` は毎回 SRC 経由で DDRC/PHY をリセットしてから始めるが、
**DRAM デバイス側の状態はリセットされない**ことがある。LPDDR4 のチップは
Mode Register(MR)に VREF(基準電圧)・ODT(終端)・FSP(どのレートセットで動くか)
などを持ち、一度初期化されるとそれが残る。

すると、あるテーブルで初期化が成功した直後なら別のテーブルでも training が通るのに、
電源投入直後のコールド状態から同じテーブルを流すとハングする、という
**順序依存**が起こりうる。ベンダーの製品 SPL が複数テーブルを順に試す実装
(§6)だと、この依存が「たまたま」満たされていて見えなくなる。

教訓: **「テーブルが正しい」と「コールドから 1 発で通る」は別**。挙動を再現する
ときは、どのテーブルを使うかだけでなく**何を先に流したか**まで揃える。

## 6. 製品 SPL の定石: DRAM ID による multi-probe

複数の DRAM 調達先に 1 バイナリで対応するボードベンダーは、次のパターンを使う:

```
候補テーブルを順に ddr_init() → training 失敗なら次へ
→ 通ったら DRAM の Mode Register(MR5〜MR8 = メーカー/密度/リビジョン ID)を読む
→ ID でチップを特定 → そのチップ専用テーブルで再初期化
```

LPDDR4 の MR5 = Manufacturer ID(0xFF = Micron、0x01 = Samsung、0x06 = SK hynix)、
MR6/7 = リビジョン、MR8 = 密度・種別。読むには一度 DRAM が動いている必要があるので
「まず何かで通す」工程が要る — これが §5 の順序依存を生む温床でもある。

## 7. 触るときの原則

1. lpddr4_timing.c は**生成物**。別チップ/別ボードへ流用するときは、信号タイミング・
   アドレスマップ・初期化シーケンスのどれが合っていてどれが違うかを分けて考える。
   正道は RPA + DDR Tool で再生成。ただし**同じ基板配線・同じレートで密度だけ違う**
   場合は、密度由来のレジスタ(ADDRMAP の行/バンクビット、tRFC を含む RFSHTMG と
   t_xsr = DRAMTMG14、それらの各 fsp 分)だけ差し替えれば済むことが多い —
   tRFC はナノ秒値をそのレートのコントローラクロックでサイクル換算し直すこと
2. training 失敗は SPL 即死でシリアルに出る(一発診断)。アドレスマップ違いは
   **カーネルの全ページ初期化まで潜伏**する — earlycon 必須、`mem=` で切り分ける
3. 検証は training 通過で満足せず、**RAM 全域(特に上位バンク)にパターンを書いて
   読み戻す**ところまでやる
4. SDP/UUU 経由で SPL を送り込んで途中で止まるときも、実は DDR で死んでいることがある
   (BootROM は SPL 分しか読まないので、残りの転送タイムアウトという別の顔で見える)
