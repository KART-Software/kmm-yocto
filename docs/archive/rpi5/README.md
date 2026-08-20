# archive/rpi5 — Raspberry Pi 5 時代のドキュメント

製品ターゲットが Raspberry Pi 5 だった頃の記録。**現行の XPI-iMX8MM には
当てはまらない**(tryboot・NVMe・EEPROM 前提)ため、履歴として退避した。

RPi5 の当時の完全な状態はタグ [`rpi5-final`](https://github.com/KART-Software/kmm-yocto/tree/rpi5-final) を参照。

| ファイル | 内容 | imx8mm での対応 |
|---|---|---|
| [ab-ota.md](ab-ota.md) | A/B (tryboot) OTA の仕組み | `imx8mm-xpi-bringup/08-falcon.md`(A/B 統合)+ ルート README の OTA 節 |
| [boot-timing.md](boot-timing.md) | 起動時間分析(電源→GUI 8.59s) | `imx8mm-xpi-bringup/09-boot-sequence.md` |
| [boot-optimization-research.md](boot-optimization-research.md) | 起動時間最適化の研究ログ | `imx8mm-xpi-bringup/` の perf/pitfalls コミット群 + 09/11 |

移行の設計判断(なぜ SoC を変えたか)は
[../../imx8mm-migration-design.md](../../imx8mm-migration-design.md)。
