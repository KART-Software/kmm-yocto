# 09 — eMMC の中身: boot0/boot1・ハードウェアパーティション・ブートモード

DEBIX (8MP) の起動時間短縮で「ROM の imx-boot ロードが遅い(実測 ~450KB/s
相当)」を追ううちに出てきた基礎: eMMC はただの記憶素子ではなく、
**ブート専用の仕組みを規格として内蔵した小さなストレージ・システム**だという話。

## eMMC = NAND + コントローラ + 規格化された内部区画

eMMC (JEDEC 規格) はチップの中に NAND とコントローラを持ち、内部が
**ハードウェアパーティション**に分かれている。DEBIX の実機ではこう見える:

```
/dev/mmcblk2        user 領域 (32GB)  ← OS も imx-boot も今は全部ここ
/dev/mmcblk2boot0   ブートパーティション 0 (4 MiB)
/dev/mmcblk2boot1   ブートパーティション 1 (4 MiB)
(mmcblk2rpmb)       RPMB = 認証付きリプレイ保護領域 (セキュア用途)
```

重要: これは MBR/GPT のような「ソフトの区画」ではなく**別アドレス空間**。
user 領域を先頭から dd で埋めても boot0/boot1 は無傷 (逆も同じ)。さらに
`/sys/block/mmcblk2boot0/force_ro` = 1 が既定で、書くときだけ
`echo 0 > force_ro` して dd する、という二重の柵がある。

## ブートモード — 「フル初期化なしで先頭から流し込む」規格

普通にカードを読むには CMD0→CMD1→CMD2→CMD3… の識別手続きが要る
(BootROM がやると数百 ms 級)。それとは別に規格には**ブートモード**があり:

1. 電源投入直後、ホストが特別なシーケンスを出すと、eMMC は識別手続きを
   省略して**選択済みブートパーティションの内容を先頭からストリーミング送信**する
2. どれを送るか (boot0 / boot1 / 無効) は ext_csd レジスタの
   **PARTITION_CONFIG (BOOT_PARTITION_ENABLE)** で選ぶ
3. 送信のバス幅・速度は **BOOT_BUS_CONDITIONS** で事前設定 (最大 8bit DDR)

つまり「ブートローダ置き場 + 高速な取り出し口」が SoC 非依存の規格として
標準装備されている。ext_csd は mmc-utils (`mmc bootpart enable`,
`mmc bootbus set`) で Linux から設定できる。

## i.MX での 2 つのブート方式 (kart での対比)

| | user 領域方式 (現行) | boot パーティション方式 (fast boot) |
|---|---|---|
| imx-boot の場所 | user 領域 sector 64 (SD カード互換の配置) | boot0 (+boot1) の先頭 |
| ROM の読み方 | 通常初期化 → CMD17/18 読み (fuse 既定で **8bit SDR 20MHz**) | ブートモードでストリーミング (fuse 指定で最大 8bit DDR) |
| 速度 | 転送自体は既定でも ~20MB/s 級。「~450KB/s 相当」の正体は区間平均で、支配項は転送でなく識別手続き+ROM 固定処理 | 識別手続きをスキップ (+40MHz/DDR 化)。利得の本体は転送でなく手続き分 |
| A/B 冗長化 | 自前 (SIT + A/B コピー + オフセット計算) | **boot0/boot1 がそのまま A/B** (PARTITION_CONFIG 切替) |
| 誤爆耐性 | user 領域なので dd ミスに弱い | 別アドレス空間 + force_ro |
| 壊したときの ROM の落ち先 | セカンダリ (8MP は fuse 既定 +4MB) → SDP | **boot0 が壊れると boot1 へ即フォールバック** (8MP 実測 2026-09-03、ペナルティ ≈0) = 自然な A/B。user 領域へは戻らない |

SD カードに boot0 が無いのは、SD 規格にブートパーティションが存在しないから
(user 領域方式は「SD でも eMMC でも同じ像が使える」互換性が取り柄)。

## ROM は何をきっかけに boot0 を見るのか (判断の 2 段)

1. **どのデバイスか** = SoC 側の入力: BOOT_MODE ピン + eFuse (BOOT_CFG)。
   DEBIX の S1 スイッチがこれ (eMMC か Serial Download か)
2. **eMMC の中のどこか** = eMMC 側の設定: ext_csd の PARTITION_CONFIG
   (BOOT_PARTITION_ENABLE 3bit)。0/7 なら user 領域の固定オフセット
   (8MP は 32KB)、1/2 なら boot0/boot1 の**先頭 (image offset 0)**。
   **スイッチは eMMC の中にあり、ROM はそれを読んで従うだけ** — だから
   フラッシュ配置でなく `mmc bootpart enable` の一発が点火スイッチになる
   (ソフトで可逆)。しかもこれは **fast boot fuse と無関係に normal boot でも
   起きる** — IMX8MPRM Table 6-24 に「ROM は Ext_CSD[179] の
   BOOT_PARTITION_ENABLE を読んで boot パーティションを選ぶ」と明記
   (offset は Table 6-28)

実機の傍証 (DEBIX 2026-09-03): boot0 にはベンダー工場出荷の IVT 付き
ブートローダが丸ごと眠っていた (`d1 00 20 41` で始まる) が、
PARTITION_CONFIG=0x00 のため完全に不参照 — user 領域のうちの imx-boot が
起動している。「書いてあるかどうか」と「読まれるかどうか」は別のレイヤ。

なお読み出し速度はさらに別のレイヤで、**ホスト (ROM) 側の条件は全部 eFuse、
BOOT_BUS_CONDITIONS はカードが自分のブートモード送信に使う自分用設定**。
ROM は BOOT_BUS_CONDITIONS を読まない (RM の System Boot 章に言及なし)。
詳細は後述の Q&A「fuse なしで速度は変えられるか」。

## 用語の解剖 (Q&A から)

**ext_csd** = Extended CSD。eMMC 内蔵コントローラが持つ **512 バイトの
設定・能力レジスタ配列** (byte 単位で意味が固定)。読み CMD8、書き CMD6
(SWITCH)、**カード内不揮発** — 「eMMC 自身が設定を覚えていて ROM は読むだけ」
の構図はこれで成立する。

**PARTITION_CONFIG (byte 179) のビット図**:

```
bit 6     : BOOT_ACK
bits [5:3]: BOOT_PARTITION_ENABLE (0=無効 / 1=boot0 / 2=boot1 / 7=user)
bits [2:0]: PARTITION_ACCESS (起動後の通常アクセス先)
```

**BOOT_BUS_CONDITIONS (byte 177)**: bits[1:0]=バス幅 (x1/x4/x8)、
bits[4:3]=タイミング (互換 SDR / 高速 SDR / DDR)、bit2=リセット後維持。
これは**カードが自分のブートモード送信に使う自分用の設定**で、
**ROM はどのモードでも読まない** (IMX8MPRM の System Boot 章に byte 177 への
言及は皆無)。ホスト側の受信条件は eFuse (0x490[5:4] バス幅 / [3:2] 速度) で
決まるので、fast boot ではカード側 177 とホスト側 fuse を**手で一致させる**
必要がある (ここは規格上のネゴ無し)。普通の読み (CMD17/18) に 177 は
無関係 — normal boot の速度は fuse だけで決まる。

**eFuse** = SoC 内 (i.MX は OCOTP) のワンタイム PROM。電流で焼き切る
不可逆ビット。ブート設定・MAC・セキュアブート鍵ハッシュ (SRK) 等。
**BT_FUSE_SEL** を焼くと BOOT_MODE ピン (S1) を無視して fuse 設定で起動
= 量産向け・後戻り不可。開発ベンチでは焼かない。

**BootROM の実装**: ソースは非公開 (NXP プロプライエタリ、チップ内マスク ROM)。
ただし**挙動はリファレンスマニュアル System Boot 章にフローチャート付きで
公開**されており、工事の一次資料はこれ。ROM バイナリ自体はアドレス空間に
マップされているので U-Boot からダンプは可能。HAB 等は「ROM API」として
呼び出し仕様のみ公開。

**CSD** = ext_csd のご先祖。MMC 初期からの 128bit レジスタ (容量・転送
クラス等のビット詰め)。足りなくなって eMMC では凍結し、拡張分を 512B の
ext_csd へ逃がした。身分証は別途 CID。

**CMD 番号** = MMC プロトコルのコマンド。CMD0=リセット、CMD1=電圧ネゴ
(識別の本体、ループ待ち)、CMD2/3=CID/アドレス割当、**CMD6=SWITCH
(ext_csd の 1 バイト書換)**、**CMD8=SEND_EXT_CSD (512B 読み)**、
CMD17/18/24/25=ブロック読み書き。mmc-utils は ioctl で生 CMD を通している。
罠: SD の CMD8 は別物 (SEND_IF_COND)。

**eFuse の物理**: ポリ/金属橋の溶断、またはアンチヒューズ (酸化膜破壊で
恒久短絡)。どちらも物理破壊なので undo 不能。UUU への影響は fuse 次第:
- BT_FUSE_SEL 系だけなら、S1 で SDP を「選ぶ」ことは不能になるが、
  ブート失敗時の SDP フォールバックは残る (非常口化)
- **SDP/USB 無効化のセキュリティ fuse を焼くと UUU は永久に閉じる**
  (セキュアブート閉域化の最終段。ベンチでは絶対に触らない)

**fast boot fuse が飛ばすもの**: CMD0〜CMD1 電圧ネゴ〜CID/RCA の識別手続き
(数十〜百 ms 級) を丸ごと省略し、電源直後に CMD 線を Low に落として
ブートモード転送で受信する (IMX8MPRM Figure 6-13: fast boot fuse の分岐は
CMD0 より前)。安全網も RM 明記: boot ack 有効なら 50ms・無効なら 1s 待って
データが来なければ **normal MMC として選択済み boot パーティションから
起動し直す** (Table 6-24)。boot ack (0x4A0[0]) だけは fuse でしか
有効化できない (mmc bootbus では代替不可 — NXP 回答)。

**「読めた後のハング」は SDP に戻れない**: ROM のフォールバックは
「イメージをロードできたか」にしか反応せず、ジャンプした瞬間に ROM は退場する。
BT_FUSE_SEL を焼いて S1 の手動非常口を捨てた場合、読めた後のハングの保険は
① WDOG リセット → ROM の永続ビット → **セカンダリ像 (A/B)**、② JTAG (未封印なら)、
③ 電源投入時に eMMC の線を物理妨害して「読めない」状態を作り SDP へ落とす古典技、
の 3 枚だけ。両系が同じバグでハングすると①は無限ループ — fuse 後の世界では
「片系ずつ更新・検証してから複製」の運用が生命線になる。また SPL 極初期の
WDOG 有効化前 (数十 ms) はどの保険も効かない空白地帯として残る。

**fuse の焼き方 (実務)**: 特別な治具は不要で全部ソフト操作。
① U-Boot `fuse read/sense/prog <bank> <word>` (定番。bank/word は RM の
Fusemap 章が唯一の正)、② Linux の nvmem
(`/sys/bus/nvmem/devices/imx-ocotp0/nvmem`、読みは実機確認済み。書きは
オフセット事故が怖いので U-Boot 推奨)、③ UUU から仮 U-Boot に
`fuse prog` を流す (量産プロビジョニングの形)、④ `fuse override` は
シャドウのみの試し書きだが **ROM はリセットで fuse 本体を読み直すため
ブート設定の試験には使えない** (ブート系 fuse は一発本番)。
掟: fuse は 1 を増やす方向にしか変わらない (OR 蓄積) / read→1 ワードだけ
prog→sense 照合→電源サイクル / 同居ビット (SJC/SDP/JTAG 無効化系) を
巻き込まないようマスクを RM で三重確認 / 打つ前に UUU 生存確認。

**fuse なしで速度は変えられるか** → **No。ただし理由は当初の推測と逆だった**
(IMX8MPRM Rev.3 精読 2026-09-03)。normal boot の転送条件は fuse の
shipped 値で決まり、**既定 (0x490[5:4]=00) が既に「8-bit」、速度既定
(0x490[3:2]=00) は 20MHz SDR** — 「fuse なし = x1 で低速」ではなく
「fuse なしでも最初から 8bit で読んでいて、上げ代 (High Speed 40MHz / DDR)
が fuse にしかない」が正しい。ROM は normal boot でも fuse 値に従い自分で
CMD6 を発行してバス幅を切り替える (Figure 6-14)。BOOT_BUS_CONDITIONS は
そもそも ROM が読む対象ではない (前述)。**置き場所 (user 領域 vs boot
パーティション) の違いでも転送速度は変わらない** — 同じ識別手続き+
同じ読み方で、違いは offset (32KB vs 0) とパーティション選択だけ。
8bit/20MHz なら imx-boot 166KB の転送は ~10ms 級なので、ROM 区間 ~0.5s の
支配項は転送でなく**識別手続き+ROM の固定処理**であり、fast boot fuse の
利得もそこ (識別スキップ) が本体 = **上限は百 ms 級**と見るのが妥当。
fuse なしの boot パーティション移行の価値は速度でなく構造
(boot0/boot1 の自然な A/B、dd 事故からの隔離、force_ro)。
i.MX6 にあった BOOT_CFG の GPIO ピンサンプリング (焼かずに ROM 側を
指定する手段) は i.MX8M 系で廃止。8MP のブート設定 fuse は 0x470 (Bank1
Word3: BOOT_MODE/BT_FUSE_SEL) と 0x490/0x4A0 (Bank2 Word1/2: USDHC 構成、
Fusemap Table 6-35)。

## 教訓・落とし穴

- **転送よりも手続きが支配する**。SPL を 1.7KB 削っても電源→SPL は 1ms も
  動かなかった (実測 2026-09-03、LTO が既に不要コードを捨てていた)。
  既定でも 8bit/20MHz で 166KB の転送は ~10ms 級 — 削れる余地があるのは
  識別手続き (fast boot fuse) の方
- **一次資料の shipped value を読む前に「既定は遅いはず」と思い込まない**。
  「fuse なし = x1 低速」という推測は RM の Fusemap で覆った (既定 00=8-bit)
- **フォールバックで走る「他人のブートローダ」は書き換え主体になりうる**。
  DEBIX ではベンダー U-Boot の自己修復ロジックがフォールバック起動の
  ついでに user 領域のプライマリを上書きした (実測 2026-09-03)。
  フォールバック実験は「どこに落ちるか」だけでなく
  「落ち先が何を書くか」まで含めて観測する
- boot パーティション方式へ移るときは**先にフォールバック挙動を実測**する
  (boot0 の像を故意に壊して ROM がどこへ落ちるか)。受け皿が SDP/UUU だけに
  なるなら、UUU 経路の生存確認が着工条件
- RPMB は「見えるけど普通の読み書きはできない」領域。ls で見えても慌てない

## 関連

- 実務側: `docs/imx8mp-debix-bringup/30-boot-time.md` (ROM 区間の実測と撤回記録)、
  `docs/imx8mm-xpi-bringup/06-emmc-flash.md` (eMMC への書き込み実務)
- ブートチェーン全体: [01-arm-boot-and-atf.md](01-arm-boot-and-atf.md)
- SPL 側のロード高速化 (HS400/memmove): [08-uboot-spl-memory.md](08-uboot-spl-memory.md)
