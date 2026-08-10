# 02 — デバッグ環境の作り方

bring up に使った道具立てと、その理由・ハマりどころ。

## UART: Teensy 4.0 デュアルブリッジ

最初は USB シリアル変換([CH340](00-glossary.md#g-ch340) → 後に [FTDI](00-glossary.md#g-ftdi) 0403:6015)を直結したが、
**A コア(UART2)と M コア(UART4)を同時に見たい**のと、配線の抜き差しで
デバイス名(`ttyUSB0`/`ttyUSB1`)が入れ替わる問題があった。

→ **`tools/teensy-uart-bridge`** を作成。[Teensy 4.0](00-glossary.md#g-teensy-4-0) が 2 本の USB [CDC](00-glossary.md#g-cdc) シリアル
(`/dev/ttyACM0` = A コア、`/dev/ttyACM1` = M コア)として列挙される。
`USB_DUAL_SERIAL` ビルド。詳細は同ディレクトリの README。

利点:
- 1 本の USB で 2 コア分。ボードの電源リセットで切れない(Teensy は PC 側)
- PC で開いたボーレートが CDC line coding 経由でそのまま [UART](00-glossary.md#g-uart) に反映
- LED がデータ通過中に点灯 → PC を見ずに物理層の生死が分かる

配線(3.3V、GND 共通): `pin0(RX1)←A コア TX` / `pin1(TX1)→A コア RX`。

## シリアルデバイスの権限(udev で恒久化)

挿し直すたびに `/dev/ttyACM*` の権限が root:dialout に戻り、毎回
`setfacl` するのは無駄。**[udev](00-glossary.md#g-udev) ルールで恒久化した:**

```
# /etc/udev/rules.d/99-kart-uart.rules
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", MODE="0666"   # FTDI
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", MODE="0666"   # CH340
SUBSYSTEM=="tty", ATTRS{idVendor}=="16c0", MODE="0666"   # Teensy
```

適用: `sudo udevadm control --reload && sudo udevadm trigger`。
以後どのアダプタでも権限設定不要。

## UART の全出力をユーザー端末にライブ表示(/dev/pts/15)

ユーザーがボードの反応を自分の目で追えるよう、シリアル操作の**全受信バイトを
`/dev/pts/15` にライブで流す**([[mirror-serial-debug-to-pts15]] の選好)。

`tee /dev/pts/15` はシグナル(exit 144)で落ちることがあったため、
**Python スクリプト内で受信バイトを都度 [pts](00-glossary.md#g-pts) へ直接 write** する方式に統一:

```python
mirror = open("/dev/pts/15", "wb")
def sink(b):
    log.write(b); log.flush()
    mirror.write(b); mirror.flush()   # ライブ表示
```

バックグラウンドキャプチャは別途 `tail -f <log> > /dev/pts/15` でも追従できる。
pts 番号はセッションで変わるので最新の指定に従う。

## UART キャプチャスクリプト(scratchpad)

RPi5 の起動時間計測で作った `uart-capture.py`(ホスト側 monotonic タイムスタンプ
付きで 1 行ずつログ化)を流用。ボーレート違いや無音の切り分けに、各行の
先頭に `[経過秒]` が付くのが効く。

## シリアルからの自動操作(U-Boot コマンド送信)

シリアルは対話端末なので、スクリプトから叩くには **プロンプト同期**が要る。
最初は固定 sleep で送っていたが、[TFTP](00-glossary.md#g-tftp) が遅い(7.8 KiB/s まで落ちることがある)と
コマンドが競合して壊れた。→ **各コマンド後に `u-boot=>` を待ってから次を送る**
方式が正解:

```python
def send(c):
    os.write(fd, (c+"\r\n").encode())
    # u-boot=> が来るまで待つ
    ...
```

`termios` で raw 115200(`CS8|CREAD|CLOCAL`、その他フラグ 0)を明示設定する。
`stty` 任せだと環境で挙動が違うことがある。

## ネットワーク経由(SSH):ベンダ 4.14 は ssh-rsa のみ

ベンダの dropbear(2017.75)はホスト鍵が **ssh-rsa** しか無く、最近の
OpenSSH クライアントは既定で拒否する。回避はコマンドラインオプションで:

```bash
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@192.168.0.16
```

`~/.ssh/config` に足すこともできるが、ユーザーの config は勝手に触らない方針。

**ベンダイメージには `reboot` コマンドが無い**([systemd](00-glossary.md#g-systemd) 237、`which reboot` が空)。
非対話 SSH からの再起動は `systemctl reboot -f` か、確実に落とすなら [sysrq](00-glossary.md#g-sysrq):

```bash
ssh ... root@192.168.0.16 'echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger'
```

## UUU(NXP mfgtools)

`sudo apt install uuu`(Ubuntu universe)。[SDP](00-glossary.md#g-sdp) デバイス(`1fc9:0134`)が
見えるか: `uuu -lsusb`。使い方の詳細と [SPL](00-glossary.md#g-spl) 後段ハンドオフの罠は
[03-boot-flow.md](03-boot-flow.md) と [04-pitfalls.md](04-pitfalls.md)。

## TFTP / NFS(netboot 用)

```bash
sudo apt install -y nfs-kernel-server tftpd-hpa
sudo mkdir -p /srv/tftp /srv/nfs/kart
sudo chown $USER /srv/tftp
echo '/srv/nfs/kart 192.168.0.0/24(rw,no_root_squash,no_subtree_check,insecure)' \
    | sudo tee -a /etc/exports
sudo systemctl restart tftpd-hpa nfs-server
```

- TFTP ルート `/srv/tftp` に `Image` と `imx8mm-xpi-kart.dtb` を置く
- [NFS](00-glossary.md#g-nfs) `/srv/nfs/kart` に [rootfs](00-glossary.md#g-rootfs) を展開: `sudo tar --zstd -xf <rootfs>.tar.zst -C /srv/nfs/kart`
  (所有権・デバイスノード保持のため sudo の tar)
- `no_root_squash` は rootfs として使うので必須

## ベンダ DTB の抽出(暗号化 zip を回避)

ベンダソース zip はパスワード保護で開けない。代わりに `.sdcard` イメージから:

```bash
# 1. boot パーティション(FAT)を dd で抜く
dd if=<vendor>.sdcard of=boot.img bs=512 skip=16384 count=131072

# 2. DTB を carve(FDT マジック d00dfeed を検索、妥当サイズだけ切り出し)
#    → python で d00dfeed を find、totalsize を読んで切り出し

# 3. 逆コンパイル(dtc は kas コンテナ内の native を使う)
kas-container shell kas/imx8mm-dev.yml -c \
  'DTC=/build/tmp/sysroots-components/x86_64/dtc-native/usr/bin/dtc; \
   $DTC -I dtb -O dts -o out.dts in.dtb'
```

**実行中の [DT](00-glossary.md#g-dt)** は `cat /sys/firmware/fdt`([U-Boot](00-glossary.md#g-u-boot) fixup 込みの最終形。
メモリサイズ等の動的修正が入る)を SSH で吸って逆コンパイルするのが最も正確。

## ボード全体のバックアップ(文鎮化保険)

bring up 前に、[eMMC](00-glossary.md#g-emmc) の重要領域を SSH + dd で吸っておく:

```bash
ssh ... root@192.168.0.16 'dd if=/dev/mmcblk2boot0 bs=1M | gzip' > boot0.img.gz  # ブートローダ
ssh ... root@192.168.0.16 'dd if=/dev/mmcblk2p1   bs=1M | gzip' > p1-boot.img.gz # カーネル+DTB
ssh ... root@192.168.0.16 'cat /sys/firmware/fdt'                > running.dtb    # 実行中 DT
```

リモート側 `dd | gzip`、ローカルで受けるだけ(デバイス側に書かない)。
`local/xpi-backup/` に保管。**これがあれば eMMC を壊しても書き戻せる。**
今回は一度も eMMC に書いていないので出番は無かったが、量産プロビジョニングで
ブートローダを差し替える際は必須。
