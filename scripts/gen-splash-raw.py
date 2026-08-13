#!/usr/bin/env python3
"""SPL スプラッシュ用フレーム生成。

黒埋め広 DE モード (active 1920x792 / raster 2200x818) の全面フレームを作る。
パネルが物理表示するのは左上 800x480 だけなので、その領域に
logo/kart_logo.png を中央配置 (背景 #10141c = weston と同色)、残りは黒。
eLCDIF が読む XRGB8888 (メモリ上 B,G,R,X) の raw を gzip して
meta-kart/recipes-bsp-imx/kart-falcon-itb/files/kart-splash-1920x792.raw.gz
に書く。ロゴ差し替え時に再実行してコミットする (ビルド時変換はしない —
ビルド環境に Pillow が無いため)。

usage: python3 scripts/gen-splash-raw.py [logo.png]
"""
import gzip
import sys
from pathlib import Path

from PIL import Image

W, H = 1920, 792          # DE (eLCDIF active) サイズ
PANEL_W, PANEL_H = 800, 480   # パネルが実際に表示する左上領域
BG = (0x10, 0x14, 0x1C)
LOGO_W = 560  # パネル幅の 7 割。余白はバランス見た目調整
# 旧疎ラスタでは PCR の位相ズレ相殺 (-56) が要ったが、黒埋めラスタは
# 充填率 87% でロックが一意化されるため補正なし。ズレを実測したら要調整
H_COMP = 0

root = Path(__file__).resolve().parent.parent
src = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "logo/kart_logo.png"
dst = root / "meta-kart/recipes-bsp-imx/kart-falcon-itb/files/kart-splash-1920x792.raw.gz"

logo = Image.open(src).convert("RGBA")
logo = logo.resize((LOGO_W, round(logo.height * LOGO_W / logo.width)),
                   Image.LANCZOS)

frame = Image.new("RGB", (W, H), (0, 0, 0))          # 黒埋め (パネル外)
panel = Image.new("RGB", (PANEL_W, PANEL_H), BG)      # 可視領域
panel.paste(logo, ((PANEL_W - logo.width) // 2 + H_COMP,
                   (PANEL_H - logo.height) // 2), logo)
frame.paste(panel, (0, 0))

raw = frame.tobytes("raw", "BGRX")
assert len(raw) == W * H * 4
dst.parent.mkdir(parents=True, exist_ok=True)
# mtime=0 で再実行しても同一バイナリ (git diff を汚さない)
with open(dst, "wb") as f:
    with gzip.GzipFile(fileobj=f, mode="wb", mtime=0) as gz:
        gz.write(raw)
print(f"{dst} ({dst.stat().st_size} bytes, logo {logo.width}x{logo.height})")
