# 学習ノート — XPI-iMX8MM / Cortex-M4 bring-up で出てきた基礎知識

このディレクトリは、XPI-iMX8MM の bring-up(M4 統合 = rpmsg + CAN ゲートウェイ、
起動最適化・スプラッシュ 等)の過程で疑問に思って調べた内容を、後から復習できる
教材としてまとめたもの。
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

5. [フレームバッファとブートスプラッシュ](05-display-framebuffer-and-boot-splash.md)
   — FB とは、**なぜ表示中の FB への書き込みは激遅なのか(表示 DMA の帯域競合)**、
   ブートスプラッシュのバトンパス(SPL→カーネル→コンポジタ)、データ駆動 vs 手続き描画、
   コードとデータで配布経路が違う話、**一般化: 表示帯域とバトンパス(SoC/EL 非依存)**

6. [U-Boot の weak フックとパッチの作り方](06-uboot-weak-hooks-and-patching.md)
   — weak シンボル(箱は用意済み・中身だけ差し替え)、`spl_board_*` フック規約と
   探し方、devtool / git / diff -u によるパッチ生成(直書きしない)、
   quilt 適用順と patch-fuzz QA の掟

## 関連する既存ドキュメント(実務側)

- `docs/imx8mm-xpi-bringup/` — bring-up の実務記録(pitfalls 集は #26 が本件)
- `m4/repro-mu-read-reset/` — NXP 報告用の最小再現(英語)
- `local/nxp-inquiry-mu-read-reset.md` — NXP 問い合わせ文面

この教材は「なぜそうなるのか」の理解用、上記は「何をどうやったか」の記録用、
という住み分け。
