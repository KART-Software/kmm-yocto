# 起動時間分析

2026-08-07 時点の計測結果。**電源投入 → GUI 表示 = 8.56 秒**。

最適化の経緯と個別施策の検証記録は [boot-optimization-research.md](boot-optimization-research.md) を参照。
本ドキュメントは現行構成の実測サマリ。

## 環境

- Raspberry Pi 5 / NVMe (UMIS RPETJ256MMQ1MDQ, M.2 HAT 経由) / HDMI 接続
- Yocto scarthgap, `kas/rpi5-prod.yml:kas/boot-nvme.yml`（A/B レイアウト）
- C++/Qt6 Widgets アプリ (`kmm.service`, `Type=notify`)
- カーネル 16.1MB (`slim.cfg` + `slim-aggressive.cfg` + `slim-modular.cfg` 適用済み)

## 計測方法

| 対象 | 方法 |
|------|------|
| ファームウェア段 | UART キャプチャ (115200, `console=ttyAMA10`)。ブートローダが出力する `Starting OS NNNN ms` を採取。カウンタは電源投入時起点 |
| カーネル / userspace | `systemctl show -p UserspaceTimestampMonotonic`、`systemctl show kmm.service -p ActiveEnterTimestampMonotonic` |

`kmm.service` は `Type=notify` で**初回ウィンドウ表示時に READY を返す**ため、
`ActiveEnterTimestamp` = 画面にピクセルが出た時刻そのもの。

## 全体（電源 → GUI 表示）

| 段階 | 平均 | σ | n |
|------|------|-----|---|
| ファームウェア（電源 → Starting OS） | **6970ms** | 16.0 | 6 |
| カーネル | **702ms** | — | 4 |
| userspace → GUI 表示 | **891ms** | — | 4 |
| **合計** | **8563ms (8.56s)** | 合成 ≈35ms | |

カーネル Image は 16.1MB（slim-modular 適用後）。ファーム段の読込セグメントは
466ms（旧 17.4MB で 498ms）。

ファームウェアが全体の **81.5%** を占める。

## ファームウェア段の内訳（11 ブート平均・slim-modular 適用前）

> 下表は 2026-08-04 の 17.4MB カーネルでの計測。slim-modular (-1.25MB) 適用後は
> カーネル読込が 498→466ms になった以外、各区間に変化はない。

| 区間 | 所要 | σ | 内容 |
|------|------|-----|------|
| 電源 → 最初の UART 出力 | 1645ms | 2 | EEPROM ロード（UART 出力前のため中身は不可視） |
| BOOTSYS → SDRAM 初期化開始 | 162ms | 2 | RP1 chip ID、PMIC、uSD 電圧 |
| **SDRAM トレーニング** | **1830ms** | **14** | `rank 2 total-size: 64 Gbit 4267` |
| OTP → RP1 ファームロード | 668ms | 2 | `RP1_BOOT: fw size 46888` |
| RP1 → PCI2 init | 632ms | 2 | |
| PCI2 → BOOTLOADER 段 | 57ms | 2 | |
| BOOTLOADER → NVMe 認識 | 215ms | 3 | `VID 0x1cc4 MN UMIS RPETJ256MMQ1MDQ` |
| NVMe → config.txt 読取 | 67ms | 2 | autoboot.txt → `boot_partition=2` へ直行 |
| config.txt → カーネル読込開始 | 1113ms | 2 | DTB + overlay (vc4-kms-v3d-pi5, mcp2515-can0) + EDID 読取 |
| **カーネル読込** | **498ms** | 2 | `kernel_2712.img` 17,377,792 バイト |
| 後処理 → Starting OS | 113ms | 3 | PCI reset、USB-OTG 切断 |

**変動源は SDRAM トレーニング段のみ**（σ 14ms）。他の全区間は σ 2〜3ms で完全に決定論的。

## userspace の内訳

```
kmm.service +97ms
└─weston.service @531ms +203ms
  └─basic.target @485ms
```

weston 完了が userspace 開始から約 734ms、kmm の READY が約 886ms。

> **`systemd-analyze` の総時間（約 9.4s）は GUI 到達時間ではない。** `multi-user.target` 到達までを指し、
> その大半は `systemd-networkd-wait-online`（5.6〜7.9s、eth0 の PHY オートネゴ + DHCP 待ち）。
> `kmm.service` は `network-online.target` に依存しないため GUI 表示は影響を受けない。
> 影響するのは `tailscaled.service`（`After=network-online.target`）で、
> リブート後 tailnet に復帰するまで 6〜8 秒余計にかかる。

## コールドブート vs ウォームリブート — 有意差なし

| | n | 平均 | σ | 幅 |
|---|---|------|-----|-----|
| コールドブート（電源断からの投入） | 6 | 7003.2ms | 15.1 | 52ms |
| ウォームリブート（`reboot`） | 5 | 6997.4ms | 13.2 | 34ms |

差は 5.8ms で各々の σ より小さく、区別がつかない。SDRAM トレーニング段も
コールド 1832ms / ウォーム 1827ms でほぼ同一（ウォームでトレーニングが短縮される、
ということはない）。

> ⚠️ **research ログ §14 の「ファーム段には ±0.3s の自然変動がある」という記述は、
> 現行構成では再現しない。** 11 ブートで幅 57ms（σ 14.6ms）。詳細は
> [research ログ §15](boot-optimization-research.md) を参照。

## 経緯

| 時期 | 電源→GUI | 主な変更 |
|------|---------|---------|
| 2026-04 | 12s | 初期状態（SD + PyQt6） |
| 2026-04-17 | 9.5s | `ExecStartPre=/bin/sleep 2` 削除、weston 依存を `Requires=` 化（SD 実測） |
| 2026-07 | 10.5s | NVMe 化 + 各種 systemd 最適化後の再計測（PyQt6 の import 1.6s が律速） |
| 2026-07-27 | 9.6s | カーネルスリム化（Image 27.5MB → 17.4MB） |
| 2026-07-28 | 8.65s | C++ 版アプリ + PID1 mountinfo レートリミッタ修正 |
| 2026-08-04 | 8.59s | EEPROM 残骸掃除後の全段実測（UART + systemd、11 ブート） |
| **2026-08-07** | **8.56s** | slim-modular.cfg（=y→=m 移動 + KALLSYMS_ALL/IPv6/swap 削除、Image 17.4→16.1MB） |

## 結論

- ファーム段 7.0 秒は Pi5 のクローズドなブートローダ（VPU 上で動作、署名検証あり、置換不可）の
  制約による床。設定レベルの削減は枯渇済み
- OS 側の寄与は 1.59 秒（カーネル 0.70s + userspace 0.89s）で、揺れは σ 24ms
- **起動時間はほぼ完全に決定論的**。全 11 ブートで幅 57ms
- これ以上の劇的短縮は SoC 変更なしには不可能
