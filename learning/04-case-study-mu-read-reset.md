# ケーススタディ: 「MU read reset」の謎とその解決

この 1 件は、上の 3 つの知識(ATF / RDC / rpmsg)が全部絡む総合問題だった。
デバッグの筋道そのものが教材になるので、時系列で残す。

## 1. 症状

M4 で **CAN(SPI)+ rpmsg を同居**させようとすると、Linux との rpmsg
セッションが張られた瞬間、M4 が GPIO/ECSPI を **read** した所で **SoC 全体が
無言でハードリセット**する。

- A53 コンソールに panic 無し、いきなり U-Boot SPL に飛ぶ
- M4 のフォールトハンドラも走らない
- 再起動後 `SRC_SRSR = 0x1`(`ipp_reset_b` のみ、watchdog ビット無し)

## 2. 切り分けで潰した仮説(全部ハズレ)

「read で落ちて write は平気」という症状に振り回され、多くの仮説を実機で
潰した:

| 仮説 | 検証 | 結果 |
|---|---|---|
| ECSPI2 ハード固有 | soft-SPI(GPIO ビットバン)でも落ちる | ✗ |
| SPI サブシステム固有 | 純 GPIO read だけでも落ちる | ✗ |
| クロック gate | mcore_booted=1、clk_summary で ON 確認 | ✗ |
| 電源(ブラウンアウト) | dp100 で電圧トレース → 平坦 | ✗ |
| 熱 | 56°C 定常でも落ちる | ✗ |
| MPU / メモリ属性 | MPU 無効でも落ちる | ✗ |
| ダブルマスター | spi_imx 完全解放でも落ちる | ✗ |
| RDC PDAP(実行時 devmem で 0x0C) | 落ちる | ✗ ← 実は方向性は正しかった |
| cpuidle 深ステート | 無効化しても落ちる | ✗ |
| watchdog | wdt サービス下で再検証 → 落ちる | ✗ |
| Linux カーネル依存 | vendor kernel(lf-6.6)でも同一再現 | ✗(非依存確定) |
| 起動経路(remoteproc) | ← bootaux 検証は宿題 | 未 |

**write は 100 万回超安全、MU/DDR/SCTR/UART4 の read は安全**、という非対称も判明。

## 3. 決定的な観察

「read で落ちて write は平気」= **未クロック/権限外ペリフェラルの典型症状**。
write は posted(投げっぱなし)なのでエラーにならないが、read は**バス応答を
待つ**ので、応答が返らない/拒否されると**バスエラー → リセット**。

そして重要な非対称: **UART4 の read だけは常に安全**だった。

→ ここで ATF の RDC 設定を実機で読んだら核心が見えた:
```
既定 ATF は M4(domain1)に UART4 しか割り当てていない
    RDC_PDAPn(RDC_PDAP_UART4, D1R | D1W)   ← UART4 だけ
ECSPI2/GPIO は RDC テーブルに無い → M4 read が RDC で弾かれてリセット
```

「UART4 は read OK / GPIO・ECSPI2 は read でリセット」が完全に一致した。

## 4. なぜ devmem で 0x0C を書いても直らなかったか

方向性(RDC に M4 権限を足す)は正しかったが、**やり方が間違っていた**:
- 実行時に Linux から devmem で PDAP を書いても、RDC のタイミング/ロック/
  domain の壁で効かない([02 参照](02-rdc-and-domains.md#4-なぜ-linux-の-devmem-では-rdc-を変えられなかったか))
- **RDC はブート最初期に ATF が確定させるしかない**

## 5. 解決 — ATF の RDC パッチ

`imx8mm_bl31_setup.c` の rdc[] に 3 行追加:
```c
RDC_PDAPn(RDC_PDAP_eCSPI2, D0R | D0W | D1R | D1W),
RDC_PDAPn(RDC_PDAP_GPIO3,  D0R | D0W | D1R | D1W),
RDC_PDAPn(RDC_PDAP_GPIO5,  D0R | D0W | D1R | D1W),
```
= ECSPI2/GPIO3/GPIO5 を**両ドメイン RW(0x0F)**に。

### 検証(brick リスクゼロの技)
eMMC を書かず、**UUU で RAM ブート**して試した:
1. RDC パッチ入り ATF で flash.bin を再ビルド
2. S1=Serial Download + `uuu` で flash.bin を RAM に送って起動
   (eMMC のブートローダは無変更、電源サイクルで元通り)
3. Linux 起動後 `devmem 0x303D058C`(ECSPI2 PDAP)→ **0x0F** を確認
   (= ATF パッチが効いた証拠。既定なら 0xFF)
4. repro(GPIO read + rpmsg セッション)を実行

### 結果
**GPIO read カウンタが数億回増加、リセットせず生存。** 全条件で落ちていた
failing case が初めて生き残った。**真因 = ATF の RDC 設定漏れ、確定。**

## 6. 学び(この一件のエッセンス)

1. **「read で落ちて write は平気」= 権限外/未クロックアクセスを疑え。**
   read はバス応答を待つので、拒否されると顕在化する。
2. **RDC は ATF 領域。実行時に Linux から緩められない。**ブート最初期に
   確定 → ロック。触るなら bl31.bin を再ビルド。
3. **既定の RDC は M4 に最小限(UART4 のみ)しか渡していない。**M4 に
   ペリフェラルを増やすなら ATF の RDC に足すのが正規手順(NXP/Kontron の
   文書通り)。
4. **UUU RAM ブートは「eMMC を汚さず bl31.bin を差し替えて試す」最強の
   実験手段。** S1=Serial + OTG ケーブルさえあれば brick リスクゼロ。
5. デバッグは**症状の物理的意味**(posted write vs response-waiting read)に
   立ち返ると近道だった。40 回近くリセットを繰り返す前に気づけた可能性。

## 7. レイテンシ比較(参考)

RDC 修正前、MU 回避策を検討した時の見積もり:

| 方式 | 片道 典型 | 片道 最悪(深 idle 除く) | アイドル CPU |
|---|---|---|---|
| rpmsg(MU、実測) | ~76µs | ~100µs | ~0(割り込み) |
| GPIO ドアベル(案 A) | ~10–30µs | ~50µs | ~0(割り込み) |
| 1kHz ポーリング | ~500µs | ~1ms | ~0.1–0.5% |

- CAN の実用途(表示・ロギング)では**どれも体感差なし**。M4 が受信時に
  タイムスタンプを打つので、転送遅延はログ精度に影響しない。
- 最悪ケースは A53 の深い idle 復帰(~0.5–1ms)が支配的で、これは方式に
  よらず共通(MU でも GPIO でも被る)。
- 結局 RDC 修正で rpmsg がそのまま使えるようになり、これらは保険になった。

## 8. NXP への報告価値(解決後も残る)

自力で解決したが、報告には価値が残る:
- 質問 2(「必要な RDC 設定を見落としていないか?」)の答えが **YES** だったこと
- **実行時 devmem では直らず、ブート時 ATF が必須**という知見
- SDK に rpmsg + ECSPI/GPIO の複合サンプルが無いこと
（詳細は `m4/repro-mu-read-reset/` と `local/nxp-inquiry-mu-read-reset.md`）
