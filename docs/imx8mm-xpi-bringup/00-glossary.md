# 00 — 用語集

この bring up 記録に出てくる略語・専門用語を、**この文脈での意味**で解説する。
アルファベット数文字の略語は初見で詰まりやすいので優先的に収録。
五十音・アルファベット混在、おおむね分野別。

---

## ブート / ブートローダ

- <a id="g-bootrom"></a>**BootROM(ブートROM)** — SoC 内蔵の、電源投入直後に必ず動く読み取り専用の
  起動コード。どこから次段を読むか(eMMC/SD/USB)を BOOT スイッチや fuse で決める。
  i.MX8MM の BootROM は UART に**何も出力しない**(だから SDP 待ちは無音)。
- <a id="g-spl"></a>**SPL(Secondary Program Loader)** — U-Boot の第 1 段。**DDR(メモリ)を初期化**し、
  U-Boot 本体を RAM に読み込む小さなプログラム。「SPL バナーが出た = DDR 初期化成功」。
- <a id="g-u-boot"></a>**U-Boot** — 組み込み用ブートローダ本体。`u-boot=>` プロンプトでコマンドを打てる。
  カーネルを読んで起動する。今回の自作版は **2025.01**、ベンダ版は **2018.03**。
- <a id="g-booti"></a>**booti** — U-Boot のカーネル起動コマンド(arm64 の生 `Image` 用。
  bootm=uImage/FIT、bootz=32bit zImage の兄弟)。`booti <kernel> <initrd|-> <dtb>` で
  Image ヘッダ検査(magic `ARM\x64`)→ 再配置 → DTB fixup/後始末 →
  **x0=DTB・x1〜x3=0 の入場規約でジャンプ**する。netboot(03/06)と extlinux 経路が
  使用。falcon はこれをシム 8 命令に切り詰めた代替([09](09-boot-sequence.md) ③)。
  pitfalls #4 の「Image magic エラー」はこのヘッダ検査。
- <a id="g-imx-boot"></a><a id="g-flash-bin"></a>**imx-boot / flash.bin** — SPL + U-Boot(+ ATF)を 1 つにまとめた i.MX 用の
  ブートローダイメージファイル。これを eMMC/SD の決まったオフセットに置く。
- <a id="g-atf"></a><a id="g-bl31"></a>**ATF(Arm Trusted Firmware)/ BL31** — Arm の セキュアファームウェア層。
  U-Boot の前に読み込まれ、PSCI(電源管理)等を提供。ログの `NOTICE: BL31` がこれ。
- <a id="g-ddr-training"></a>**DDR training(DDR 訓練)** — 起動時に DRAM の信号タイミングを実測校正する処理。
  `training for 3000/400/100MTS ... PASS` の 3 段。ここが通らないと起動できない
  ため、SoC 移行の最大リスクだった。**MTS = Mega Transfers per Second**(DRAM 速度)。
- <a id="g-autoboot"></a>**autoboot** — U-Boot が「Hit any key to stop autoboot」のカウントダウン後に
  自動でカーネルを起動する動作。キー入力で止めてプロンプトに入る。
- <a id="g-falcon-mode"></a>**Falcon Mode** — SPL が U-Boot 本体を飛ばして直接カーネルを起動する高速化手法
  (今回未使用、将来案)。

## USB 書き込み(NXP 固有)

- <a id="g-sdp"></a>**SDP(Serial Download Protocol)** — i.MX の BootROM が USB 上で見せる
  ダウンロードプロトコル(HID デバイス)。ストレージではない。ここに `uuu` で
  imx-boot を流し込んで RAM 起動する。PC からは `1fc9:0134 NXP SE Blank` に見える。
- <a id="g-sdpu"></a><a id="g-sdpv"></a>**SDPU / SDPV** — SPL 段が次段(U-Boot 本体)を受け取るための SDP の派生プロトコル。
  `SDP: boot` だけでは SPL 止まりで、**SDPV: write/jump** まで送って初めて U-Boot が上がる。
- <a id="g-uuu-universal-update-utility"></a><a id="g-mfgtools"></a>**UUU(Universal Update Utility / mfgtools)** — NXP 製の書き込みツール。SDP 経由で
  RAM 起動したり、eMMC に焼いたりする。`uuu -lsusb` でデバイス確認、`uuu <script>` で実行。
- <a id="g-uuu-auto"></a>**uuu.auto** — UUU のスクリプトファイル。SDP→SDPV→FB(fastboot)の各ステージを記述。
- <a id="g-fb"></a>**FB(Fastboot)** — Android 由来の書き込みプロトコル。U-Boot が起動後に提供し、
  eMMC への本焼きに使う(今回は netboot までで未使用)。
- <a id="g-ivt"></a>**IVT(Image Vector Table)** — i.MX ブートイメージ先頭の小さなヘッダ(目次)。
  タグ 0xD1・バージョン 0x41・エントリポイント・ロード先などを持ち、
  **BootROM の「このイメージは正当か」検査の実体はこのヘッダ検査だけ**
  (非セキュアブートでは本体のチェックサムを見ない)。U-Boot A/B では
  「IVT の有効/無効」が事実上の起動面切替スイッチになる([04](04-pitfalls.md) #19)。
- <a id="g-psb"></a>**PSB(PERSIST_SECONDARY_BOOT)** — SRC_GPR10[30] のビット。**ROM がフォールバック
  起動中に立てる「B 面で動いている」印(出力)**であり、ソフトから立てても
  次回起動は変わらない(実機検証 2026-08-12、[04](04-pitfalls.md) #19。
  GPR10 はあらゆるリセットでクリアされる。imx6/7 の同名機構とは挙動が違う)。
- <a id="g-sit"></a>**SIT(Secondary Image Table)** — B 面イメージの位置を BootROM に教えるテーブル
  (sector 0x41)。A 面の IVT が不正なとき、ROM は**同一起動内で** SIT の指す
  B 面へ inline フォールバックする(実機検証済み)。

## netboot / ネットワーク

- <a id="g-tftp"></a>**TFTP(Trivial FTP)** — 極めて単純なファイル転送。U-Boot がカーネルと DTB を
  PC から RAM に落とすのに使う。`tftp ${loadaddr} Image`。
- <a id="g-nfs"></a>**NFS(Network File System)** — ネットワーク越しにファイルシステムを共有。
  **NFS root** = rootfs(`/`)を PC のディレクトリから LAN 経由でマウントする起動。
  eMMC に焼かずにカーネルを試せる。
- <a id="g-nfs-root-ip"></a>**NFS root の `ip=`** — カーネル cmdline のパラメータ。
  `ip=<client>:<server>:<gw>:<mask>:<host>:<iface>:off` の形で、カーネルが
  NFS root のためにネットワークを静的設定する。
- <a id="g-dhcp"></a>**DHCP** — IP アドレス自動割り当て。U-Boot の `dhcp` コマンドや systemd-networkd が使う。
- <a id="g-rgmii"></a>**RGMII** — Ethernet MAC と PHY を繋ぐ配線規格(Gigabit)。XPI は AR8033 PHY で RGMII。
- <a id="g-phy"></a>**PHY** — Ethernet の物理層チップ。XPI は Qualcomm Atheros **AR8031/AR8033**。
- <a id="g-mac"></a><a id="g-ethaddr"></a>**MAC アドレス / ethaddr** — NIC の固有アドレス。自作 U-Boot は持たないので
  `setenv ethaddr ...` で手動設定した。

## デバイスツリー / カーネル

- <a id="g-dt"></a><a id="g-dts"></a><a id="g-dtb"></a>**DT(Device Tree)/ DTS / DTB** — ハードウェア構成の記述。**DTS** がソース(テキスト)、
  **DTB** がコンパイル済みバイナリ。カーネルは DTB を読んでどんな周辺機器があるか知る。
  SoC が同じでもボードごとに DTS が違う(これが移行作業の大半)。
- <a id="g-dtc"></a>**dtc(Device Tree Compiler)** — DTS ⇄ DTB を変換するツール。`dtc -I dtb -O dts` で逆コンパイル。
- <a id="g-overlay"></a>**overlay(DT オーバーレイ)** — ベース DT に部分的な変更を重ねる仕組み。RPi の
  `mcp2515-can0` はファームウェアが起動時に適用するが、i.MX には無いので DTB に直書き。
- <a id="g-pinctrl"></a>**pinctrl(pin control)** — SoC のピンをどの機能(SPI/I2C/GPIO…)に割り当てるかの設定。
  **IOMUXC** がその制御ブロック。DTS の `pinctrl_xxx` グループで定義。
- <a id="g-deferred-probe"></a>**deferred probe(遅延プローブ)** — ドライバが依存先(supplier)の準備を待って
  probe を保留する仕組み。今回 pinctrl グループ未定義で LT9611/CAN が**永久保留**になった。
- <a id="g-iomuxc"></a>**IOMUXC** — i.MX の I/O Multiplexer Control。どのパッドをどの機能にするかを設定するレジスタ群。
- <a id="g-snvs"></a><a id="g-caam"></a>**snvs / caam** — i.MX 内蔵の周辺。**SNVS** = Secure Non-Volatile Storage
  (RTC・電源キー等)、**CAAM** = 暗号アクセラレータ(RNG 含む)。起動ログに出る。

## 表示 / CAN

- <a id="g-mipi-dsi"></a>**MIPI-DSI** — SoC が出すディスプレイ用シリアル信号。XPI はこれを **LT9611** で
  HDMI に変換。**MIPI-CSI** はカメラ入力側。
- <a id="g-lt9611"></a>**LT9611(Lontium)** — DSI→HDMI ブリッジチップ。XPI の HDMI 出力の実体。
  EVK の **ADV7535**(Analog Devices)とは別物なのが DTS 差分の核。
- <a id="g-lcdif"></a><a id="g-mxsfb"></a>**LCDIF / mxsfb** — i.MX の表示コントローラと、その Linux ドライバ名。
  LT9611 ブリッジに繋がって初めて画が出る(`Cannot connect bridge` = ブリッジ未接続)。
- <a id="g-etnaviv"></a>**etnaviv** — Vivante GPU(i.MX 内蔵)の mainline Linux ドライバ。weston の描画に使う。
- <a id="g-can"></a>**CAN(Controller Area Network)** — 車載等のバス。kart の CAN は SPI 接続の
  **MCP2515** コントローラ(i.MX8M Mini に CAN 内蔵は無い)。**FlexCAN** は
  i.MX8M **Plus** の内蔵 CAN(Mini には無い)。
- <a id="g-ecspi"></a>**ECSPI** — i.MX の SPI コントローラ(Enhanced Configurable SPI)。CAN は ECSPI2。

## ストレージ / メモリ

- <a id="g-emmc"></a>**eMMC** — 基板直付けのフラッシュストレージ。XPI は Samsung 8GB。
  **boot0/boot1** = eMMC のハードウェアブートパーティション(ユーザー領域とは別区画。
  ベンダはここに imx-boot を置く)。**rpmb** = 認証付き保護領域。
- <a id="g-hs400"></a><a id="g-enhanced-strobe"></a>**HS400 / Enhanced strobe** — eMMC の高速転送モード。実機で認識された。
- <a id="g-usdhc"></a>**usdhc(uSDHC)** — i.MX の SD/MMC コントローラ。eMMC は usdhc3(= `mmcblk2`)。
- <a id="g-lpddr4"></a>**LPDDR4** — 低電力 DRAM。XPI は 2GB。**PMIC**(BD71847)が電源供給。
- <a id="g-pmic"></a>**PMIC(Power Management IC)** — 電源管理チップ。XPI は EVK と同じ **BD71847**。

## Yocto / ビルド

- <a id="g-yocto"></a><a id="g-bitbake"></a>**Yocto / BitBake** — 組み込み Linux のビルドシステム。**レシピ(.bb)**が
  各ソフトの作り方、**bbappend** が既存レシピへの追記、**machine** がターゲット定義。
- <a id="g-kas"></a><a id="g-kas-container"></a>**kas / kas-container** — Yocto を Docker で回すためのラッパー。`kas/*.yml` で
  レイヤ構成を合成する。
- <a id="g-bsp"></a>**BSP(Board Support Package)** — あるボード向けの Yocto レイヤ・カーネル・
  U-Boot 一式。ベンダ(Geniatech)配布の BSP は暗号化 zip で開けなかった。
- <a id="g-rootfs"></a>**rootfs** — ルートファイルシステム(`/` の中身)。netboot では NFS 経由で供給。
- <a id="g-cfg"></a>**cfg フラグメント** — カーネル config の部分ファイル(`.cfg`)。`slim-*.cfg` で
  機能を削る。
- <a id="g-srcrev"></a>**SRCREV** — レシピが取得するソースの Git コミット。アプリのバージョン固定に使う。

## systemd / 起動

- <a id="g-systemd"></a>**systemd** — Linux の init(サービス管理)。**unit** が各サービス、**target** が
  グループ(`multi-user.target` 等)。**mask** = サービスを `/dev/null` リンクで無効化。
- <a id="g-systemd-networkd"></a>**systemd-networkd** — systemd のネットワーク管理。NFS root では eth0 を奪って
  接続を落とすので mask した(「16 秒の壁」)。
- <a id="g-udev"></a>**udev** — デバイスノード(`/dev/*`)の生成と命名を管理。predictable naming が
  `eth0→end0` の改名をする。**udev ルール**でデバイス権限を恒久化した。

## デバッグ機材 / ホスト

- <a id="g-uart"></a>**UART** — シリアル通信。デバッグコンソール。XPI の A コアは UART2(`ttymxc1`)、
  115200 8N1。
- <a id="g-teensy-4-0"></a>**Teensy 4.0** — 小型マイコンボード。今回 A/M 2 コアの UART を USB CDC ×2 に
  ブリッジするのに使った(`tools/teensy-uart-bridge`)。
- <a id="g-cdc"></a><a id="g-acm"></a>**CDC(Communications Device Class)/ ACM** — USB のシリアル通信規格。
  Teensy や多くの USB シリアルが `/dev/ttyACM*` として見える。
- <a id="g-ftdi"></a><a id="g-ch340"></a>**FTDI / CH340** — USB シリアル変換チップ。`ttyUSB*` として見える。
- <a id="g-hidraw"></a>**hidraw** — Linux が USB HID デバイスを生で読み書きするインタフェース
  (`/dev/hidraw*`)。DP100 制御に使用。
- <a id="g-dp100"></a>**DP100(ALIENTEK)** — USB 制御の実験用電源。電源断/投入の自動化に使う予定。
- <a id="g-sysrq"></a>**sysrq** — カーネルの緊急操作機能。`echo b > /proc/sysrq-trigger` で即再起動。
- <a id="g-pts"></a>**pts(pseudo-terminal slave)** — 疑似端末。`/dev/pts/15` にログをミラーして
  ユーザー端末にライブ表示した。

## kart 固有 / A/B

- <a id="g-a"></a><a id="g-b"></a>**A/B(スロット)** — OS を 2 面持ち、片面を更新して失敗したら戻す仕組み。
  RPi5 は **tryboot**(ファームウェア機能)、i.MX は **U-Boot bootcount** で実装。
- <a id="g-tryboot"></a>**tryboot** — RPi ファームウェアの「今回だけ別スロットで起動」機能。i.MX には無い。
- <a id="g-bootcount"></a><a id="g-upgrade-available"></a><a id="g-altbootcmd"></a>**bootcount / upgrade_available / altbootcmd** — U-Boot の A/B 用環境変数。
  起動失敗が続くと altbootcmd で旧スロットへフォールバックする。
- <a id="g-ota"></a>**OTA(Over-The-Air)** — ネットワーク越しの OS 更新。`scripts/ota-update.sh`。
- <a id="g-kmm"></a>**kmm(kart-machine-manager)** — kart の GUI アプリ本体(C++/Qt6)。
- <a id="g-weston"></a>**weston** — Wayland のコンポジタ(画面表示の土台)。kiosk モードで kmm を全画面表示。
