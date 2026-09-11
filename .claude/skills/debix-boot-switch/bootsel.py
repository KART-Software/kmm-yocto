#!/usr/bin/env python3
"""DEBIX Infinity のブートモード DIP を USB リレーで切り替える。

  bootsel.py status          # 現在のリレー状態とブートモードを表示
  bootsel.py emmc|uuu|sd     # ブートモードを設定して読み戻し確認

リレー (dcttech USBRelay 16c0:05df, hidraw feature report) の 2ch が
DIP S1 の bit2/bit3 に対応する(bit1 は常に 0):

  mode  DIP  relay1 relay2
  uuu   001  OFF    ON
  emmc  010  ON     OFF
  sd    011  ON     ON

DIP はパワーオンリセット時にしか読まれないので、切り替え後は電源サイクル
(scripts/dp100.py cycle)が必要。稼働中の板に対して切り替えても影響しない。

デバイスは udev ルール 99-usbrelay.rules の /dev/usbrelay を優先し、無ければ
/sys/class/hidraw から VID:PID で探す。
"""
import argparse
import fcntl
import glob
import os
import sys
import time

VID_PID = "000016C0:000005DF"
SYMLINK = "/dev/usbrelay"

MODES = {  # mode -> (relay1, relay2)
    "uuu": (False, True),
    "emmc": (True, False),
    "sd": (True, True),
}
DIP = {"uuu": "001", "emmc": "010", "sd": "011"}

CMD_ON, CMD_OFF = 0xFF, 0xFD
REPORT_LEN = 9


def _ioc(direction, typ, nr, size):
    return (direction << 30) | (size << 16) | (ord(typ) << 8) | nr


def HIDIOCSFEATURE(size):
    return _ioc(3, "H", 0x06, size)


def HIDIOCGFEATURE(size):
    return _ioc(3, "H", 0x07, size)


def find_device():
    if os.path.exists(SYMLINK):
        return SYMLINK
    for path in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(os.path.join(path, "device/uevent")) as f:
                if VID_PID in f.read().upper():
                    return "/dev/" + os.path.basename(path)
        except OSError:
            continue
    return None


def get_state(fd):
    """(relay1, relay2) の ON/OFF を返す。byte 8 が状態ビットマスク。"""
    buf = bytearray(REPORT_LEN)
    fcntl.ioctl(fd, HIDIOCGFEATURE(REPORT_LEN), buf, True)
    mask = buf[8]
    return bool(mask & 1), bool(mask & 2)


def set_relay(fd, relay, on):
    buf = bytearray(REPORT_LEN)
    buf[0] = 0x00  # report id
    buf[1] = CMD_ON if on else CMD_OFF
    buf[2] = relay
    fcntl.ioctl(fd, HIDIOCSFEATURE(REPORT_LEN), buf, True)


def decode(state):
    for mode, pattern in MODES.items():
        if pattern == state:
            return mode
    return None


def fmt(state):
    r1, r2 = state
    mode = decode(state)
    label = f"{mode} (DIP {DIP[mode]})" if mode else "(未定義: DIP 000 相当)"
    return f"relay1={'ON ' if r1 else 'OFF'} relay2={'ON ' if r2 else 'OFF'}  -> {label}"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("action", choices=["status", *MODES])
    args = ap.parse_args()

    dev = find_device()
    if not dev:
        sys.exit(f"USBRelay ({VID_PID}) が見つからない")
    try:
        fd = os.open(dev, os.O_RDWR)
    except PermissionError:
        sys.exit(
            f"{dev} を開けない (permission denied)。"
            "99-usbrelay.rules を /etc/udev/rules.d/ に入れているか確認"
        )
    try:
        before = get_state(fd)
        if args.action == "status":
            print(f"{dev}: {fmt(before)}")
            return
        want = MODES[args.action]
        if before == want:
            print(f"already: {fmt(before)}")
            return
        # ON を先に立ててから OFF を落とす(両 OFF の瞬間を作らない)
        for relay, on in sorted(zip((1, 2), want), key=lambda t: not t[1]):
            if (before[relay - 1]) != on:
                set_relay(fd, relay, on)
                time.sleep(0.05)
        after = get_state(fd)
        print(f"before: {fmt(before)}")
        print(f"after:  {fmt(after)}")
        if after != want:
            sys.exit("設定後の読み戻しが一致しない")
        print("DIP はパワーオンでしか読まれない: 反映には電源サイクルが必要")
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
