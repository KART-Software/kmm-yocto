"""Stage 判定とタイミング計測 (§19-21)。

各フレームの stage 別タグ数から first / 50% / stable を記録する。
Mixed Stage フレームはそのまま記録する (エラーにしない)。
"""
from dataclasses import dataclass

from . import layout


@dataclass
class TimingConfig:
    stable_ratio: float = 0.9     # Target Stage >= 90%
    stable_frames: int = 3        # 連続フレーム数
    half_count: int = 30          # GUI 50% = 30/60


class StageTimer:
    """feed(ts_ns, counts) を毎フレーム呼ぶ。counts = {stage: tag数}。"""

    def __init__(self, config: TimingConfig = None, t0_ns: int = None):
        self.cfg = config or TimingConfig()
        self.t0 = t0_ns
        self.first = {}
        self.half = {}
        self.stable = {}
        self._streak = {}

    def feed(self, ts_ns: int, counts: dict):
        if self.t0 is None:
            self.t0 = ts_ns
        need_stable = int(layout.NUM_TAGS * self.cfg.stable_ratio)
        for stage in layout.STAGES:
            n = counts.get(stage, 0)
            if n >= 1 and stage not in self.first:
                self.first[stage] = ts_ns
            if n >= self.cfg.half_count and stage not in self.half:
                self.half[stage] = ts_ns
            if n >= need_stable:
                self._streak.setdefault(stage, []).append(ts_ns)
                if (stage not in self.stable and
                        len(self._streak[stage]) >= self.cfg.stable_frames):
                    # stable 時刻は連続区間の先頭フレーム
                    self.stable[stage] = self._streak[stage][0]
            else:
                self._streak[stage] = []

    def rel(self, ts_ns):
        if ts_ns is None or self.t0 is None:
            return None
        return (ts_ns - self.t0) / 1e9

    def dominant_stage(self, counts: dict):
        best = max(counts, key=lambda s: counts.get(s, 0), default=None)
        if best is None or counts.get(best, 0) == 0:
            return "none"
        return best

    def report_lines(self):
        out = []
        for stage in ("bootloader", "weston", "gui"):
            f = self.rel(self.first.get(stage))
            s = self.rel(self.stable.get(stage))
            out.append(f"{stage.capitalize():10s} first : "
                       f"{f:.3f} s" if f is not None else
                       f"{stage.capitalize():10s} first : -")
            if stage == "gui":
                h = self.rel(self.half.get(stage))
                out.append(f"{'GUI':10s} 50%   : "
                           f"{h:.3f} s" if h is not None else
                           f"{'GUI':10s} 50%   : -")
            out.append(f"{stage.capitalize():10s} stable: "
                       f"{s:.3f} s" if s is not None else
                       f"{stage.capitalize():10s} stable: -")
        return out
