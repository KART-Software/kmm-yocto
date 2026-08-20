# ARM のブートチェーンと ATF

## 1. 特権レベル(Exception Level, EL)

ARMv8-A(64bit)には 4 段の特権レベルがある。数字が大きいほど強い。

```
EL0  アプリ (ユーザ空間)         ← 一番弱い
EL1  OS カーネル (Linux)
EL2  ハイパーバイザ (KVM 等)
EL3  セキュアモニタ (ATF/BL31)   ← 一番強い、SoC の土台
```

上位は下位のできないことができる。下位から上位へは「命令一発のトラップ」で
しか行けない(勝手には上がれない):

| トラップ命令 | どこから | どこへ | 例え |
|---|---|---|---|
| `svc` | EL0 アプリ | EL1 カーネル | **syscall**(open/read) |
| `hvc` | EL1 | EL2 ハイパーバイザ | ハイパーコール |
| `smc` | EL1 | EL3 モニタ(ATF) | **SMC** |

**syscall と SMC は同じ構造**。「自分では触れないものを、より上位に代行して
もらう」トラップ。syscall がアプリ→カーネルなら、SMC はカーネル→ATF。
つまり **SMC は「カーネルにとっての syscall」**。

## 2. ブートチェーン(i.MX8MM)

電源投入から Linux まで、複数のファームがバトンを渡す:

```
① BootROM    SoC 内蔵 ROM。電源直後に必ず動く。次段を eMMC/SD/USB から読む
                (S1 スイッチでどこから読むか・USB 待ちかが決まる)
② SPL        U-Boot の第1段(小さい)。主目的は DRAM 初期化。次に ATF を読む
③ BL31 (ATF) ★ EL3 で起動。RDC/電源/SMC 窓口を設定。以後 EL3 に常駐
④ U-Boot     本体。BL31 が EL2 に落として起動。extlinux/falcon でカーネルを起動
⑤ Linux      EL1 で起動。以後、電源・CPU・M4 操作は smc で ③ を呼ぶ
```

- **BootROM**: 変更不能。S1=Serial Download にすると次段を eMMC でなく
  **USB(SDP)から待つ** → これが UUU リカバリの入口。文鎮っても S1 を倒せば
  ここから復旧できる。
- **SPL**: DRAM を立ち上げるのが最重要(それまで DRAM が使えない)。
- **falcon モード**(この製品):SPL が U-Boot 本体を飛ばして **直接カーネルを
  起動**する高速化。`falcon.itb` に ATF+カーネル+DTB を詰めてある。

## 3. ATF / BL31 とは

**ATF = ARM Trusted Firmware**。ARM 公式のセキュアブート初期化ファーム。
i.MX では **BL31** という常駐部分を使う(我々が触った `bl31.bin` /
`imx8mm_bl31_setup.c`)。役割は 3 つ:

### (a) EL3 に常駐する「監視役」
③ で起動して**終わらない**。EL3 に居座り続け、④⑤ が動く裏で待機する。
Linux(EL1)が直接触れないハードを代行する。

### (b) SMC の窓口(電源・CPU・M4)
Linux が特権操作をしたい時に `smc` で BL31 を呼ぶ:
- **PSCI**(CPU の on/off、システム reset/poweroff)
- **SIP**(Silicon Provider 固有)= i.MX 固有の操作。**M4 起動もこれ**

### (c) ブート最初期の SoC アクセス制御 ← 今回の核心
Linux が動く**前**に、後から緩められないハード関所を確定させる:
- **RDC**(どのマスタがどのペリフェラルを触れるか)→ [02 参照](02-rdc-and-domains.md)
- CSU / AIPSTZ / TZASC(セキュア/非セキュア分離)

**一行**: ATF(BL31)= EL3 に常駐して、Linux の特権操作を代行し、ブート最初期に
SoC のアクセス制御を確定させる土台ファーム。

## 4. `IMX_SIP_SRC_M4_START` の正体

**レジスタではない。SMC の「関数番号」**(伝票番号)。

M4 を起動する時の流れ:
```
Linux (remoteproc):
    arm_smccc_smc(IMX_SIP_SRC, IMX_SIP_SRC_M4_START, addr, ...);
       ↓ ラッパが x0..x7 にセットして smc #0 を実行 (libc の read が svc を
         実行するのと同じ構造)
ATF (BL31, EL3):
    x0 の番号 IMX_SIP_SRC_M4_START を見て分岐
       ↓ 実際に SRC(System Reset Controller, 0x30390000+)の
         M4 reset 解除ビットを書く = M4 が走り出す
```

- `SIP` = Silicon Provider。ARM の SMC 呼び出し規約(**SMCCC**)には
  ベンダ専用の番号帯があり、NXP が `IMX_SIP_*` として使っている。
- なぜ Linux が直接 SRC を書かないか = SRC は EL3 管理の特権リソースで、
  Linux(EL1)からは触らせない設計だから。だから ATF に代行を頼む。

`/sys/class/remoteproc/remoteproc0/state` に `start` と書くと、この SMC が
飛んで M4 が起動する、という繋がり。

## 5. EL 遷移のメカニズム — 例外で上がり、ERET で下がる

EL の移動は 2 方向しかない:

- **上がる = 例外**(SMC / IRQ / トラップ)。種類ごとに行き先の EL が
  決まっていて**直行**する。SMC の行き先は定義上 EL3(BL31 のベクタ)なので、
  カーネル(EL1)の SMC は EL2 を経由せず **1 ホップで EL3 へ**届く
  (2 段になるのはハイパーバイザが HCR_EL2.TSC で横取りする仮想化構成のみ)
- **下がる = ERET(例外リターン)**。`ELR_EL3`(飛び先)と `SPSR_EL3`
  (行き先 EL・NS bit)をセットして ERET すると、CPU がその EL に降りて
  飛び先から実行を始める

**BL31 が BL33 を「起動」する実体はこの ERET**。BL31 は自分は EL3 から
一歩も出ずに、`ELR_EL3=0x40200000 / SPSR=EL2h / SCR_EL3.NS=1` を仕込んで
ERET → CPU が EL2・Non-secure でシムから走り出す。BL31 のコード・スタック・
ベクタは EL3 に置き去りのまま残るので、後の SMC でちゃんと戻れる。
カーネルがユーザプロセス(EL0)を起動するのも全く同じ ERET 機構。

### BL33 は常駐しない

BL33 = 「Non-secure 世界の最初の走者」という**役割名**で、仕事を終えたら消える:
- 通常構成: BL33 = U-Boot proper(env/extlinux/カーネルロード後、booti で消滅)
- falcon 構成: BL33 = **8 命令のシム**(x0=DTB を積んでカーネルへ分岐。寿命は
  ナノ秒オーダー、残骸はカーネルが RAM として回収)

常駐するのは BL31(EL3)だけ。「BL33 は次の走者、BL31 は走り終わっても
管理人室に残る人」。

### なぜ EL2 で入場させて安全なのか

「カーネルが EL1 に降りる保証は無いのに EL2 で渡していいのか?」への答えは 2 つ:

1. **arm64 Linux のブート規約**(Documentation/arm64/booting)が「EL2(推奨)
   または EL1 で入場」と定めており、カーネル入口(head.S)は CurrentEL を
   自分で読んで処理する。A53(ARMv8.0、VHE 無し)では EL2 に KVM 用の
   hyp スタブを置いてから自分で EL1 に降りる — 「降りる」はカーネル側の契約
2. **仮に降りなくても壊れる境界が無い**。ファームウェアが守る境界は
   EL3/Secure vs Non-secure であって EL2/EL1 間ではない。NS へ渡した時点で
   EL2〜EL0 は丸ごと OS の持ち物(VHE のある SoC では Linux 自体が EL2 で
   動き続ける)。むしろ EL は上がれないので、EL1 で渡すとその OS は永遠に
   KVM を使えなくなる — EL2 で渡すのは「NS 全権の委譲」という積極的な設計

## 6. この製品で実際に触った所

- `bl31.bin` は falcon.itb の中に `atf` イメージとして同梱(load 0x920000)。
  SPL がそこに置いて**まず ATF に飛ばす** → ATF が RDC 設定してからカーネルへ。
- ケーススタディ([04](04-case-study-mu-read-reset.md))では、この ATF の
  RDC 設定に ECSPI2/GPIO を足したのが M4+CAN 問題の解決策になった。
