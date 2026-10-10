# 7. ベンチの操作

手順と実測値の詳細は `.claude/skills/` の各スキル(Markdown)にある。

## DEBIX(i.MX8MP)

| 何 | どうする |
|---|---|
| 電源 | DP100(USB 電源)を `scripts/dp100.py` で操作。`on` / `off` / `cycle [--off-time 3]` / `status`。udev で `/dev/dp100` にしてあり sudo 不要 |
| ブートモード | DIP(001 = USB 書き込み、010 = eMMC、011 = SD)を USB リレーで切り替える。`python3 .claude/skills/debix-boot-switch/bootsel.py emmc` / `uuu` / `sd` / `status`。**DIP は電源投入時にしか読まれない**ので、切り替えたら電源を入れ直す。リレーが無ければ基板の DIP を手で |
| シリアル | FTDI FT230X(`/dev/serial/by-id/usb-FTDI_FT230X_*`)、115200 8N1。A53 のコンソール(ttymxc1)で、root に自動ログインする。使うには `dialout` グループが要る |
| 表示の確認 | Web カメラで AprilTag のパターンを撮って判定する(`tools/lcd-validation/`、`lcd-validation` スキル)。輝度や目視では判定しない |
| USB 書き込み | Type-A の DWN_USB1(OTG ができる口)を A-A ケーブルで PC へ。普段 LTE ドングルを挿している口と同じ |
| CAN の模擬 | kart-machine-manager の `can-mock-py` が CANable2 から擬似のマシン CAN を流す(1Mbps) |

- シリアルで `systemctl` を使うと、ページャで止まることがある。先に `export SYSTEMD_PAGER=`
- 機体のシェルは busybox。`head -c` や `timeout` は無い

### よく使う組み合わせ

```bash
S=.claude/skills/debix-boot-switch/bootsel.py
python3 $S uuu  && python3 scripts/dp100.py cycle --off-time 3   # USB 書き込みモードで起動
python3 $S emmc && python3 scripts/dp100.py cycle --off-time 3   # 普段の eMMC 起動に戻す
```

## XPI(i.MX8MM)

- ブートモードは基板の DIP S1(eMMC / Serial Download)で、手で切り替える。触れないときは
  `xpi-remote-sdp` スキル
- シリアルや電源は udev の固定名(`/dev/kart-a53-console` など)。手順は `imx8mm-xpi-bench`
  と `xpi-serial-debug` スキル
- M4 のコンソールは `/dev/kart-m4-uart`(115200)
