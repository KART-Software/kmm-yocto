# 10 — 割込みの配達係: GIC(A53 側)と NVIC(M コア側)

DEBIX (8MP) のハード構成図を描いていて「RDC は BL31 の中の話だと思っていた」
「GIC って何」が出てきたので、**「誰がアクセスしてよいか」(RDC)と「誰に割込みを
届けるか」(GIC)は別物のハード**、という整理。

## 1. GIC とは

**GIC = Generic Interrupt Controller。Arm 純正の割込みコントローラ IP で、
A53 クラスタ専用の「割込みの配達係」。** i.MX8MP が積んでいるのは GIC-500
(GICv3 の実装、RM 1.4.2.1)。SoC 内の独立ブロックで、レジスタは

```
0x3880_0000  GICD (Distributor)     64 KB   全体の有効化・各割込みの enable/優先度/行き先コア
0x3888_0000  GICR (Redistributor)   コア毎   そのコア固有の割込み(PPI/SGI)の enable
```

(DT: `gic: interrupt-controller@38800000 { compatible = "arm,gic-v3"; reg = <0x38800000 0x10000>, <0x38880000 0xc0000>; }`)

ペリフェラルの割込み線は全部ここに集まり、GIC が優先度を付けて、指定された
A53 コアの IRQ/FIQ 端子を叩く。コアは EL1(Linux)か EL3(BL31)の例外ベクタへ飛ぶ。

### 3 種類の割込み

| 種類 | 番号 | 例(この製品) |
|---|---|---|
| SPI (Shared Peripheral Interrupt) | 32〜 | ペリフェラル全部。FlexCAN1 = `GIC_SPI 142`(= 線番号 174) |
| PPI (Private Peripheral Interrupt) | 16〜31 | コア毎の Generic Timer、PMU |
| SGI (Software Generated Interrupt) | 0〜15 | コア間 IPI(Linux のスケジューラが使う) |

DT の `interrupts = <GIC_SPI 142 IRQ_TYPE_LEVEL_HIGH>;` の 142 は SPI の番号で、
GIC 内部の線番号は +32 した 174。

## 2. M コア側は NVIC — 同じ線が両方に配線されている

Cortex-M7 は GIC を使わない。**M7 コア内蔵の NVIC** が自分の割込みコントローラ。
重要なのは、**ペリフェラルの割込み線の多くが GIC と NVIC の両方に同じ番号で
配線されている**こと:

```
Linux  DT : flexcan1 interrupts = <GIC_SPI 142 ...>   ← GIC の SPI 142
Zephyr DT : flexcan1 interrupts = <142 3>, <143 3>;   ← NVIC の IRQ 142(優先度 3)
```

だから can-gw(M7)が FlexCAN1 を直接駆動できる: Linux 側で flexcan1 を
disabled にすれば Linux は enable せず、M7 の NVIC だけが受け取る。
「どちらが受けるか」は GIC/NVIC の enable で決まり、**RDC は関与しない**
(RDC が決めるのはレジスタへのアクセス権)。

MU(メールボックス)も同じ発想で、MU-A 側の IRQ は GIC(Linux)へ、MU-B 側の IRQ は
NVIC(M7)へ配線されていて、片側に書くと相手側の割込みが上がる(= rpmsg の kick)。

HDMIMIX の `irqsteer@32fc2000` は、HDMI ブロック群の細かい割込みを束ねて GIC の
1 本に乗せる「中継器」。GIC の線が足りない領域でこういう集約器が入る。

## 3. 誰が GIC を設定するか

- **BL31(EL3)**: ブート時に GIC の全体設定とセキュア側(Group 0 / 1S)を初期化する。
  非セキュア OS に渡す前の「配電盤の主幹」はここ。
- **Linux(EL1)**: `irq-gic-v3` ドライバが非セキュア側(Group 1NS)を初期化し、
  ドライバの probe ごとに SPI を enable。起動時間の内訳(30-boot-time.md)の
  「RNG/GIC + eMMC init 0.04 s」がこれ。
- **実機で踏んだ例**: hibernation の SPL 直接復帰では、復帰先カーネルが
  「ブートカーネルが GIC を整えてくれている」前提で動くため、トランポリンが
  自前で `GICD_CTLR |= 3`、`GICD_ISENABLER[1..5]`、`GICR_ISENABLER0 = 0x4080007F`
  (SGI0〜6 / PMU PPI23 / timer PPI30)を書き戻す必要があった。GIC が初期化されて
  いないと、割込みが一切届かず復帰後に止まる。

## 4. RDC との対比(混同しやすい)

| | RDC | GIC |
|---|---|---|
| 役割 | バスアクセスの**許可**(どのマスタがどのペリフェラルを読み書きできるか) | 割込みの**配達**(どの割込みをどのコアへ) |
| 場所 | 0x303D_0000(AIPS1 の並び) | 0x3880_0000 |
| 設定役 | BL31 が bl31.bin 内の表から書き、以後ロック(8MM)。8MP は Zephyr の SoC init が MDA を書いて M7 を domain 1 へ | BL31 がセキュア側、Linux が非セキュア側 |
| 違反すると | アクセスが弾かれる(8MM では SoC リセットに至った) | 届かないだけ(待ちで止まる) |
| M コア側 | 同じ RDC(ドメイン 1 として扱われる) | 別物の NVIC |

「RDC は BL31 の中の話」と見えるのは、**この製品で RDC に触るコードが
BL31 のパッチ(8MM)と Zephyr の SoC init(8MP)にしか無い**から。レジスタは
SoC の中にあり、`devmem 0x303D0204`(MDA[1])で `0x1` が読めるのはその証拠
(02-rdc-and-domains.md §2)。

## 5. まとめ

```
ペリフェラル ──IRQ線──┬─→ GIC-500 (0x3880_0000) ─→ A53 ×4 (EL1 Linux / EL3 BL31)
                      └─→ NVIC (M7 内蔵)        ─→ M7 (Zephyr)
                 どちらが受けるかは enable 次第、RDC は無関係
ペリフェラル ←─レジスタアクセス─ RDC (0x303D_0000) が許可/拒否 ← BL31 / Zephyr が設定
```
