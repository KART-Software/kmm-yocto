#!/usr/bin/env python3
# ttyACM0 で U-Boot の autoboot を打鍵で止め "=>" プロンプトを捕まえる。
# 見つけたら 0 で抜ける。ログは logfile へ (ホスト ms 付き)。
import os, sys, termios, time, errno
dev, log, maxsec = sys.argv[1], sys.argv[2], float(sys.argv[3])
# 追加引数: プロンプト到達後に送るコマンド (省略可)
after_cmd = sys.argv[4] if len(sys.argv) > 4 else None
fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK | os.O_NOCTTY)
a = termios.tcgetattr(fd)
a[0] &= ~(termios.IXON|termios.ICRNL|termios.INLCR|termios.IGNCR|termios.ISTRIP|termios.BRKINT)
a[1] &= ~termios.OPOST
a[2] |= termios.CLOCAL|termios.CREAD
a[3] &= ~(termios.ICANON|termios.ECHO|termios.ISIG|termios.IEXTEN)
a[4] = a[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, a)
out = open(log, "wb")
t0 = time.monotonic()
last_key = 0
buf = b""
got_prompt = False
while time.monotonic() - t0 < maxsec:
    now = time.monotonic()
    # autoboot 打鍵 (プロンプト前のみ)
    if not got_prompt and now - last_key > 0.08:
        try:
            os.write(fd, b"\n")
        except OSError:
            pass
        last_key = now
    try:
        d = os.read(fd, 4096)
        if d:
            out.write(d); out.flush()
            buf += d
            if b"=>" in buf or b"u-boot=>" in buf:
                got_prompt = True
                time.sleep(0.3)
                if after_cmd:
                    os.write(fd, after_cmd.encode() + b"\n")
                    # コマンド後の出力を数秒読む
                    te = time.monotonic()
                    while time.monotonic() - te < 4:
                        try:
                            d2 = os.read(fd, 4096)
                            if d2: out.write(d2); out.flush()
                            else: time.sleep(0.02)
                        except OSError as e:
                            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK): time.sleep(0.02)
                            else: break
                else:
                    try:
                        d2 = os.read(fd, 4096)
                        if d2: out.write(d2); out.flush()
                    except OSError:
                        pass
                print("PROMPT")
                sys.exit(0)
            buf = buf[-2048:]
        else:
            time.sleep(0.01)
    except OSError as e:
        if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
            time.sleep(0.01)
        else:
            time.sleep(0.05)
print("NO_PROMPT")
sys.exit(1)
