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

## 5. この製品で実際に触った所

- `bl31.bin` は falcon.itb の中に `atf` イメージとして同梱(load 0x920000)。
  SPL がそこに置いて**まず ATF に飛ばす** → ATF が RDC 設定してからカーネルへ。
- ケーススタディ([04](04-case-study-mu-read-reset.md))では、この ATF の
  RDC 設定に ECSPI2/GPIO を足したのが M4+CAN 問題の解決策になった。
