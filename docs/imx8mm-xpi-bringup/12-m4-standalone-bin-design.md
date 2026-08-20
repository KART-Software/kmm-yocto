# 12 — M4 ファーム分離配布(FIT loadable を使わない)【実装・実機検証済み】

M4 ファーム(m4-fw.bin)を falcon.itb への埋め込みから外し、**boot パーティション
上のただのファイル**にして SPL が独自に読む方式の設計。狙いは
**「Zephyr だけ更新したい人が Yocto に一切関わらない」**こと。

- 現状の実装(FIT loadable 埋め込み + BL31 起動)は [10-cortex-m4.md](10-cortex-m4.md) ④
- **2026-08-21 実装・実機検証済み**(検証結果は §9)。埋め込み方式(10 ④)はこの方式で置き換えた

---

## 1. 目的とユースケース

M4 ファームの入れ替えに現状は kmm-yocto が必須(m4-fw.bin を recipe に
vendored → `bitbake kart-falcon-itb` → falcon.itb 差し替え)。M4 開発者の
ユースケースは 3 つ:

| ユースケース | 現状 | 本設計後 |
|---|---|---|
| ローカルの zephyr.bin を恒久配備 | bin コピー + bitbake(Yocto 必須)| **scp + reboot だけ** |
| リリース版を配備 | recipe の版更新 + bitbake | イメージ同梱の既定ファイル(OTA で配布)|
| M4 を動かさない | kas overlay を外してビルド | ファイルを置かない |

一時的に試すだけなら今も remoteproc(data-logger-zephyr の `scripts/try.sh`)で
Yocto 不要。本設計は**恒久配備**も Yocto 非接触にする。

## 2. 方式の比較

```
【現行】埋め込み
  m4-fw.bin ──(手動コピー)──> meta-kart/.../files/ ──bitbake──> falcon.itb に /incbin/
  SPL: falcon.itb(FIT) をロード → loadable 機構が M4 部分を DDR 0x46000000 へ
  BL31: DDR のベクタ妥当なら TCML へコピー + SRC 解除

【提案】分離ファイル
  /boot/falcon.itb   ← M4 を含まない
  /boot/m4-fw.img   ← ヘッダ付き M4 バイナリ (§6)。scp で差し替え可能
  SPL: falcon.itb ロード後、m4-fw.img を file_fat_read で読み検証 → DDR 0x46000000 へ
  BL31: 無変更(DDR しか見ていないので、置き方が変わっても関知しない)
```

## 3. なぜ FIT loadable 無しで成立するのか(詳細)

一見「用意された仕組みを捨てて自前でやる」ように見えるが、各層の実際の
仕事を分解すると、FIT loadable は**代替容易な薄い層**であることが分かる:

**(a) FIT loadable の実体は「メタデータ付き memcpy」でしかない。**
SPL の FIT ローダが loadable にやることは「FIT 内のデータを、メタデータの
`load = <addr>` が指す番地へコピーする」だけ。ELF 解釈も再配置も検証も
(hash ノードを書かない限り)何もしない。つまり「eMMC 上のバイト列を
DDR の約束の番地に置く」ことが本質で、それは FIT の専売ではない。

**(b) SPL は既に汎用のファイル読み出し能力を持っている。**
falcon 構成の SPL は boot パーティション(FAT)から falcon.itb を
「ファイルとして」読んでいる(`CONFIG_SPL_FS_FAT`)。同じ FAT スタックの
`file_fat_read("m4-fw.img", (void *)addr, 0)` で任意ファイルを任意番地に
置ける。追加のドライバもサブシステムも不要 — 使う関数が 1 つ増えるだけ。

**(c) BL31 は「どうやって置かれたか」に無関心。**
BL31 の M4 起動コード(imx-atf パッチ)は DDR 0x46000000 の内容だけを見る:
先頭 8B のベクタ(SP/PC)が妥当なら TCML へコピーして SRC 解除。
ステージングに置いたのが FIT ローダか file_fat_read かを区別する術も
必要も無い。**SPL↔BL31 間の契約は「0x46000000 に置く」というアドレスだけ**で、
これは FIT とは独立の取り決め。

**(d) FIT が提供していた付加価値は実は 1 つも失われない。**
FIT の一般的な付加価値は ①複数イメージの束ね ②ロード先メタデータ
③hash/署名の器。①は M4 だけなので不要。②は (a) の通り自前で持てば済む。
③は — **重要な事実として、現行の falcon.its は hash ノードを書いていない
= 今も何も検証していない**。つまり分離ファイル化で検証が「失われる」のではなく、
どちらの方式でも検証は別途設計が必要(§6 で新設する。結果として現行より強くなる)。

**(e) リブート残存も既に解決済みのパターン。**
「DDR は warm reboot で消えない」問題(pitfalls #28)への対処と同型:
SPL はファイル読み出しの**前に**ステージング先頭のベクタ領域をゼロ化する。
ファイルが無い/読めない/検証に落ちた場合、ステージングは無効のままなので
BL31 のゲートが M4 起動をスキップする(= M4 なしで普通に起動)。

## 4. 各層の変更量

| 層 | 変更 |
|---|---|
| SPL(u-boot パッチ)| falcon ロード後: ステージングゼロ化 → `file_fat_read` → ヘッダ検証(§6)→ 合格時のみペイロードを 0x46000000 へ。~40 行 |
| BL31(imx-atf)| **無変更**(実証済みのゲート+コピー+SRC のまま)|
| kart-falcon-itb | m4 loadable ノードと vendored bin を削除(§5 の同梱に置換)|
| kart-image / 同梱 | `IMAGE_BOOT_FILES += "m4-fw.img"`。既定版(リリース版)をイメージに焼く |
| data-logger-zephyr | `scripts/install.sh` 新設(ビルド → ヘッダ付与 → scp → /boot 配置 → reboot)|

## 5. 配布・更新フロー

- **イメージビルド時**: 既定の m4-fw.img が boot パーティションに焼かれる
  (両スロット)。**OTA は今まで通りファイルコピーで配る**ので A/B 整合も維持
- **M4 開発者の恒久更新**(Yocto ゼロ):
  ```
  ./west-container.sh build -d build apps/can-gw
  ./scripts/install.sh        # ヘッダ付与 → scp → /boot/m4-fw.img → reboot
  ```
- **仮に試す**: 従来通り `scripts/try.sh`(remoteproc、リブートで戻る)
- **M4 なし**: ファイルを置かない(または削除)だけ

## 6. 整合性検証の設計(hash をどこで見るか)

**hash 検証とは**: ペイロードのダイジェスト(SHA256 等)を配布時に計算して
添付し、ロード時に再計算して一致を確認する仕組み。1 bit でも化けると
ダイジェストが変わるので、書き込み途中の電源断・ストレージ化け・転送欠損を
検出できる。**整合性(壊れていないか)の検証**であり、**真正性(誰が作ったか)
の検証ではない**(それは署名 = HAB の領分。この製品は open なので扱わない)。

### 採用案: 自前ヘッダ付きコンテナ `m4-fw.img`

```
offset 0x00: magic   "K4FW" (4B)     ← ファイル種別 + ステージング残存の無効化にも効く
offset 0x04: size    ペイロード長 (LE32)
offset 0x08: crc32   ペイロードの CRC32 (LE32)
offset 0x0C: version 任意の版数 (LE32、表示用)
offset 0x10: payload = zephyr.bin (先頭がベクタ)
```

- **検証場所は SPL**(BL31 ではなく)。理由: SPL にはコンソール・十分な
  コード余地があり、失敗時に人間へ警告を出せる。BL31 は最小のまま保つ
- SPL: magic/size/crc32 を検査 → 合格ならペイロードを 0x46000000 へ、
  不合格なら**ステージングを無効のまま**にして警告を出す(→ M4 なしで起動、
  Linux は生きるので scp で直せる)
- **CRC32 を選ぶ理由**: 目的が「破損検出」であり敵対者対策ではないから。
  u-boot SPL は CRC32 を既に持っている(env 検証で使用中 = コードサイズ増ゼロ)。
  37KB の CRC32 は < 1ms。SHA256 でも実装可(SPL に lib あり、こちらも ~1ms)だが、
  破損検出能力は実用上 CRC32 で十分
- ヘッダ付与は `install.sh` / リリース CI が自動でやる(数行の python/シェル)

### 副次効果

- 現行の「ベクタが偶然妥当なら走る」という弱いゲートが、magic + CRC の
  強いゲートに置き換わる(**現行 FIT 埋め込み(hash ノード無し)より強くなる**)
- ステージング残存(§3e)も magic 不一致で確実に弾ける

## 7. 失敗モード分析

| 状況 | 挙動 |
|---|---|
| m4-fw.img が無い | SPL がスキップ(警告)→ M4 なしで起動。kmm は can0 待ちになる点に注意 |
| 破損(CRC 不一致)| 同上 + 警告。**壊れたファームは走らない**(現行より安全)|
| scp 途中の電源断 | 書きかけファイルは CRC 不一致 → 上と同じ(安全側)|
| 論理バグ入りファーム | M4 だけ死ぬ(隔離、[#27 の Q&A 参照](10-cortex-m4.md))。**例外: RDC 違反は SoC リセットループ**になり得るので、恒久化前に必ず try.sh で試す運用 |
| ブートループに陥った場合 | falcon.itb と独立なので、もう片スロットへの fallback は起きない。復旧は Linux の起動窓での scp、駄目なら SDP([xpi-remote-sdp](../../.claude/skills/xpi-remote-sdp/SKILL.md) は稼働 Linux が要るので、最悪 S1)|

## 8. 時間コスト

実測ベース(SPL の eMMC 読み ~80–90MB/s):
FAT lookup ~1–2ms + 37KB 読み ~0.5ms + CRC32 < 1ms = **+2〜3ms**。
電源→GUI 約 5s に対し 0.05% で無視できる([10](10-cortex-m4.md) の Q&A で検討済み)。

## 9. 実装と実機検証結果(2026-08-21)

実装物:
- SPL: `0011-imx8mm-kart-spl-m4-file-read.patch`(ゼロ化 → file_fat_read →
  magic/size/CRC32 検証 → ステージング配置。arch/arm/mach-imx/spl.c 末尾)
- `kart-falcon-itb`: m4 loadable 除去、m4-fw.img 生成(ヘッダ付与)+ deploy
- `kas/imx8mm-m4.yml`: SPL/BL31 パッチ + `IMAGE_BOOT_FILES += m4-fw.img`
- data-logger-zephyr: `scripts/install.sh`(ヘッダ付与 → scp → /boot、--reboot)

検証マトリクス(cold boot、コンソール+board 状態で確認):

| テスト | 結果 |
|---|---|
| 正常ファイル | `kart: m4-fw.img staged (37936 bytes)` → BL31 released → attached → can0 UP → kmm active。staged のコスト +10ms(Falcon 引き渡し→staged 実測)|
| ファイル無し(+DDR 残存)| staged/released 行なし = 無言スキップ、`m4=offline`。Linux 正常起動 |
| CRC 破壊(1 バイト反転)| **`kart: m4-fw.img invalid (len=37952) — M4 skipped`**、`m4=offline`。壊れたファームは走らない |
| install.sh 復旧 | ヘッダ付与 → scp → reboot で全 chain 復帰(Yocto ゼロ)|

検証中の教訓: 板上で dd `conv=notrunc` による破壊を試みて busybox に拒否され
「破壊したつもり」になった(pitfalls #24 の既知の罠を再踏襲)。破壊系の
細工はホスト側で作って scp するのが確実。
