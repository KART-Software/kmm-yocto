# 03 — 実機ブート: ブートローダの修正内容と切り分けの知見

machine 正式化([02-dts-delta.md](02-dts-delta.md))した `kart-image-imx8mp-debix` を
DEBIX Infinity 実機で起動するために必要だった imx-boot(SPL/U-Boot)側の修正と、
その過程で確定した知見。暫定対応・未解決事項は [open-issues.md](open-issues.md)。

到達状態(2026-08-30): 自前 imx-boot → BL31 → U-Boot → kernel 6.6.101(`imx8mp-debix.dtb`)
→ systemd → weston(kiosk)。DRAM 4GB 全域使用可、HDMI 出力、FlexCAN×2、GbE、
Tailscale、シリアル root autologin。ベンダー配布バイナリへの依存なし。

## 1. imx-boot に入れた修正

すべて `meta-kart/recipes-bsp-imx/u-boot/`(`u-boot-imx_%.bbappend`、machine 名 `imx8mp-debix` でガード — ボード固有なので SoC レベルの `mx8mp-generic-bsp` ではない)。

| 修正 | ファイル | 理由 |
|---|---|---|
| DDR timing 表を本機 DRAM 用に差し替え | `debix-lpddr4_timing.c`(do_configure で EVK の `lpddr4_timing.c` を上書き) | EVK の表(4000MTS、6GB 実装用)は本機の Micron MT53E1G32D2NP(4GB)で training に失敗し SPL が即死する |
| DRAM サイズ 6GB → 4GB(3GB + 1GB) | `0001-imx8mp-debix-4gb-dram-size.patch` | NXP EVK ヘッダは 3GB+3GB 固定 |
| `CONFIG_USB_TCPC` 無効 | `debix.cfg` | EVK の Type-C コントローラ(PTN5110)初期化が DEBIX には無い IC を叩き、USB ガジェット(fastboot/ums)が `USB init failed: -22` になる |
| `CONFIG_VIDEO` 無効 | `debix.cfg` | U-Boot の video_link が EVK 用 DTB の LCDIF1 → MIPI DSI → ADV7535 をプローブして失敗し、**その残留状態でカーネル側の HDMI TX が無信号になる**。ADV7535 だけ外しても解消するが、U-Boot で絵を出す用途が無いので丸ごと無効化 |
| `CONFIG_DEFAULT_FDT_FILE=imx8mp-debix.dtb` | `debix.cfg` | デフォルト env で独自 DTB を掴ませる |

### DDR timing 表の中身

出典は debix-tech の公開 U-Boot(https://github.com/debix-tech/uboot-nxp-debix)。
本機の DRAM はベンダー呼称 D8BJG(MR5〜8 の ID 0xff070018、Micron 16Gb ダイ ×2 = 4GB)。

- ベース: Model A 用の 3732MTS 表(`lf_v2024.04-yocto_L6.12.3-debix_model_ab_4gbddr`
  ブランチ)。同一配線で、この基板ではコールドから training が通る
- そこに、16Gb ダイ専用表 `lpddr4_timing_D8BJG.c`(`lf_v2025.04-yocto-6.12.49-2.2.0`
  ブランチ、3264MTS)から**密度由来のレジスタだけ**を移植:
  RFSHTMG(tRFC 280→381ns を 3732MTS のコントローラクロック 933MHz でサイクル換算 = 0x710164)、
  DRAMTMG14(t_xsr = 0x16a)、ADDRMAP7(行アドレス bit16: 0xf0f→0xf07)、
  および P1/P2(400/100MTS)の同レジスタ
- 2 表の DDRC 差分は 19 レジスタで、残りはレート依存(3732 vs 3264)のため Model A の値を維持

検証: コールドから training 1 回で通過、`DRAM: 4 GiB`、System RAM 3 バンク
(〜0x13fffffff)、3.2GB のパターン(0x55/0xAA)書き読み化けゼロ、OFF 15 秒のコールド
サイクル 3 回連続成功、パターンループ 20 周(計 128GB)化けゼロ(室温)。

D8BJG 表そのものを使わなかった理由: コールドから直接流すと training 中に SPL がハングする
(再現性あり)。ベンダーの製品 SPL は複数表を順に試す実装で、D8BJG に到達する前に別表で
一度 training を成功させているため見えていない(一般論は
[learning/07](../../learning/07-ddr-init-and-training.md) §5)。

## 2. 切り分けの知見(再利用できるもの)

- **UUU の SDPS 転送が途中(例: 12%)で HID timeout する** → 転送の問題ではなく、BootROM が
  第 1 コンテナ(SPL)だけ読んでジャンプし、SPL が DDR で即死している。シリアルを先に開通させる
- **ブートローダが原因か切り分ける型**: ベンダー配布のブートローダ + 自前 kernel/DTB/rootfs と、
  自前ブートローダ + 同じ kernel/DTB/rootfs を比較する。ブートローダだけが変数になる。
  同じ手で kernel、DTB、userspace も順に無罪化できた
- ベンダー U-Boot の fastboot ガジェットは BootROM と同じ USB ID(1fc9:0146)を名乗り、
  uuu が fastboot と認識しない。ums も ROM → U-Boot 引き継ぎ後の UDC がホストから列挙不能。
  eMMC 書き込みは Linux 稼働中に `dd` する方が確実(scp 先は tmpfs の `/dev/shm`、
  書き込み前に `sysrq-u` で全 FS を ro 化)
- **カーネルが `Starting kernel ...` 直後に無音で止まる**ときは earlycon を足す。DDR の
  アドレスマップ不良は U-Boot では無症状で、カーネルの全ページ初期化で初めて死ぬ
  (`mem=` で上位を切ると通る = アドレスマップを疑う)
- **DRM がモードセット成功と報告していても信号が出ていないことがある**。
  モニタ側の「No Signal」表示と、別のディスプレイでの陽性対照で判定する
- debugfs の `edid_override` は `printf reset`(改行なし 5 バイト)でしか解除できない
  (`echo reset` は EINVAL)。解除し忘れると以後の EDID 読み取りが全部偽物になる

## 3. TFP401 LCD(800x480)と 8MP HDMI の制約

- パネルの EDID は 800x480 @ **32.00MHz**。8MP の Samsung HDMI PHY は離散 88 点のクロック表
  (23.75〜297MHz)しか出せず 32MHz が無いため、mode_valid で全モードが落ち weston が
  `no available modes` で起動しない
- 通る設定: pclk **33.75MHz** + ブランキング拡張(htotal 1072、vtotal 525 → 59.97Hz)。
  debugfs の edid_override で検証済み。恒久化は open-issues.md 参照

## 4. weston kiosk 設定の 8MP 適用

8MP(NXP BSP)では meta-freescale の `weston-init.bbappend` が `imx-nxp-bsp/weston.ini` を
持っており、FILESEXTRAPATHS の順序で `file://weston.ini` を横取りする(8MM = mainline BSP
では該当ファイルが無く起きない)。別名 `weston-debix.ini` で持ち込み、override 付き
`do_install:append:imx8mp-debix` で上書きする(`recipes-graphics/weston/`)。
