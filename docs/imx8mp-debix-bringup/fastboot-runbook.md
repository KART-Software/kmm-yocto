# eMMC fast boot 工事ランブック(DEBIX / i.MX8MP)

**方針(2026-09-03)**: fuse は「最後の爆弾」として**保留**が決定
([07-emmc-boot-rom.md](07-emmc-boot-rom.md))。このランブックは
将来着工が決まったときのための手順書として維持する。

**実施記録(2026-09-03)**: Phase 0 と Phase 2 相当は調査として実施済み —
boot0 起動成功(バナー 1 バイト刻印で出所を証明)・速度 ±0・
ベンダー内容まで完全原状復帰済み(詳細は 07-emmc-boot-rom.md の実測節)。
Phase 1(フォールバック実測)も完了: 落ち先 = boot1・ペナルティ ≈0、
ベンダー自己修復の事故と復旧も含め 07-emmc-boot-rom.md に記録。
Phase 3 は「±0 の追認」にしかならないことが RM+実測で確定したので省略。

目的: imx-boot を user 領域 (sector 64) から eMMC boot0/boot1 へ移す。
狙いは ROM 区間の短縮(fast boot fuse 前提)と bootloader の A/B 構造化。

**期待値(2026-09-03、IMX8MPRM Rev.3 精読で確定 — local/IMX8MPRM.pdf)**:

- **fuse なしでも boot0 起動は可能**(Table 6-24: normal boot で ROM が
  Ext_CSD[179] BOOT_PARTITION_ENABLE を読んでパーティションを選ぶ)。
  image offset は **0**(Table 6-28: boot partition=0 / user=32K)
- ただし **fuse なしの速度改善はゼロが RM の予言**: normal boot の転送条件は
  fuse で決まり、shipped 既定が既に **8bit SDR 20MHz**(0x490[5:4]=00 が
  「8-bit」、[3:2]=00 が Normal=20MHz)。BOOT_BUS_CONDITIONS は ROM 不読
  (カードの boot-mode 送信専用)なので、fuse なしの Phase 3 bootbus 変更は
  効かないはず
- fast boot fuse(0x490[6])の利得 = **識別手続きスキップ**(+40MHz/DDR 化)。
  転送は既定でも 166KB ≈ 10ms 級なので**利得上限は百 ms 級**と見る。
  boot ack(0x4A0[0])は fuse でのみ有効化可。boot-mode 失敗時は ROM が
  normal MMC として同じ boot パーティションへフォールバック(Table 6-24。
  ack 有効=50ms 判定 / 無効=1s データ待ち)
- → Phase 1-2(可逆)の主目的は構造価値(boot0/boot1 の A/B 化・dd 隔離)の
  検証と、fast boot fuse を焼く価値の最終判定。不可逆判断(fast boot +
  speed fuse のみ、SDP/JTAG 無効系は絶対不可)は量産判断とセット。
背景知識: [../../learning/09-emmc-boot-partitions.md](../../learning/09-emmc-boot-partitions.md)。
準備状況(2026-09-03 済み):

- mmc-utils: ボード `/data/fastboot-prep/mmc`(動作確認済み)
- バックアップ: ext_csd 生ダンプ + boot0/boot1 の全内容(ベンダー工場出荷の
  ブートローダ遺物入り)を `/data/fastboot-prep/` とホスト
  `local/recovery/fastboot-prep/` の両方に保存(md5 照合済み)
- 現状値: PARTITION_CONFIG=0x00(boot パーティション無効)、
  BOOT_BUS_CONDITIONS=0x00 — ROM は user 領域から起動中

## 着工条件(これを満たすまで書換え禁止)

1. **UUU 経路の生存確認**: S1=Serial で電源投入(※S1 は物理スイッチ =
   ユーザー操作)→ `lsusb | grep 1fc9:0134`。
   直近の ums 実験で USB ガジェットがホストに enumerate されなかった
   未解決があるため、ここが通らない限り着工しない
   (boot パーティションモードで像を壊すと落ち先が SDP 一本の可能性)
2. シリアル(/dev/ttyUSB1)・dp100・カメラ(/dev/kart-debix-cam)が生きていること
3. tftp 復旧経路(/srv/tftp + uboot-break.py)の再確認

## 手順

### Phase 0: 現状再確認(読みのみ)

```bash
M=/data/fastboot-prep/mmc
$M extcsd read /dev/mmcblk2 | grep -iE "PARTITION_CONFIG|BOOT_BUS|boot"
```

### Phase 1: フォールバック挙動の実測(最重要・本番前)

boot0 に**故意に壊れた像**(先頭 4KB をゼロ等)を書き、PARTITION_CONFIG を
boot0 に向けて電源サイクル:

```bash
echo 0 > /sys/block/mmcblk2boot0/force_ro
dd if=/dev/zero of=/dev/mmcblk2boot0 bs=4096 count=1
echo 1 > /sys/block/mmcblk2boot0/force_ro
$M bootpart enable 1 0 /dev/mmcblk2   # boot0 有効 (ack なし版から試す)
# 電源サイクル → シリアル観測
```

- ROM が user 領域へフォールバックして通常起動するか?
- それとも無応答/SDP 落ちか?(lsusb 1fc9:0134 を確認)
- **結果がどちらでも、まず `$M bootpart enable 0 0` で元に戻して**通常起動を
  回復してから次へ(戻し用の一撃: Linux が上がらなければ UUU→U-Boot→
  `mmc partconf 2 0 0 0`)

この結果で「デッドマン圏の内か外か」が確定し、以後の慎重度が決まる。

### Phase 2: 正像で boot0 起動

- 書く像: 現行 imx-boot(flash_evk)。**boot パーティションの image offset は
  0 で確定**(IMX8MPRM Table 6-28: boot partition=0 / user partition=32K)。
  `seek=0` 一択
- 手順:

```bash
echo 0 > /sys/block/mmcblk2boot0/force_ro
dd if=/tmp/imx-boot of=/dev/mmcblk2boot0 bs=512 [seek=0 or 64]
echo 1 > /sys/block/mmcblk2boot0/force_ro
$M bootpart enable 1 0 /dev/mmcblk2
# 電源サイクル → 起動確認 → 電源→banner を epoch 突き合わせで 3 回計測
#   (基準: 1.363〜1.372s。手順は 30-boot-time.md の計測と同じ)
```

### Phase 3: 速度設定

```bash
$M bootbus set dual_backward x8 dual /dev/mmcblk2   # 8bit DDR (カード側設定)
# 各段で電源→banner を計測。boot_ack 有無 (bootpart enable 1 1) も比較
# RM の予言: fuse なしでは全部 ±0 のはず (BOOT_BUS_CONDITIONS は ROM 不読、
# normal boot は fuse 既定の 8bit SDR 20MHz)。±0 の実測確認自体が成果
```

SoC 側の eMMC fast boot 系 eFuse は**不可逆なので今回は触らない**。
ext_csd だけでの改善幅を確定してから、fuse の追加効果は別判断。

### Phase 4: 採否と A/B 再設計

- 効果が -0.2s 未満なら撤回(bootpart disable + boot0 にベンダー遺物を復元)
- 採用なら: boot0/boot1 = imx-boot A/B 化、OTA(ota-update.sh)と
  kart-uboot-\* ツールの改修、SIT/user 領域方式の撤去、docs 更新
  (04-falcon リカバリ節・06-emmc 系・30-boot-time)

## ロールバック(完全に元へ戻す)

```bash
$M bootpart enable 0 0 /dev/mmcblk2          # boot パーティション無効化
echo 0 > /sys/block/mmcblk2boot0/force_ro
dd if=/data/fastboot-prep/boot0-vendor.bin of=/dev/mmcblk2boot0 bs=1M
echo 1 > /sys/block/mmcblk2boot0/force_ro    # boot1 も同様
# ext_csd の他フィールドは触っていないので以上で原状復帰
```

## 未確定事項(2026-09-03 RM 精読後の残り)

1. (解決)boot パーティションの image offset = **0**(RM Table 6-28)
2. (解決 2026-09-03)壊れた boot0 の落ち先 = **boot1**(ペナルティ ≈0、
   user 4MB のセカンダリは使われない)。事故記録(ベンダー U-Boot の
   自己修復がプライマリを上書き)とも 07-emmc-boot-rom.md 参照
3. (解決)fuse なしの速度上限 = 既定の 8bit SDR 20MHz から変わらない
   (BOOT_BUS_CONDITIONS は ROM 不読。Phase 3 は ±0 確認になる見込み)
4. (解決)boot_ack は fuse 0x4A0[0] でのみ有効化可。無効でも ROM は
   1s のデータ待ち後 normal フォールバックするので必須ではない
   (有効なら 50ms で判定が速い)
