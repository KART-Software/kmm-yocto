---
name: xpi-remote-sdp
description: XPI-iMX8MM を S1 スイッチに触らず(S1=eMMC のまま)遠隔で SDP に落とし、uuu+ums で flash.bin の復旧・更新・検証を行う手順。遠隔で SDP/UUU が必要になったとき、S1 を Serial に切り替えられないときに参照。
---

# S1 を触らず SDP に入る(遠隔 SDP エントリ)

BootROM は「A 面 IVT → SIT → B 面 IVT の順に検証し、全滅なら SDP へ落ちる」。
これを逆手に取り、**意図的に IVT を不正化して電源サイクルすると S1=eMMC の
まま SDP(USB 1fc9:0134)に入れる**。3 パターン実測済み(2026-08-19):

| 壊す対象 | 結果 |
|---|---|
| A IVT + B IVT(各先頭セクタをゼロ化)← **推奨・最単純** | SDP |
| A IVT + SIT の tag(B 正常でも到達不能) | SDP |
| A IVT + SIT の firstSectorNumber を零領域に向ける | SDP |

## 前提(できないケースを先に)

- **既にブリックしている板には使えない**。壊す操作をするためのシェル
  (ssh で入れる稼働中 Linux、または ums)が生きていることが前提。
  完全起動不能 + ssh 死亡なら現地で S1=Serial にするしかない —
  この技は「S1=Serial 保険を掛け忘れて外出した」を救うもの
- ベンチ PC 側: USB OTG ケーブル接続済み・dp100(電源)・uuu・
  `local/recovery/flash.bin-stock`(falcon 版は UUU RAM 起動不可のため必須)

## 手順

```bash
# 1. バックアップ(必須。ホストと /data の両方に置き md5 照合)
ssh root@<board> 'for s in 65 66 4162; do dd if=/dev/mmcblk2 of=/data/sec$s.bin bs=512 skip=$s count=1; done; sync; md5sum /data/sec*.bin'
scp root@<board>:/data/sec\*.bin <workdir>/
# sec66 と sec4162 は d1 xx xx 41 で始まり、sec65 は offset8 に 33 22 11 00 のはず

# 2. A/B 両面の IVT セクタをゼロ化(板は busybox dd — conv= 不可)
ssh root@<board> 'dd if=/dev/zero of=/dev/mmcblk2 bs=512 seek=66 count=1; dd if=/dev/zero of=/dev/mmcblk2 bs=512 seek=4162 count=1; sync'
# 読み戻しで全零を確認 (md5 = bf619eac0cdf3f68d496ea9344137e8b)

# 3. 電源サイクル → SDP 確認(実測: 投入 ~1s で出現)
sudo python3 scripts/dp100.py cycle --off-time 3
lsusb | grep 1fc9:0134

# 4. stock U-Boot を RAM 起動して ums(ベンチスキルの UUU 節と同じ。
#    uboot_catch.py はこのスキルのディレクトリに同梱)
python3 .claude/skills/xpi-remote-sdp/uboot_catch.py /dev/kart-a53-console ums.log 45 "ums 0 mmc 2" &
timeout 60 uuu scripts/kart-boot.uuu
# → /dev/sda が eMMC。ここで flash.bin 更新など目的の作業をする

# 5. 復旧: バックアップを書き戻し → 読み戻し照合 → 電源サイクル
sudo dd if=sec65.bin of=/dev/sda bs=512 seek=65 conv=fsync
sudo dd if=sec66.bin of=/dev/sda bs=512 seek=66 conv=fsync   # 4162 は壊した場合のみ
sudo python3 scripts/dp100.py cycle --off-time 3
# 起動後: kart-uboot-status で ACTIVE_COPY=A と A/B MD5 が実験前と一致すること
```

## 注意

- **やる前に必ずセクタバックアップ**(手順 1)。壊すのは各 512B だが、
  戻せるものが無ければ flash.bin をビルドし直す羽目になる
- **/dev/sda がホストのディスクでないことを毎回確認**:
  `blockdev --getsize64 /dev/sda` = 7818182656(7.3G, MODEL "UMS disk")
- **全書き込みは読み戻し md5 照合**をセットにする(dd の seek ミスが最悪の事故)
- **SIT 単独破壊は SDP に落ちない**。A 正常時 ROM は SIT を読まないので、
  無症状のまま冗長性だけが失われる(壊すなら必ず A とセット)
- **SDP は 1 電源投入 = 1 発勝負**。wedge(HID timeout)したら dp100 cycle
- 壊した状態で放置しない(その間ボードは SDP でしか上がらない)。
  作業完了まで一気にやり切る
- セクタ番号: 65=0x41 SIT / 66=0x42 A 面 IVT / 4162=0x1042 B 面 IVT。
  構造の詳細は `docs/imx8mm-xpi-bringup/09-boot-sequence.md` ① と
  `imx8mm-migration-design.md` の U-Boot A/B 節

## 関連

- 電源・シリアル・uuu の基礎操作: `imx8mm-xpi-bench` スキル
- ROM フォールバック仕様と kart-uboot-* ツール群: `docs/imx8mm-xpi-bringup/04-pitfalls.md` #19
