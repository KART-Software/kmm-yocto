"""グリッド配置と AprilTag ID <-> (stage, row, column) の変換。

設計書 §3-4:
  800x480 を 10 列 x 6 行 (セル 80x80) に分割、各セル中央にタグ。
  理想タグ中心 = (col*80+40, row*80+40)。
  Stage ごとに ID 帯を変える (family は 36h11 = 587 ID なので 0-359 が収まる)。
"""

DISPLAY_W = 800
DISPLAY_H = 480
GRID_COLS = 10
GRID_ROWS = 6
CELL = 80
NUM_TAGS = GRID_COLS * GRID_ROWS  # 60

DEFAULT_TAG_SIZE = 56  # セル 80 - マージン 12*2

STAGE_BASE = {
    "calibration": 0,
    "bootloader": 100,
    "weston": 200,
    "gui": 300,
}
STAGES = list(STAGE_BASE)


def tag_id(stage: str, row: int, col: int) -> int:
    return STAGE_BASE[stage] + row * GRID_COLS + col


def decode_tag(tid: int):
    """tag_id -> (stage, row, col)。範囲外は None。"""
    for stage, base in STAGE_BASE.items():
        if base <= tid < base + NUM_TAGS:
            idx = tid - base
            return stage, idx // GRID_COLS, idx % GRID_COLS
    return None


def expected_center(row: int, col: int):
    """ディスプレイ座標 (800x480) での理想タグ中心。"""
    return col * CELL + CELL // 2, row * CELL + CELL // 2


def stage_ids(stage: str):
    base = STAGE_BASE[stage]
    return list(range(base, base + NUM_TAGS))
