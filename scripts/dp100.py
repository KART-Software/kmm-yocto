#!/usr/bin/env python3
"""dp100.py — ALIENTEK DP100 (USB 電源) を /dev/hidraw 直叩きで制御する。

依存ゼロ (pip 不要)。プロトコルは lessu/open_dp100 のリバースエンジニアリング
結果 (DP100_Protocol.md + Rust 実装 frame.rs/data.rs) を独自に再実装したもの。

用途: kart 実機の電源断/投入の自動化 (コールドブート計測、A/B フォールバック検証)。

フレーム (64B 固定, すべて little-endian):
  [0]=0xFB(送信)/0xFA(受信)  [1]=opcode  [2]=serial(0)  [3]=payload長
  [4..4+len]=payload  [4+len..+2]=CRC16/MODBUS(LE)  残り 0 詰め
Linux hidraw は write() の先頭バイトを report ID と解釈する (非番号レポート
デバイスは 0x00 を前置し、その分は線上に流れない)。

使い方:
  dp100.py ls                      # デバイス検出
  dp100.py info                    # 機種/FW/シリアル
  dp100.py status                  # vin/vout/iout/温度/出力状態
  dp100.py get                     # アクティブプリセットの設定値
  dp100.py on / dp100.py off       # 出力 ON/OFF (他の設定は不変)
  dp100.py set --v 5.1 --i 3.0 [--ovp 5.5] [--ocp 3.5] [--on|--off]
  dp100.py cycle [--off-time 2.0]  # 電源断→投入 (コールドブート用)
"""
import argparse
import glob
import os
import select
import struct
import sys
import time

VID_PID = "2E3C:AF01"

OP_DEVICE_INFO = 0x10
OP_BASIC_INFO = 0x30
OP_BASIC_SET = 0x35

# BasicSet.index の修飾ビット (Rust: update_basic_set)
# 実機検証済み (2026-08、この個体のファームウェア):
#   0x20 = 保存のみ (出力は変わらない)
#   0xA0 = 「保存済み」プリセットを適用 (フレーム内の state/値は保存されない)
# Rust コメントの「0xA0 = 保存して即適用」はこの個体では成立せず、単発送信だと
# 直前の保存値次第で効いたり効かなかったりする。確実な切替は 0x20 → 0xA0 の
# 2 段送信 (apply_set 参照)。
IDX_SAVE = 0x20        # プリセット保存のみ
IDX_APPLY = 0xA0       # 保存済みプリセットを適用
IDX_ACTIVE = 0x80      # 照会: アクティブプリセット

ACTIVE_INDEX_MASK = 0x0F


def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc


def find_devices():
    """VID:PID が一致する hidraw ノードを列挙する。"""
    found = []
    for uevent in sorted(glob.glob("/sys/class/hidraw/hidraw*/device/uevent")):
        try:
            text = open(uevent).read()
        except OSError:
            continue
        # HID_ID=0003:00002E3C:0000AF01 の形式
        for line in text.splitlines():
            if line.startswith("HID_ID=") and VID_PID.split(":")[0] in line and VID_PID.split(":")[1] in line:
                node = "/dev/" + uevent.split("/")[4]
                found.append(node)
    return found


class DP100:
    def __init__(self, path: str):
        self.path = path
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)

    def close(self):
        os.close(self.fd)

    def _txn(self, opcode: int, payload: bytes = b"", timeout: float = 1.0) -> bytes:
        frame = bytearray(64)
        frame[0] = 0xFB
        frame[1] = opcode
        frame[2] = 0x00
        frame[3] = len(payload)
        frame[4:4 + len(payload)] = payload
        crc = crc16_modbus(bytes(frame[:4 + len(payload)]))
        frame[4 + len(payload)] = crc & 0xFF
        frame[5 + len(payload)] = crc >> 8
        # hidraw: 先頭バイトは report ID (非番号レポートなので 0x00)
        os.write(self.fd, b"\x00" + bytes(frame))

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            r, _, _ = select.select([self.fd], [], [], deadline - time.monotonic())
            if not r:
                break
            buf = os.read(self.fd, 64)
            if len(buf) < 6 or buf[0] != 0xFA:
                continue
            if buf[1] != opcode:
                continue  # 別 opcode の遅延応答は読み捨て
            dlen = buf[3]
            if 4 + dlen + 2 > len(buf):
                continue
            expect = crc16_modbus(bytes(buf[:4 + dlen]))
            got = buf[4 + dlen] | (buf[5 + dlen] << 8)
            if expect != got:
                raise IOError(f"CRC mismatch (calc={expect:04x} recv={got:04x})")
            return bytes(buf[4:4 + dlen])
        raise TimeoutError(f"no response for opcode 0x{opcode:02x}")

    # --- 高レベル操作 ---
    def device_info(self):
        d = self._txn(OP_DEVICE_INFO)
        if len(d) < 40:
            raise IOError(f"short device info ({len(d)}B)")
        return {
            "type": d[0:16].split(b"\x00")[0].decode(errors="replace"),
            "hw_ver": struct.unpack_from("<H", d, 16)[0],
            "app_ver": struct.unpack_from("<H", d, 18)[0],
            "boot_ver": struct.unpack_from("<H", d, 20)[0],
            "serial": d[24:36].hex(),
        }

    def basic_info(self):
        d = self._txn(OP_BASIC_INFO)
        if len(d) < 16:
            raise IOError(f"short basic info ({len(d)}B)")
        vin, vout, iout, vo_max, t1 = struct.unpack_from("<HHHHH", d, 0)
        t2 = struct.unpack_from("<h", d, 10)[0]
        dc5v = struct.unpack_from("<H", d, 12)[0]
        return {
            "vin_V": vin / 1000, "vout_V": vout / 1000, "iout_A": iout / 1000,
            "vo_max_V": vo_max / 1000, "temp1_C": t1 / 10, "temp2_C": t2 / 10,
            "dc_5v_V": dc5v / 1000, "out_mode": d[14], "work_st": d[15],
        }

    def get_active_set(self):
        d = self._txn(OP_BASIC_SET, bytes([IDX_ACTIVE]))
        if len(d) < 10:
            raise IOError(f"short basic set ({len(d)}B)")
        return {
            "index": d[0] & ACTIVE_INDEX_MASK,
            "on": bool(d[1]),
            "vo_set_V": struct.unpack_from("<H", d, 2)[0] / 1000,
            "io_set_A": struct.unpack_from("<H", d, 4)[0] / 1000,
            "ovp_set_V": struct.unpack_from("<H", d, 6)[0] / 1000,
            "ocp_set_A": struct.unpack_from("<H", d, 8)[0] / 1000,
        }

    def apply_set(self, on, vo_V=None, io_A=None, ovp_V=None, ocp_A=None):
        cur = self.get_active_set()
        vo = int(round((vo_V if vo_V is not None else cur["vo_set_V"]) * 1000))
        io = int(round((io_A if io_A is not None else cur["io_set_A"]) * 1000))
        ovp = int(round((ovp_V if ovp_V is not None else cur["ovp_set_V"]) * 1000))
        ocp = int(round((ocp_A if ocp_A is not None else cur["ocp_set_A"]) * 1000))
        state = 1 if on else 0
        # 0x20 で保存 → 0xA0 で適用の 2 段送信 (ファイル冒頭の修飾ビット注記参照)。
        # 段間の待ちは必須: 連射すると保存が内部コミットされる前に適用が走り、
        # 旧い保存値が適用されて空振りする (実機で確認)
        for mod in (IDX_SAVE, IDX_APPLY):
            payload = struct.pack("<BBHHHH", mod + cur["index"], state, vo, io, ovp, ocp)
            d = self._txn(OP_BASIC_SET, payload)
            if not d or d[0] != 0x01:
                raise IOError(f"device rejected basic_set mod=0x{mod:02x} "
                              f"(resp={d.hex() if d else 'empty'})")
            time.sleep(0.5)
        return self.get_active_set()


def open_first():
    devs = find_devices()
    if not devs:
        sys.exit("ERROR: DP100 (2e3c:af01) が見つからない。接続とデータ対応ケーブルを確認。\n"
                 "権限エラーの場合: sudo setfacl -m u:$USER:rw /dev/hidrawN")
    return DP100(devs[0])


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ls")
    sub.add_parser("info")
    sub.add_parser("status")
    sub.add_parser("get")
    sub.add_parser("on")
    sub.add_parser("off")
    ps = sub.add_parser("set")
    ps.add_argument("--v", type=float)
    ps.add_argument("--i", type=float)
    ps.add_argument("--ovp", type=float)
    ps.add_argument("--ocp", type=float)
    g = ps.add_mutually_exclusive_group()
    g.add_argument("--on", action="store_true")
    g.add_argument("--off", action="store_true")
    pc = sub.add_parser("cycle")
    pc.add_argument("--off-time", type=float, default=2.0)
    args = p.parse_args()

    if args.cmd == "ls":
        devs = find_devices()
        print("\n".join(devs) if devs else "(なし)")
        return

    dev = open_first()
    try:
        if args.cmd == "info":
            for k, v in dev.device_info().items():
                print(f"{k}={v}")
        elif args.cmd == "status":
            info = dev.basic_info()
            st = dev.get_active_set()
            for k, v in info.items():
                print(f"{k}={v}")
            print(f"output={'ON' if st['on'] else 'OFF'} (set {st['vo_set_V']}V {st['io_set_A']}A)")
        elif args.cmd == "get":
            for k, v in dev.get_active_set().items():
                print(f"{k}={v}")
        elif args.cmd in ("on", "off"):
            st = dev.apply_set(on=(args.cmd == "on"))
            print(f"output={'ON' if st['on'] else 'OFF'}")
        elif args.cmd == "set":
            on = True if args.on else (False if args.off else dev.get_active_set()["on"])
            st = dev.apply_set(on=on, vo_V=args.v, io_A=args.i, ovp_V=args.ovp, ocp_A=args.ocp)
            print(f"output={'ON' if st['on'] else 'OFF'} "
                  f"v={st['vo_set_V']} i={st['io_set_A']} ovp={st['ovp_set_V']} ocp={st['ocp_set_A']}")
        elif args.cmd == "cycle":
            dev.apply_set(on=False)
            print(f"OFF ({args.off_time}s)...")
            time.sleep(args.off_time)
            st = dev.apply_set(on=True)
            print(f"ON (v={st['vo_set_V']} i={st['io_set_A']})")
    finally:
        dev.close()


if __name__ == "__main__":
    main()
