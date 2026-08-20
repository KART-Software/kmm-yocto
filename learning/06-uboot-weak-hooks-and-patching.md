# 06 — U-Boot の weak フックとパッチの作り方

U-Boot(や Linux カーネル)を fork せずに製品固有の処理を差し込む仕組みと、
Yocto でそのパッチをどう作る・運用するかの話。このリポの実例
(falcon 0001 / m4-fw 0011 / BL31 M4 起動)に全部紐づけてある。

## 1. weak シンボル — 「箱だけ用意されていて中身を差し替えられる」仕組み

C のリンカには「**弱い定義(weak)は、強い定義があればそちらに差し替わる**」
というルールがある。U-Boot 本体はこれを使って拡張点を置いている:

```c
/* common/spl/spl.c (u-boot 本体、無改造のまま) */
__weak void spl_board_prepare_for_boot(void)
{
	/* Nothing to do! */          ← 空のデフォルト = 「ここはあなたが書く場所」
}

board_init_r() {
	...
	spl_board_prepare_for_boot();  ← 呼び出しは最初から存在する
	jump_to_image_no_args(...);    ← SPL の最後の命令
}
```

```c
/* うちのパッチ (arch/arm/mach-imx/spl.c 末尾) — __weak を付けない = 強い定義 */
void spl_board_prepare_for_boot(void)
{
	/* m4-fw.img を FAT から読み、CRC 検証して DDR ステージングへ */
}
```

- **呼び出し側は 1 行も変えない**。同名の強い定義を用意するだけでフックが
  差し替わる — パッチが小さく、upstream 追従も楽
- `board_*` / `spl_board_*` / `arch_*` という名前が「board/mach 層が上書きして
  よい口」の規約。デフォルト実装のコメント(Nothing to do!)が意思表示
- **制約: 強い定義はツリーに 1 つまで**。他の board ファイルが同名を実装して
  いたらリンクエラー。使う前に既存実装が無いか grep で確認する

### このリポで使ったフック

| フック | 呼ばれるタイミング | 使用パッチ |
|---|---|---|
| `spl_start_uboot()` | falcon か proper かの分岐判定 | 0001 (falcon) |
| `spl_perform_fixups()` | FIT ロード直後(イメージ加工用)| 0001 (shim 設置) |
| `spl_board_prepare_for_boot()` | **全経路でジャンプ直前に必ず 1 回** | 0011 (m4-fw.img 読み) |

0011 が `prepare_for_boot` を選んだ理由: falcon/proper どちらの経路でも最後に
必ず通る + 他に誰も実装していなかった(grep で確認済み)。

### フックの探し方

```bash
grep -n "__weak" common/spl/spl.c          # SPL のフック一覧
grep -rn "spl_board_xxx" board/ arch/      # 既存の強い定義が無いか(衝突確認)
grep -n "spl_board_xxx" common/spl/spl.c   # 呼び出し位置 = 実行タイミングの確認
```

「記憶にあるフック名をそのまま信じない。**実在・タイミング・非衝突を
ソースで裏取りしてから使う**」が事故防止の掟(レジスタ値の出典コメントと同じ精神)。

### 対比: フックが無い場合(ATF)

ATF(BL31)には該当タイミングの weak フックが無かったため、BL31 の M4 起動
パッチは `bl31_platform_setup()` の**本体に呼び出しを 1 行足す**改造になった。
フックがあれば追記だけ、無ければ本体改造 — パッチの侵襲度が一段変わる。

## 2. パッチの作り方 — 直書きせず、実ソースを編集して diff させる

パッチファイルの hunk ヘッダ(`@@ -372,3 +372,31 @@`)は行数を厳密に数える
必要があり、手書きは高確率で `malformed patch` を生む(実際 2 回踏んだ)。
**実ソースを編集してツールに diff を作らせる**のが正道。Yocto では 3 通り:

**① devtool(公式・継続メンテ向き)**
```bash
devtool modify u-boot-fslc      # ソースが git 付きで workspace に展開される
# → build/workspace/sources/u-boot-fslc をホストのエディタで普通に編集
git commit -am "..."
devtool build u-boot-fslc       # 試しビルド
devtool finish --force-patch-refresh u-boot-fslc <layer>   # .patch 自動生成
```
kas-container はプロジェクトを bind mount しているので、**編集はホストの
VSCode 等でそのまま**できる(コンテナへのリモート接続は不要)。devtool の
3 コマンドだけコンテナで叩く。

**② 展開済みツリーで git を直接**
```bash
bitbake -c patch u-boot-fslc    # fetch+unpack+既存パッチ適用まで
cd build/tmp/work/.../git && git add -A && git commit -m baseline
# 編集して git diff > 0011-xxx.patch
```
注意: workdir は rm_work で消えるので、パッチをレイヤに保存し忘れると蒸発する。

**③ コピー 2 枚 + diff -u(単発の小パッチ最速)**
```bash
cp git/arch/arm/mach-imx/spl.c /tmp/spl_orig.c
cp git/arch/arm/mach-imx/spl.c /tmp/spl_mod.c   # ← こちらを編集
diff -u /tmp/spl_orig.c /tmp/spl_mod.c \
  | sed -e 's|^--- .*|--- a/arch/arm/mach-imx/spl.c|' \
        -e 's|^+++ .*|+++ b/arch/arm/mach-imx/spl.c|' >> 0011-xxx.patch
```
ヘッダ(From/Subject/`Upstream-Status:`)だけ手書きで前置する。

## 3. Yocto のパッチ適用の掟(踏んだ罠込み)

- **基準は「先行パッチ適用後」のソース**。quilt が SRC_URI 順に当てるので、
  新パッチの文脈行は前のパッチが当たった後の状態と一致していないといけない。
  素の upstream からではなく `bitbake -c patch` 後のツリーから diff を取る
- **同じ関数・近い行を複数パッチで触らない**。行がずれると fuzz になり、
  Yocto の QA(`patch-fuzz`)は fuzz を fatal 扱いで落とす。0011 を board
  spl.c でなく mach 層(arch/arm/mach-imx/spl.c)の末尾に置いたのは、
  board spl.c を 0001(falcon)と 0002(splash)が両方触っていたため
- 作ったら **`bitbake -c patch <recipe>` で適用確認**してからビルドに進む
- `Upstream-Status:` 行が無いと QA 警告(`patch-status`)。製品固有なら
  `Inappropriate [product-specific]` と書く

## 関連

- 実務側: `meta-kart/recipes-bsp-imx/u-boot/files/`(0001/0002/0010/0011)、
  `meta-kart/recipes-bsp-imx/imx-atf/files/`(BL31 M4 起動)
- 設計: [docs/imx8mm-xpi-bringup/12-m4-standalone-bin-design.md](../docs/imx8mm-xpi-bringup/12-m4-standalone-bin-design.md)
- SPL がなぜ TCM に M4 を置けないか: [03](03-m4-coprocessor-rpmsg.md) §「SPL 起動の壁」
