# 07 — eMMC ブートと BootROM の仕様調査(fast boot の採否判断)

起動時間の残り候補「ROM ロード区間の eMMC fast boot 化」の前提調査として、
IMX8MPRM Rev.3(Chapter 6 System Boot / Fusemap。`local/IMX8MPRM.pdf`)を
精読した結果と、それに基づく決定の記録(2026-09-03)。
仕組み側の恒久知識は [learning/09](../../learning/09-emmc-boot-partitions.md)、
着工時の手順は [fastboot-runbook.md](fastboot-runbook.md) にある。

## 決定: fast boot fuse は「最後の爆弾」として保留

- **fuse は焼かない**(fast boot 0x490[6]・speed 0x490[3:2]・
  boot ack 0x4A0[0] のいずれも)。理由:
  1. 不可逆(OCOTP は OR 蓄積・undo 不能)のわりに、**利得の上限が百 ms 級**
     (下記の見積り)
  2. ベンチ機はブートローダ実験を繰り返す運用で、ブート系 fuse は
     `fuse override` で試せない一発本番(ROM はリセットで fuse 本体を読み直す)
- **fuse なしの boot0 移行(partconf のみ)も起動時間目的では実施しない**。
  RM の仕様上、速度が 1ms も変わらないため(下記)。boot0/boot1 を
  bootloader A/B に使う構造化は、将来 OTA 設計を見直すときの別判断
- 再検討のトリガ: 量産プロビジョニング設計を固めるとき
  (焼くなら fast boot + speed のみ。SDP/JTAG 無効系は絶対に巻き込まない)

## 調査で確定した BootROM の仕様(IMX8MPRM Rev.3)

### boot パーティションの選択は fuse と無関係(normal boot でも起きる)

- ROM は **normal boot 中に Ext_CSD[179](PARTITION_CONFIG)の
  BOOT_PARTITION_ENABLE を読んで**ブートパーティションを選ぶ(Table 6-24)。
  指定なし/user 指定なら user 領域。つまり `mmc partconf` だけで
  boot0 起動に切り替わり、fuse は一切不要・ソフトで可逆
- image offset は **boot パーティション = 0、user 領域 = 32KB**(Table 6-28)。
  boot0 に置くなら imx-boot を先頭(seek=0)に書く

### 転送条件はホスト(ROM)側が fuse、しかも既定が既に 8bit

- normal boot の転送条件は fuse で決まり、**shipped 既定(全ビット 0)が
  「8-bit SDR・20MHz」**(Table 6-22/6-35: 0x490[5:4]=00 が 8-bit、
  0x490[3:2]=00 が Normal=20MHz)。ROM は初期化後に自分で CMD6 を発行して
  バス幅を切り替える(Figure 6-14)
- 「fuse なし = x1 低速」という事前の想定は**誤り**だった。上げ代は
  High Speed(40MHz、0x490[3:2]=01)と DDR(0x490[5:4]=10)のみで、
  どちらも fuse でしか指定できない
- **BOOT_BUS_CONDITIONS(Ext_CSD[177])を ROM はどのモードでも読まない**
  (System Boot 章に言及なし)。あれはカードが自分のブートモード送信に使う
  カード側設定。fast boot ではホスト fuse とカード側 177 にネゴが無いので
  手で一致させる必要がある(ズレると boot-mode 失敗 → 1s 待ちの
  フォールバックで逆に遅くなる)

### fast boot fuse(0x490[6])が買うもの

- 分岐は **CMD0 より前**(Figure 6-13)。識別手続き
  (CMD0→CMD1 電圧ネゴループ→CID/RCA→CMD8)を丸ごと省略し、電源直後に
  CMD 線を Low に落としてカードのストリーミング送信を受ける。
  幸福経路では ROM は ext_csd を一切読まない
- 失敗時の安全網は RM 明記(Table 6-24): boot ack 有効なら 50ms・無効なら
  1s 待ち、データが来なければ **normal MMC として選択済み boot
  パーティションから起動し直す**
- boot ack だけは fuse(0x4A0[0])でしか有効化できない
  (`mmc bootbus`/`partconf` で代替不可 — NXP 回答)
- 周波数は fast boot 分岐でも speed fuse を見て 20/40MHz を選ぶ。
  40MHz/DDR が欲しければ fast boot とは別に speed/bus width fuse も焼く

### 利得の見積り(下方修正)

- 既定でも 8bit/20MHz なので imx-boot 166KB の転送は **~10ms 級**。
  電源→SPL バナー実測 1.37s(dp100 遅延込み)のうち ROM 区間 ~0.6s の
  支配項は転送でなく**識別手続き+ROM の固定処理**
- fast boot で買えるのは識別手続きスキップ分 = **数十〜百 ms 級が上限**。
  40MHz/DDR 化の転送分は数 ms で誤差。以前の見込み(-0.2〜0.4s 級)は過大

### セカンダリイメージとフォールバック

- セカンダリは「boot device 先頭 + IMG_CNTN_SET1_OFFSET(0x490[22:19]、
  既定 n=0 → **4MB**)」。fast boot はプライマリ専用で、セカンダリへの
  フォールバックは normal モードで行われる(NXP コミュニティ回答)
- boot パーティション選択時に「4MB」が boot0 内を指すのか user 領域かは
  RM に明記なし(着工するなら Phase 1 の壊し実験で実測 — ランブック参照)

### 関係する fuse の所在(Fusemap Table 6-35)

| fuse | bank/word(U-Boot `fuse` 用) | 内容 |
|---|---|---|
| 0x470[15:12] | 1/3 | BOOT_MODE_FUSES(ブートデバイス選択) |
| 0x470[28] | 1/3 | BT_FUSE_SEL(ピン無視で fuse 起動) |
| 0x490[3:2] | 2/1 | speed(00=20MHz / 01=40MHz) |
| 0x490[5:4] | 2/1 | bus width(**00=8-bit** / 10=8-bit DDR) |
| 0x490[6] | 2/1 | fast boot enable |
| 0x490[22:19] | 2/1 | セカンダリイメージ offset |
| 0x4A0[0] | 2/2 | fast boot ack enable |

## 実測(2026-09-03、fuse なし・可逆範囲のみ)

RM の主張のうちソフトだけで検証できる部分を実機で確認した:

- **boot0 起動は fuse なしで成立**: 現行 imx-boot(flash_evk、md5 870b01ab)を
  boot0 の先頭(offset 0)へ dd → `mmc bootpart enable 1 0`
  (PARTITION_CONFIG=0x08)→ 電源サイクルで正常起動
- **出所の証明**: boot0 側だけ SPL バナー文字列を 1 バイト改変(`+p0`→`+B0`。
  HAB open なので ROM は改変を検証しない)→ 実ブートのバナーに `+B0` が出た
  = ROM が boot0 から SPL をロードした確証。なお SPL 以降(u-boot.itb /
  falcon.itb / env)は SPL が user 領域の絶対セクタから読むため経路不変 —
  変わるのは ROM→SPL のロード元だけ
- **速度は完全に ±0**(RM の予言どおり): 電源 ON コマンド発行→SPL バナーの
  epoch 差で、user 領域 = 0.351/0.355s、boot0 = 0.365/0.360/0.332s
  (mean 0.353 vs 0.352、σ数 ms)。
  ※この計測アンカーは「dp100 on 発行時刻」基準の差分比較専用で、
  30-boot-time.md の「電源→SPL 1.37s(dp100 遅延込み)」とは物差しが別
- **原状復帰済み**: PARTITION_CONFIG=0x00、boot0 はベンダー内容を復元
  (md5 6126e9e2... = バックアップと一致)、復帰後の通常起動も確認
- フォールバック実測も同日実施 → 次節

## フォールバック実測: 壊れた boot0 の落ち先 = boot1(2026-09-03)

方法: SPL バナー文字列の 1 バイト刻印で 4 つの置き場所を識別可能にした
(user 32K=`+p0` / user 4MB=`+S0` / boot0=`+B0` / boot1=`+10`)うえで、
boot0 の先頭 4KB をゼロ化し PARTITION_CONFIG=boot0 のまま電源サイクル。

- **落ち先は boot1**(`+10` バナーで確定)。**切替ペナルティ ≈0**
  (電源→バナー 0.331s = 正常時と同水準。boot ack なし設定でも 1s 待ちは
  観測されず即切替)
- user 領域 4MB に置いたセカンダリ(S 刻印)は**使われなかった** —
  boot パーティション選択時、IMG_CNTN_SET1_OFFSET(既定 4MB)の基準は
  user 領域ではない。boot0 が丁度 4MiB なので「boot 領域連続アドレスの
  +4MB = boot1 先頭」なのか「専用の boot1 フォールバック」なのかは
  fuse を変えない限り区別不能(どちらでも実用上は同じ)
- → **boot0/boot1 は fuse なしで ROM レベル自動フェイルオーバー付きの
  bootloader A/B になる**(採用時の注意は下の事故記録)

### 事故記録: ベンダー U-Boot の自己修復がプライマリを上書き

1 回目のフォールバック(boot1 がベンダー内容のままの時)ではベンダー
SPL 2021.04 → ベンダー proper(env CRC 不一致で default env)→ p1 経由で
うちの kernel、という混成チェーンで起動した。このセッションの後、
**user 32K のプライマリが user 4MB のセカンダリ内容で上書きされていた**
(md5 で確認。p1 に boot.scr 等の外部スクリプトは無く、default env の
`sr_ir_v2_cmd` による組込みロジックと推定)。正規バイナリの書き戻しで
復旧済み。

**現在のレイアウトに潜む時限性**: 実験と無関係に、今の構成でも
「user 32K が壊れる → ROM がセカンダリ(4MB のベンダー遺物)を起動 →
ベンダー自己修復が 4MB を 32K へコピー → 以後ずっとベンダーブートローダで
起動」という経路が存在する。boot パーティション A/B 化・4MB スロットの
自前化を設計するときは、**ベンダー遺物(boot0/boot1・user 4MB)の追放が
前提条件**。

原状復帰の最終状態(全 md5 照合済み): PARTITION_CONFIG=0x00、
boot0/boot1=ベンダー内容、user 4MB=ベンダーセカンダリ、user 32K=正規
imx-boot(870b01ab)、最終ブート `+p0`・GUI まで正常。

## 出典

- IMX8MPRM Rev.3 08/2024(`local/IMX8MPRM.pdf`)Chapter 6:
  Table 6-8(BOOT_MODE)、6-22(USDHC boot eFUSE)、6-24(MMC/eMMC boot)、
  6-28(image offset)、6-35(Fusemap Descriptions)、Figure 6-13/6-14
  (Expansion device boot flow)
- [i.MX 8M Mini eMMC Boot Fusing(NXP Community)](https://community.nxp.com/t5/i-MX-Processors/i-MX-8M-Mini-eMMC-Boot-Fusing/td-p/1025730)
  — boot ack は fuse のみ、fuse 値の実例
- [i.MX 8M Mini eMMC Fast Boot BOOT_CFG[7] Fuse And Redundant Boot(NXP Community)](https://community.nxp.com/t5/i-MX-Processors/i-MX-8M-Mini-eMMC-Fast-Boot-BOOT-CFG-7-Fuse-And-Redundant-Boot/td-p/1252024)
  — fast boot はプライマリ専用・セカンダリは normal フォールバック
