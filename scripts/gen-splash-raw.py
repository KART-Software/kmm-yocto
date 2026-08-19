#!/usr/bin/env python3
"""SPL スプラッシュ用ロゴを 1bit マスクの C ヘッダにする (手続き描画版)。

logo/kart_logo.png (純白の線画 + alpha) を、パネル可視域 800x480 の中央に
置く前提で 1bit マスク化し、SPL が #include する C ヘッダ

  meta-kart/recipes-bsp-imx/u-boot/files/kart_splash_logo.h

を生成する。SPL (0002 + 0010 パッチ) は fill 直後・eLCDIF RUN 前に、この
マスクの bit=1 の画素だけ FB に白 (0x00FFFFFF) を書く。bit=0 は触らない
(fill の BG #10141c が残る)。

利点: 生ピクセル (~6MB / 帯 0.8MB) を falcon.itb から運ばず、~6.5KB を SPL
コードに埋め込む → SPL の splash ロードがゼロ。しかも RUN 前描画なので
表示 DMA と競合しない。旧「帯 raw を FIT ロード」方式を置き換える。

ロゴ差し替え時に再実行してコミットする (ビルド環境に Pillow が無いため
ビルド時変換はしない)。

usage: python3 scripts/gen-splash-raw.py [logo.png]
"""
import sys
from pathlib import Path

from PIL import Image

PANEL_W, PANEL_H = 800, 480   # パネルが実際に表示する左上領域
LOGO_W = 560                  # パネル幅の 7 割 (見た目調整)
ALPHA_TH = 128                # alpha>=これ を点灯 (1bit しきい値)

root = Path(__file__).resolve().parent.parent
src = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "logo/kart_logo.png"
dst = root / "meta-kart/recipes-bsp-imx/u-boot/files/kart_splash_logo.h"

logo = Image.open(src).convert("RGBA")
logo = logo.resize((LOGO_W, round(logo.height * LOGO_W / logo.width)),
                   Image.LANCZOS)
w, h = logo.size
x = (PANEL_W - w) // 2
y = (PANEL_H - h) // 2

# alpha しきい値で 1bit 化 → row-major, MSB-first でパック
alpha = list(logo.getchannel("A").get_flattened_data())
packed = bytearray((w * h + 7) // 8)
setbits = 0
for i, a in enumerate(alpha):
    if a >= ALPHA_TH:
        packed[i >> 3] |= 0x80 >> (i & 7)
        setbits += 1

lines = [
    "/* SPL スプラッシュ ロゴ 1bit マスク — scripts/gen-splash-raw.py が生成。",
    " * 手で編集しない。ロゴ差し替えはスクリプト再実行 + コミット。",
    " * row-major, MSB-first。bit=1 の画素だけ SPL が FB に白を書く。 */",
    "#ifndef KART_SPLASH_LOGO_H",
    "#define KART_SPLASH_LOGO_H",
    "",
    f"#define KART_LOGO_W {w}",
    f"#define KART_LOGO_H {h}",
    f"#define KART_LOGO_X {x}\t/* パネル可視域(左上原点)内の X */",
    f"#define KART_LOGO_Y {y}\t/* 同 Y */",
    "",
    f"/* {w}x{h} = {w * h} bit, 点灯 {setbits} ({round(100 * setbits / (w * h))}%), "
    f"{len(packed)} byte */",
    "static const unsigned char kart_logo_bits[] = {",
]
row = "\t"
for j, b in enumerate(packed):
    row += "0x%02x," % b
    if len(row) >= 97:
        lines.append(row)
        row = "\t"
if row.strip():
    lines.append(row)
lines += ["};", "", "#endif /* KART_SPLASH_LOGO_H */", ""]

dst.parent.mkdir(parents=True, exist_ok=True)
dst.write_text("\n".join(lines))
print(f"{dst}")
print(f"  logo {w}x{h} at panel ({x},{y}), 点灯 {setbits} "
      f"({round(100 * setbits / (w * h))}%), {len(packed)} byte packed")
