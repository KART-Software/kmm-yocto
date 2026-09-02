# 05 — 起動時間の短縮記録(DEBIX / i.MX8MP)

「電源 ON → GUI(kmm READY = 画面表示)」の実測を主指標にした短縮の記録。
1 施策 = 1 行で、効かなかった施策も残す(再挑戦の無駄を防ぐ)。
各施策の技術詳細はリンク先。計測はシリアルのタイムスタンプ
(ts-serial)+ `journalctl -o short-monotonic` の kmm Started。

| # | 日付 | 施策 | 電源→GUI | 差分 | 備考・参照 |
|---|---|---|---|---|---|
| 0 | 08-31 | (移植直後・未最適化) | — | — | systemd-analyze **15.3s**(kernel 4.1 + userspace 11.2)。さらに NXP defconfig の FW user-helper fallback により、見つからない firmware 要求が各 **60s 停止**(EDID cmdline 追加で顕在化、sdma 2 件も該当) |
| 1 | 08-31 | 第 1 弾: FW fallback 無効・quiet(kernel 4.1→1.3s)・udev/hwdb 削減・ユニット間引き・CPU 配分(8MM の道具を imx-generic-bsp へ共通化) | **≈7.0s** | — | SPL 0.6 / U-Boot 1.8 / kernel 1.3 / userspace ~4.2。analyze 11.5s。FW: `meta-kart/recipes-kernel-imx/linux/files/edid-firmware.cfg`、udev/CPU 配分: `meta-kart/recipes-support/kart-udev-slim/`、ユニット間引き: `kart-image.bb` の boot_trim_units。コミット 69773a8 |
| — | 08-31 | weston-early(basic.target を待たない 8MM 変種) | 7.0s | **±20ms = 効果なし、不採用** | 律速は basic 待ちでなく seatd 後の dispatch/exec + weston 初期化 0.8s。経緯コメント: `meta-kart/recipes-graphics/weston/weston-init.bbappend`(weston-early.service)。8MM 側の weston 区間の知見は [../imx8mm-xpi-bringup/11-splash-optimization.md](../imx8mm-xpi-bringup/11-splash-optimization.md) ⑧ |
| — | 08-31 | FlexCAN ビルトイン化 | ≈7.0s | 微小 | kmm のクリティカルパスから udev を排除(定性的効果)。`meta-kart/recipes-kernel-imx/linux/files/can-builtin.cfg`、コミット 5ec449d |
| 2 | 09-01 | **Falcon mode**(U-Boot proper 1.8s をスキップ) | **6.6s** | -0.4s | ただし SPL の低速 eMMC 読みで falcon.itb 35MB に 1.54s かかり効果が相殺気味。設計・落とし穴①〜③: [04-falcon.md](04-falcon.md)、SPL のメモリ知識: [../../learning/08-uboot-spl-memory.md](../../learning/08-uboot-spl-memory.md) |
| 3 | 09-01 | SPL eMMC を **HS400(ES) @200MHz** 化 | **6.0s** | -0.6s | ロード 1.54→0.90s。config 2 行(`debix-falcon.cfg`)+ 高速 pinctrl の bootph パッチ(`0003-imx8mp-debix-spl-usdhc3-fast-pinctrl.patch`)。[04-falcon.md](04-falcon.md) 実測結果の節 |
| 4 | 09-01 | **35MB の隠れ memmove 除去**(blob 64B パディング + in-place memcpy スキップ) | **5.2s** | -0.8s | ロード 0.90→**0.19s**(読み自体は 119ms=295MB/s だった)。機序: [04-falcon.md](04-falcon.md) ④、教訓(アラインと隠れコピー・バス vs CPU の切り分け): [../../learning/08-uboot-spl-memory.md](../../learning/08-uboot-spl-memory.md)。パディング: `kart-falcon-itb.bb`、スキップ: `0004-spl-fit-skip-inplace-memcpy.patch` |
| 5 | 09-02 | **SPL スプラッシュ + seamless takeover + kart-splash-wl** | **5.2s(維持)** | ±0 | 数値でなく体感の施策: **電源 +0.8s でロゴ点灯**し、GUI まで暗転ゼロ(SPL 描画 24ms、kmm READY はシリアル+journal 実測で 5.2s 維持)。カメラ輝度タイムラインで falcon/proper 両経路 PASS。設計・パッチ・落とし穴: [06-splash.md](06-splash.md) |
| 6 | 09-02 | **カーネル減量**(slim-imx8mp.cfg: 仮想化/SND/BT/無線/V4L2/NFS/IPv6 ほか一掃) | **4.9s** | -0.3s | kernel 1.18→1.08s、userspace も probe/udev 減で -0.34s(kmm READY 3.99→3.65s)、Image ≈35→25.9MB で falcon.itb ロードも短縮(SPL 区間 627→595ms)。**罠**: PINCTRL を select するのは ARCH_S32 だけで、他 SoC 削りで PINCTRL ごと消える(8MM pitfalls #15 の 8MP 版 — cfg 内コメント参照)。NXP defconfig 特有の VIRTIO_VIDEO は XEN/KVM/VIRTIO と一塊で消すこと |
| — | 09-02 | SPL 中の A53 overdrive 1.2→1.6GHz | 5.2s | **-12ms = 効果なし、撤回** | 1.6GHz 化自体は成功(proper バナーが `at 1600MHz`。VDD_ARM は vendor SPL が元々 OD 0.95V なので PLL 切替のみ: spl_board_init で CCM 退避→ARM_PLL 1600→復帰)。しかし SPL バナー→falcon ジャンプ 627→615ms と CPU 律速でなく、さらに **proper 経路の Linux がカーネル極初期以降で沈黙する退行**(2/2 再現、falcon は健全。機序未特定)。利得ゼロ+フォールバック退行のため撤回。再挑戦するならまず proper 退行の機序(U-Boot proper の regulator sync と 1.6GHz の組か)を潰すこと |

## 現在の内訳(5.2s、2026-09-01。シリアルの ts 実測)

| 区間 | 時間 | 備考 |
|---|---|---|
| 電源 → SPL バナー | ~0.6s | BootROM + imx-boot ロード(ROM 側の低速読み) |
| DDR init + PHY training | 0.22s | |
| board init(RNG/GIC) | 0.02s | |
| eMMC init + HS400 交渉 + MBR/FAT | 0.05s | |
| env ロード | 0.13s | 読み自体でなく 16KB のインポート処理(dcache OFF の CPU 仕事)が主と推定 |
| デッドマン env_save + falcon.itb + シム | 0.18s | itb 読み 0.13s / save ~0.02s |
| カーネル | 1.3s | |
| userspace → weston → kmm READY | 2.7s | |

## 残り候補(open-issues #7)

- **A53 起動時クロック 1.2→1.6GHz**(8MM は SPL overdrive 1.8GHz で kernel→GUI
  3.33→2.98s の実績。8MP 未検証。期待 -0.5s 級で現状の本命)
- スプラッシュ(open-issues #4)— 絶対時間でなく「暗い時間」の体感を消す
- kernel 1.3s(config 減量)、weston 初期化 0.8s
- 小粒: env ロード 0.13s(縮小・部分読みは proper とのレイアウト共有に波及するわりに
  最大 0.1s 級 = コスパ低)、DDR training 0.22s(training 結果の保存復元は大掛かり)
