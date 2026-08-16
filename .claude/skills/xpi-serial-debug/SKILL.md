---
name: xpi-serial-debug
description: XPI-iMX8MM の実機シリアル(A53 コンソール / Cortex-M4 UART / CANable)へアクセスするときの規約。どのポートがどれか迷わないよう udev の安定名を使う。M4 remoteproc のデバッグ手順も含む。
---

# XPI-iMX8MM シリアルデバッグ

XPI 実機には USB シリアルが複数ぶら下がっており、`/dev/ttyACM*` は接続順で
番号が入れ替わる。**生の `/dev/ttyACM*` には触らない。必ず udev の安定名を使う。**

## 安定名 (udev by-id 相当)

`99-kart-serial.rules`(このディレクトリ)を入れると固定名が生える:

| 安定名 | 中身 | 用途 |
|---|---|---|
| `/dev/kart-a53-console` | Teensy if00 → ttymxc1 (UART2) | A53/Linux + U-Boot コンソール。ブートログ・カーネル panic・fallback が見える |
| `/dev/kart-m4-uart` | Teensy if02 → UART4 (J64) | Cortex-M4 の printk 出力 |
| `/dev/kart-canable` | CANable2 (16d0:117e) | ホスト側 CAN。`slcand … /dev/kart-canable hcan0` |

Teensy は 1 個の USB で 2 ポート出す "Dual Serial"。ポートの区別は
**USB インターフェース番号**(if00 / if02、firmware 固定)で行うので、
番号の入れ替わりに影響されない。

### インストール

```bash
sudo cp .claude/skills/xpi-serial-debug/99-kart-serial.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=tty
ls -l /dev/kart-*        # 確認
```

USB を挿し直したり別の Teensy/CANable に替えたら `vid:pid` と
`bInterfaceNumber` を `udevadm info -a -n /dev/ttyACMx` で確認し、
ルールを更新する。

## キャプチャ手順

コンソール/UART は 115200 8N1。**ボードのリセットに影響されない**ので、
M4 起動系のデバッグでは開始前からキャプチャを回しておくと、
ハードリセットで飛ぶ前の出力まで確実に残る。

```bash
# A53 コンソール(panic / fallback の確認に必須)
stty -F /dev/kart-a53-console 115200 raw -echo
setsid nohup cat /dev/kart-a53-console > a53.log 2>/dev/null < /dev/null &

# M4 UART(M4 firmware の printk)
stty -F /dev/kart-m4-uart 115200 raw -echo
setsid nohup cat /dev/kart-m4-uart > m4.log 2>/dev/null < /dev/null &
```

注意: Zephyr アプリで `CONFIG_SHELL_BACKEND_RPMSG=y` だとコンソールが
rpmsg 側に向き UART4 に何も出ない。M4 UART で見たいときは
UART コンソールを残す構成にする。

## M4 remoteproc デバッグの勘所

- 起動: `echo <fw>.elf > /sys/class/remoteproc/remoteproc0/firmware; echo start > …/state`
  ファームは必ず `/lib/firmware/` に置く(path パラメータ + fallback wait は
  kernfs を wedge させる既往あり)。
- **`echo start` / `echo stop` を timeout で kill しない。** 途中で殺すと
  kernfs が wedge して `reboot -f` でしか戻らない。刺さっても待つか、
  別 SSH セッションで観測する(`echo start` は backgrounded で回すと安全)。
- 停止は NS destroy に ~15s×チャネル。気長に。
- M4 起因の AXI バスロックは **A53 ごとハードリセット**する(コンソールに
  panic を出さずいきなり U-Boot SPL に飛ぶ)。この切り分けには
  A53 コンソールのキャプチャが要る。
- ダブルマスター注意: `mcp251x` の子だけ unbind しても `spi_imx` は
  30830000.spi に残る。M4 が ECSPI2 を専有する構成では、コントローラ側の
  所有と RDC 割り当てまで確認する。

詳細な背景は `docs/imx8mm-xpi-bringup/10-cortex-m4.md` と
`docs/imx8mm-xpi-bringup/04-pitfalls.md`(#24 SIP 起動 / #25 CCGR ドメイン)。
