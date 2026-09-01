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

## デバッグの型

- クラッシュ位置は「リセットまでの時間 × 読み込み速度」で割り出せる
  (0.78s × ~45MB/s ≈ 35MB = ロード完了間際、等)
- proper の U-Boot から同じファイルを `fatload` して切り分ける
  (proper で読めるなら SPL 固有 = 配置・config の問題)
- FIT ロード各段に printf を入れた計装ビルドが最終兵器
  (どの image のロードで死んだかが一発で出る)
