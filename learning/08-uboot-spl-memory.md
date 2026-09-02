# 08 — U-Boot SPL のメモリ管理と FIT ロード

falcon 移植(8MM/8MP)で踏んだ「SPL がメモリをどう使うか」の恒久知識。
実務記録は docs/imx8mp-debix-bringup/04-falcon.md(8MP)と
docs/imx8mm-xpi-bringup/08-falcon.md(8MM)。

## SPL の malloc はシステムコールではない

システムコールは「カーネルへのお願い」だが、SPL の下には OS が無い
(SPL は EL3 のベアメタルで自分が最高権限。01 の特権レベル参照)。
U-Boot の malloc は**自前ヒープアロケータ(dlmalloc 系)のただの関数呼び出し**で、
「ビルド時に決め打ちした領域を先頭から切り分けて貸す」だけ。
プールが尽きれば黙って NULL が返る。カーネルの brk/mmap のような
「OS に追加メモリをもらう」後ろ盾は存在しない。

## ヒープは二段構え(場所は人間がビルド時に決める)

| 段階 | 実体 | 例(i.MX8MP、NXP lf_v2024.04) |
|---|---|---|
| DRAM 初期化前 | simple malloc(free 不能な bump アロケータ、`CONFIG_SPL_SYS_MALLOC_F_LEN`) | OCRAM 内の数十 KB |
| DRAM 初期化後 | 本物の dlmalloc プール(`CONFIG_SPL_SYS_MALLOC` + `SPL_CUSTOM_SYS_MALLOC_ADDR/SIZE`) | 0x42200000 / 512KB |

FAT ドライバのクラスタバッファ、DM のデバイス構造体、env バッファ、
FIT メタデータなどが全部ここから出る。

## FIT ロードのバッファ戦略と「射程」の法則

SPL は FIT のヘッダから `fdt_totalsize`(目次サイズ、実行時にしか分からない)を
読み、その分を malloc して目次全体を保持し、目次を参照しながら各 image を
ロード先へコピーする(external data / mkimage -E の場合。埋め込みだと FIT 全体を
ヒープに載せようとして数十 MB の malloc で即死するので falcon は -E 必須)。

- 目次バッファ: `spl_get_fit_load_buffer()` = malloc → 失敗時は
  `spl_get_load_buffer(0)` = **CONFIG_SYS_LOAD_ADDR にフォールバック**
- weak `board_spl_fit_buffer_addr()` で板ごとに固定可能

**法則: SPL が生かしておくべきバッファ(ヒープ・目次・スタック)は、
これからロードする全ペイロードの範囲外に置く。**
proper だけを読む通常構成は u-boot.itb ~1MB なので defconfig の配置で偶然無事だが、
falcon で 35MB のカーネルを読むと前提が崩れる:

- 8MP defconfig のヒープ 0x42200000 = カーネル 0x40400000 + 30MB 地点
  → Image が 30MB を超えた瞬間、**読み込み処理自身の作業領域(FAT 管理構造)を
  読み込んだデータで破壊**して暴走(8MP Image 35.4MB で実測。8MM は 30MB 未満で
  偶然セーフ — 当時のレシピに「SPL heap と衝突しないこと」と自分で書いていた)
- フォールバック先 CONFIG_SYS_LOAD_ADDR=0x40400000 はカーネルロード先そのもの

対策はどちらも「決定的な配置」: 目次は `board_spl_fit_buffer_addr()` で
0x48000000 固定、ヒープは cfg で 0x4A000000 へ移動(8MP 実値)。

## external data のアラインと「隠れ全長コピー」

spl_fit の external data 読みは「offset を bl_len(DMA アライン時 64B)境界に
丸めて読み、ずれ(overhead)があれば `memcpy(load_ptr, load_ptr+overhead, 全長)`
で補正する」実装になっている。`mkimage -E` は blob を **4B 詰め**で並べるため、
2 個目以降の blob はほぼ必ずこのコピーを踏む。SPL は **dcache 無効**(ARMv8 の
SPL は誰も dcache_enable を呼ばないのがデフォルト。proper は board_r.c が有効化)
なので CPU コピーは ~50MB/s しか出ず、35MB のカーネルで ~0.7s を空費する
(8MP falcon で実測: バスを HS400 の 295MB/s にしてもこれが支配項として残った)。

対策は「blob を 64B の倍数にパディングして offset を常に境界に乗せる」+
「src == dst の memcpy をスキップ」(mainline の後年修正と同型)。
**教訓: 転送が遅い時は『バスの速さ』と『その後の CPU 処理』を分けて測る。**
読み自体の実測(get_timer 挟み)と proper での同一操作の比較で 10 分で切り分く。

## なぜ dcache OFF だと CPU だけ遅いのか(Device メモリの機序)

ARMv8 では dcache を使うには MMU(ページテーブル)で「Normal・キャッシュ可」と
宣言する必要があり、**MMU 無効の間は全メモリが Device メモリ扱い**になる
(周辺レジスタかもしれない前提で、1 アクセスずつ順序厳守・まとめ書き禁止・
先読み禁止で DRAM まで往復)。この結果:

- CPU の memcpy: 本来数 GB/s → **~50MB/s**(8MP A53@1.2GHz 実測)
- **DMA は無関係に速い**(コントローラが CPU を介さず DRAM へ直書き。
  eMMC HS400 で 295MB/s を dcache OFF のまま実測)

よくある誤解: 「DMA したデータはキャッシュに無いのだから、dcache を有効に
しても初回コピーは速くならないのでは?」→ **速くなる**。キャッシュの利得は
再利用(ヒット)だけでなく、**Normal 属性なら CPU がバースト・複数同時ミス・
HW プリフェッチ・書き戻しまとめを許される**こと自体にある。コールドデータの
ストリーム読みでも 64B ライン充填のバースト+先読みで帯域律速(数 GB/s)に
なる。Device 属性は「相手はレジスタかもしれない(読むだけで副作用があり得る)」
という契約なので、DRAM 相手でも 1 アクセス 1 往復の最遅作法を強制される。
なお DMA バッファは CPU が読む前に invalidate が必要(古いラインが残ると
DRAM の新データでなくキャッシュのゴミを読む)— ドライバがやっている。

まとめると、SPL では「バスは速いのに CPU の触る仕事だけ遅い」非対称が生じる。
だから最適化も「CPU 処理を速くする(dcache 有効化 — TI K3 は SPL で
TLB 領域を切って enable_caches() する先例あり)」より先に
「**CPU 処理そのものを消せないか**」を検討する価値がある。

## おまけ: eMMC バスモードの早見

Legacy 26MB/s → HS/DDR52 52/104MB/s → HS200 200MB/s(SDR) →
**HS400 400MB/s(DDR×8bit)** → HS400 **ES**(Enhanced Strobe、チューニング不要)。
高速側は 1.8V 信号・8bit 配線・**専用パッド設定(state_100mhz/200mhz の
pinctrl)**・DT の mmc-hs400-1_8v 等が揃って初めて交渉される。SPL は
`CONFIG_SPL_MMC_HS400(_ES)_SUPPORT` + SPL 用 DT に高速 pinctrl の bootph が
無いと低速モードに黙って留まる(8MP で実測: 既定 ~23MB/s → HS400 ES 295MB/s)。

## デバッグの型

- クラッシュ位置は「リセットまでの時間 × 読み込み速度」で割り出せる
  (0.78s × ~45MB/s ≈ 35MB = ロード完了間際、等)
- proper の U-Boot から同じファイルを `fatload` して切り分ける
  (proper で読めるなら SPL 固有 = 配置・config の問題)
- FIT ロード各段に printf を入れた計装ビルドが最終兵器
  (どの image のロードで死んだかが一発で出る)
