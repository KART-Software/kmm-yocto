# 学習ノート — XPI-iMX8MM / Cortex-M4 bring-up で出てきた基礎知識

このディレクトリは、XPI-iMX8MM の M4 統合作業(rpmsg + CAN ゲートウェイ)の
過程で疑問に思って調べた内容を、後から復習できる教材としてまとめたもの。
実機で実際に触ったこと・ハマったことに紐づけてあるので、抽象論だけより
記憶に残りやすいはず。

## 目次

1. [ARM のブートチェーンと ATF](01-arm-boot-and-atf.md)
   — 特権レベル(EL0〜EL3)、BootROM→SPL→BL31→U-Boot→Linux、
   ATF/BL31 とは、SMC と syscall の違い、`IMX_SIP_SRC_M4_START`

2. [RDC とドメイン](02-rdc-and-domains.md)
   — RDC(リソースドメインコントローラ)とは、MDA/PDAP、
   デバイスツリーとの関係、なぜ Linux の devmem では効かないのか、
   ATF バイナリへの埋め込み、**一般化: マスタ ID ベースのバスファイアウォール
   (他ベンダ SoC にも同型。EL/特権では突破できない)**

3. [M4 コプロセッサと rpmsg](03-m4-coprocessor-rpmsg.md)
   — remoteproc、リソーステーブル、rpmsg/virtio/MU/vring、
   「セッション」とは、CAN を Linux に渡す 2 つの設計

4. [ケーススタディ: MU read reset の謎](04-case-study-mu-read-reset.md)
   — 実際に踏んだバグの全記録。真因(ATF の RDC 設定漏れ)、
   解決、レイテンシ比較、GPIO ドアベル案

## 関連する既存ドキュメント(実務側)

- `docs/imx8mm-xpi-bringup/` — bring-up の実務記録(pitfalls 集は #26 が本件)
- `m4/repro-mu-read-reset/` — NXP 報告用の最小再現(英語)
- `local/nxp-inquiry-mu-read-reset.md` — NXP 問い合わせ文面

この教材は「なぜそうなるのか」の理解用、上記は「何をどうやったか」の記録用、
という住み分け。
