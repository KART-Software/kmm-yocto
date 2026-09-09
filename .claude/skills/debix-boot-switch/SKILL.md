---
name: debix-boot-switch
description: DEBIX Infinity (imx8mp) のブートモード DIP (001=UUU / 010=eMMC / 011=SD) を PC の USB リレーから遠隔で切り替える手順。UUU 復旧・SD ブート・eMMC 復帰でブート先を変えたいとき、「DIP を切り替えて」と言われたとき、DIP を手で触りに行く前に必ず参照。
---

# DEBIX ブートモード切替 (USB リレー)

DEBIX の DIP S1 のうち bit2/bit3 が PC の USB リレー (dcttech USBRelay
`16c0:05df`, 2ch) に配線してあり、**ブート先は手を使わず PC から切り替えられる**
(bit1 は常に 0 なので UUU/eMMC/SD の 3 通りだけ)。

| mode | DIP | relay1 | relay2 | 用途 |
|---|---|---|---|---|
| `emmc` | 010 | ON | OFF | 通常運用(A/B スロット、falcon) |
| `uuu` | 001 | OFF | ON | SDPS 復旧 (`local/recovery/debix-recover.uuu`) |
| `sd` | 011 | ON | ON | SD の U-Boot から eMMC 復旧 ([[debix-emmc-recovery-via-uboot]]) |

## 操作

```bash
S=.claude/skills/debix-boot-switch/bootsel.py
python3 $S status      # 現在のリレー状態 → mode
python3 $S emmc        # 3 つのどれかを指定。設定後に読み戻し照合、不一致は非 0 終了
python3 $S uuu
python3 $S sd
```

**DIP はパワーオンリセット時にしか読まれない。** 切り替えただけでは何も起きない
ので、必ず電源サイクルを続ける(稼働中の板に対して切り替えるのは無害):

```bash
python3 $S uuu && sudo python3 scripts/dp100.py cycle --off-time 3
```

**DP100(電源)も同様に udev 化済み** (`99-dp100.rules`、ALIENTEK ATK-MDP100 `2e3c:af01`
→ `/dev/dp100`、plugdev 0660)。これで電源サイクルも sudo 不要:

```bash
python3 $S uuu && python3 scripts/dp100.py cycle --off-time 3   # sudo 不要
```

**エンドツーエンド検証済み (2026-09-09)**: `uuu`+電源投入で board が SDP (`1fc9:0146
NXP SE Blank`) として列挙、`emmc`+電源投入で SDP 消失→eMMC 起動 (0.3A で idle) を確認。
リレーが DIP を確かに駆動している。

作業が終わったら **`emmc` に戻して**から離れる(次回の電源投入で通常起動させるため)。
両 OFF (DIP 000) は未定義なので、`status` がそれを示したら誰かが手で触ったか
リレーが抜けている。

## セットアップ (udev、sudo 不要化)

hidraw は既定で root 専用 (0600)。`99-usbrelay.rules`(このディレクトリ)で
`plugdev` グループ 0660 にし、安定名 `/dev/usbrelay` を張る(2026-09-09 導入済み)。

```bash
sudo cp .claude/skills/debix-boot-switch/99-usbrelay.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=hidraw
ls -l /dev/usbrelay      # -> hidrawN, root:plugdev 0660
```

`bootsel.py` が permission denied を出したらこのルールが入っていない
(または plugdev に居ない)。スクリプトは `/dev/usbrelay` を優先し、無ければ
`/sys/class/hidraw/*/device/uevent` の VID:PID で探すので、hidraw 番号の
入れ替わりは影響しない。

## プロトコルメモ

feature report 9 バイト: `[00, cmd, ch, ...]`、cmd = `0xFF` ON / `0xFD` OFF
(`0xFE`/`0xFC` は全 ON/OFF)。読み出しは `HIDIOCGFEATURE(9)` で byte 1-5 = シリアル、
byte 8 = 状態ビットマスク (bit0 = relay1)。`bootsel.py` は ON を先に立ててから
OFF を落とし、両 OFF の瞬間を作らない。
