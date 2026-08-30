---
name: imx8mm-m4-knowledge
description: i.MX8MM の低レベル概念(ARM のブート/特権レベル/ATF・BL31、RDC とドメイン、Cortex-M4 コプロセッサ、remoteproc/rpmsg/virtio/MU、SMC/SIP)についてユーザが「〜って何」「なぜそうなる」と尋ねたとき、または M4/ブートローダ/カーネル周りで新しい知見が得られたときに使う。教材 learning/ を参照して答え、恒久的な新知識が出たら同じ教材を逐次更新して最新に保つ。
---

# i.MX8MM / Cortex-M4 の知識ベース(参照 + 継続更新)

XPI-iMX8MM の M4 統合作業で積み上げた低レベル知識の教材が、
プロジェクトルートの `learning/` にある(リポジトリ管理下)。この skill は
「その教材を参照して答える」ことと「新しい知識が出たら教材を更新して最新に
保つ」ことの両方を担う。この skill 自体(.claude/skills/)も管理下。

## 教材の構成

| ファイル | 扱う概念 |
|---|---|
| `learning/README.md` | 索引 |
| `01-arm-boot-and-atf.md` | 特権レベル EL0〜EL3、BootROM→SPL→BL31→U-Boot→Linux、ATF/BL31、SMC vs syscall、IMX_SIP_SRC_M4_START |
| `02-rdc-and-domains.md` | RDC、MDA/PDAP、DT との関係、なぜ devmem で効かないか、bl31.bin への埋め込み |
| `03-m4-coprocessor-rpmsg.md` | TCM、remoteproc、リソーステーブル、rpmsg/virtio/MU/vring、「セッション」、CAN の 2 設計、MU 非依存代替 |
| `04-case-study-mu-read-reset.md` | MU read reset バグの全記録、真因(ATF RDC 設定漏れ)、解決、レイテンシ比較 |
| `05-display-framebuffer-and-boot-splash.md` | 表示チェーン、フレームバッファ、ブートスプラッシュの仕組み |
| `06-uboot-weak-hooks-and-patching.md` | weak シンボルによる拡張点、パッチの作り方・運用 |
| `07-ddr-init-and-training.md` | DDRC/PHY、timing テーブルの正体と 3 系統、training、DRAM 側状態の順序依存、multi-probe |

## 参照のしかた(質問に答えるとき)

ユーザが上記の概念を尋ねたら:
1. まず該当ファイルを Read して、教材の内容と整合する形で答える
   (教材が source of truth。矛盾する説明をしない)
2. 抽象論だけでなく、教材のスタイルに倣って**実機でやったことに紐づける**
   (例: 「MDA[1]=0x1 を devmem で読んだ」「UART4=0x0C だから read が安全だった」)
3. 回答が教材に無い新領域なら、下の「更新」に従って教材へ書き足す

## 更新のしかた(新しい知識が出たとき)= この skill の核

以下のトリガで、**その場で教材を更新**する(後回しにしない):
- ユーザの概念質問に答えて、教材にまだ無い恒久的な知識を説明した
- デバッグ/実験で、後から役立つ低レベルの知見・仕組みが判明した
- 教材の記述に誤り/古い箇所を見つけた

更新ルール:
1. **既存トピックの範囲内**なら該当ファイルに追記(節を足す/表に行を足す)。
   **新しい大きなトピック**なら新しい連番ファイル(例 `05-xxx.md`)を作り、
   `README.md` の目次に 1 行足す。
2. **正確性最優先**。教材なので誤りは害。不確かな点は実機/ソースで裏取り
   してから書く(RM・linux ドライバ・ATF/U-Boot ソース・実機 devmem)。
3. **具体に紐づける**。この製品で実際に触ったアドレス/レジスタ/ファイル/
   コマンドを添えると記憶に残る(教材の既存スタイルに合わせる)。
4. **一時的な話は書かない**。「今日の作業ログ」や会話固有の事情は docs/ 側。
   教材は「なぜそうなるのか」の恒久知識だけ。
5. 更新後、ユーザに「教材の "◯◯" を更新した」と一言添える。

## 住み分け(何をどこに書くか)

- `learning/` = **なぜそうなるのか**の恒久知識(この skill が管理)
- `docs/imx8mm-xpi-bringup/` = **何をどうやったか**の実務記録・pitfalls
- ブランチ `dev/imx8mm-m4-nxp-repro` / `local/nxp-inquiry-*` = 特定案件の成果物

概念の疑問は learning、手順や踏んだ罠は docs、と振り分ける。
