# 起動時間分析

2026-04-17 時点の計測結果。

## 環境

- Raspberry Pi 5, SD カード (mmcblk0), HDMI 接続
- Yocto scarthgap, `kas/local-dev.yml:kas/boot-sdcard.yml`

## タイムライン (SD カード, 改善後: 9.5秒)

| 時刻 | 所要 | イベント |
|------|------|---------|
| 0s | | 電源ON |
| 3.4s | 3.4s | カーネルブート完了 |
| 5.9s | 2.5s | systemd 基本サービス (udev, fsck, mount 等) |
| 6.3s | 0.4s | seatd 起動 |
| 7.7s | 1.4s | weston 起動開始 (DRM/EGL 初期化) |
| 8.3s | 0.6s | weston ready (systemd-notify) |
| 8.3s | 0s | kart-machine-manager 起動 |
| 9.5s | 1.2s | GUI 表示 (Python + PyQt6 初期化) |

## 実施した改善 (12s → 9.5s)

`kart-machine-manager.service` を変更:

- `Wants=weston.service` → `Requires=weston.service`
  - weston 失敗時にアプリが無駄に起動・クラッシュするのを防止
- `ExecStartPre=/bin/sleep 2` を削除
  - weston 依存が正しく設定されたため不要に → **2.5秒短縮**

## HDMI 未接続時の挙動

HDMI が未接続だと weston が即終了し、kart-machine-manager も `Failed to create wl_display` で SIGABRT する。
`Requires=` により weston 失敗時はアプリが起動しなくなったが、HDMI 接続が前提。

## NVMe SSD での予測 (~6秒)

| 区間 | SD (実測) | NVMe (予測) |
|------|----------|-------------|
| カーネル | 3.4s | ~2.0s |
| systemd 基本 | 2.5s | ~1.5s |
| seatd + weston | 2.0s | ~1.8s |
| Python + PyQt6 | 1.2s | ~0.6s |
| **合計** | **9.5s** | **~6s** |

SD のシーケンシャルリードは約 88 MB/s。NVMe は 800+ MB/s。
特にランダム 4K リード (SD: 1-5 MB/s, NVMe: 50-100 MB/s) が Python import で効く。

## さらなる短縮案

| 施策 | 短縮見込み | コスト |
|------|-----------|--------|
| `.pyc` プリコンパイル | 0.2-0.3s | 低 (レシピに `python3 -m compileall` 追加) |
| `python3 -O` 最適化モード | 微量 | 低 |
| C++/QML 書き換え | 1.2s → 0.2s | 高 (アプリ全面書き換え) |
