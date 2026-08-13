# 08 — Falcon Mode(SPL 直カーネル起動)

U-Boot proper(1.39s)をスキップし、SPL が FAT 上の FIT からカーネルを直接
起動する。実測: **初バイト→GUI 5.21s → 3.66s(−1.55s / −30%)**、
電源→GUI 約 4.7〜4.8s(N=5、2026-08-13)。

```
従来:   ROM → SPL(DDR) → flash.bin 内 FIT[ATF+U-Boot proper] → extlinux
        → Image/DTB ロード → カーネル                  … proper 区間 1.39s
Falcon: ROM → SPL(DDR) → FAT の falcon.itb[ATF+Image+DTB] → シム → カーネル
                                                        … 同区間 0.18s
```

## 設計の核心 — なぜ「シム」か

この tree の imx-atf(lf_v2.10)は **SPL から渡す bl31_params を完全に無視**し、
BL33 = `0x40200000` へ x0〜x7=0 で盲目ジャンプする
(`plat/imx/imx8m/imx8mm/imx8mm_bl31_setup.c` — arg0..3 未参照、実コード確認)。
カーネルは x0=DTB アドレスを要求するため、正攻法なら ATF パッチが要る。

代わりに **SPL が `0x40200000` に 8 命令のシム(`x0=DTB; x1-3=0; br カーネル`)を
書いてから ATF へ跳ぶ**。ATF は無改造・従来と同一動作のまま、シムがカーネルへ
中継する。EL2 突入・全例外マスク・x1〜x3=0 は ATF の既定動作が既にカーネルの
ブートプロトコル通りで、欠けていた pc と x0 だけをシムが埋める。

## 実装物

| ファイル | 役割 |
|---|---|
| `recipes-bsp-imx/u-boot/files/0001-imx8mm-kart-falcon-mode.patch` | SPL 改造本体(下記) |
| `recipes-bsp-imx/u-boot/files/kart-falcon.cfg` | SPL_OS_BOOT/FS_FAT/ENV ほか config |
| `recipes-bsp-imx/kart-falcon-itb/` | falcon-{a,b}.itb / u-boot.itb / args を生成・deploy |
| `kas/imx8mm-falcon.yml` | 上記を有効化するオーバーレイ(通常ビルド無影響) |
| `scripts/kart-falcon-bench.uuu` | eMMC 無書き込みの RAM ベンチ用 |

パッチ内容:
- `spl_start_uboot()`: env(eMMC 4MiB)を読み、`upgrade_available=1`(OTA 試行中)
  か `boot_os=no`(手動脱出)なら **U-Boot proper へ委譲**、それ以外は falcon
- `spl_perform_fixups()`: falcon FIT のときだけ(`os == IH_OS_U_BOOT` 以外
  かつ fdt あり — 実測で falcon FIT は os=255 になる)、`/memory` 修正 +
  シム設置 + dcache flush
- `spl_mmc_boot_mode()` / `spl_board_boot_device()`: SDP(UUU) RAM 起動でも
  eMMC falcon 経路を通す(ベンチ用 + 挙動一貫性)
- `mmc_get_env_dev()`: SPL の DM は usdhc 2 台構成で eMMC=dev1(実測)のため
  SPL フェーズは dev1 固定
- `imx8mm-u-boot.dtsi`: uboot ノードに `os = "u-boot"` を付与(SPL_OS_BOOT 有効時、
  os 無しの u-boot FIT が DTB を貰えなくなる回帰の予防 — 調査時の R1)

## A/B・OTA との統合(重要)

- **スロット選択 = MBR bootable フラグ**(`SYS_MMCSD_FS_BOOT_PARTITION=-1`)。
  slot a → p1、slot b → p2。`kart-ab-commit` が env 確定と同時にフラグを
  付け替える(dd による MBR 512B 再構成 + 読み戻し検証。busybox 制約対応済み)。
  初回イメージは wks の `--active` で p1 に付与
- **OTA 試行は従来どおり U-Boot proper が担当**: `upgrade_available=1` を SPL が
  見て FAT 上の `u-boot.itb`(proper フォールバック FIT)を起動 → 実績ある
  bootcount/altbootcmd/extlinux 経路がそのまま走る。**bootcount 機構の SPL
  移植は不要**(この設計判断が工事を半減させた)
- **falcon.itb はスロット毎に root= を焼き分け**(`falcon-a.itb`=p5 /
  `falcon-b.itb`=p6)。boot パーティションに両変種を置き、`falcon.itb`
  (SPL が読む固定名)への複写を初回イメージ(=a)と `ota-update.sh`
  (書き込み先スロット変種)が行う

## ブートパーティション内容(falcon 構成)

```
Image, imx8mm-xpi-kart.dtb, extlinux/     ← 従来分 (proper フォールバック用に温存)
falcon.itb                                ← SPL が起動する実体 (スロット変種の複写)
falcon-a.itb, falcon-b.itb                ← 両変種
u-boot.itb                                ← OTA 試行時の proper (nodtb+ATF+control DTB)
args                                      ← SPL falcon 機構が要求するダミー
```

## リスクと復旧経路

- **R2(設計上の要注意)**: `SPL_FS_FAT` 有効化で raw モード(flash.bin 内
  proper 直読み)は到達不能。フォールバックは FAT 上の `u-boot.itb`。
  「アクティブスロットの FAT 破損」への備えは A/B の相互スロット +
  U-Boot 自体の A/B(B 面 = stock 版を温存)
- 復旧の多層: falcon FIT 読めず → u-boot.itb(proper) → それも駄目なら
  U-Boot A/B の B 面(stock、ROM の IVT フォールバック) → 最終 UUU/SDP。
  **UUU リカバリには stock ビルド(falcon オーバーレイ無し)の flash.bin を使う**
  (falcon SPL は SDPV を受けないため kart-boot.uuu は stock 専用になった)。
  stock 版は `scripts/build-recovery-uboot.sh` が `local/recovery/flash.bin-stock`
  へ退避し、kart-boot.uuu はそこを参照する(deploy の上書き合戦から独立)
- 検証手順: 変更時はまず `kart-falcon-bench.uuu` で RAM 起動ベンチ
  (eMMC 無書き込み) → 通ってから `kart-uboot-update`(B 面に前版温存)

## 計測(2026-08-13、eMMC コールドブート N=5)

| 区間 | 実測 |
|---|---|
| SPL: env 読取 + falcon.itb 21.5MB ロード + シム | 0.164s ±2ms |
| シム → BL31 | 0.015s |
| カーネル → GUI (kmm READY) | 3.48s ±0.17 |
| 初バイト → GUI | **3.66s**(従来 5.21s) |

懸念だった「SPL の eMMC 読みが遅い」は実測で否定(実効 ~130MB/s)。
