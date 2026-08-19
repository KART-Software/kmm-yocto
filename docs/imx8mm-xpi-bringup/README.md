# XPI-iMX8MM bring up 記録

Geniatech **XPI-iMX8MM**(NXP i.MX8M Mini、RPi 互換フォームファクタ SBC)に、
kart の自作 [Yocto](00-glossary.md#g-yocto) イメージ(自作 [SPL](00-glossary.md#g-spl) / [U-Boot](00-glossary.md#g-u-boot) / カーネル 6.12)を載せるまでの
実機 bring up 全記録。**2026-08-10 に実施。**

到達点(すべて実機で実証):

| マイルストーン | 状態 | 実証方法 |
|---|---|---|
| 自作 SPL の DDR 初期化 | ✅ | [UART](00-glossary.md#g-uart) に `U-Boot SPL 2025.01` バナー(= DDR 訓練後) |
| 自作 U-Boot 2025.01 | ✅ | [UUU](00-glossary.md#g-uuu-universal-update-utility)([SDP](00-glossary.md#g-sdp))で RAM 起動、`u-boot=>` プロンプト |
| カーネル 6.12.20 | ✅ | [NFS](00-glossary.md#g-nfs) root で起動、`VFS: Mounted root (nfs)` |
| [eMMC](00-glossary.md#g-emmc)([HS400](00-glossary.md#g-hs400))/GbE | ✅ | `mmcblk2 8GTF4R HS400`、`Link is Up 1Gbps` |
| [systemd](00-glossary.md#g-systemd) → login | ✅ | `imx8mm-lpddr4-evk login:` 到達 |

**2026-08-11 追記 — 上記「未完」2 点は解決済み**([05-next-steps](05-next-steps.md) 冒頭と
[04-pitfalls](04-pitfalls.md) #14〜#16 参照)。正体はどちらも当初の見立てと別物:
「ネットワーク断」= **U-Boot が武装した WDOG1 60s のウォッチドッグリセット**、
「pinctrl 待ち」= **スリム化の依存崩壊で CONFIG_PINCTRL/GPIOLIB ごと消えていた**。
修正後の実機実証: pet 無し 233s+ 生存 / PMIC probe / **LT9611 revision 0xe2 実読** /
mcp251x が SPI 通信到達(HAT 未装着で err=110 は期待通り)/
**mxsfb-drm 初期化 + `card1-HDMI-A-1` コネクタ出現**(モニタ未接続で
disconnected)/ **devices_deferred 空**。残るはモニタ・CAN HAT を挿しての
物理検証([05](05-next-steps.md) C 項)。

このディレクトリの構成:

| ファイル | 内容 |
|---|---|
| [README.md](README.md) | 本ファイル(全体像・到達点) |
| [00-glossary.md](00-glossary.md) | 用語集(略語・専門用語をこの文脈で解説。初見はまずここ) |
| [01-hardware.md](01-hardware.md) | XPI のハードウェア実測([BSP](00-glossary.md#g-bsp)/[DTB](00-glossary.md#g-dtb) 解析、ピン配置、ブートモード) |
| [02-debug-setup.md](02-debug-setup.md) | デバッグ環境の作り方(UART ブリッジ、権限、[pts](00-glossary.md#g-pts) ミラー、UUU) |
| [03-boot-flow.md](03-boot-flow.md) | ブート経路(SDP → 自作 U-Boot → [TFTP](00-glossary.md#g-tftp)/NFS netboot)の全手順 |
| [04-pitfalls.md](04-pitfalls.md) | 詰まった箇所と回避策(全部) |
| [05-next-steps.md](05-next-steps.md) | 残課題と直し方 |
| [06-emmc-flash.md](06-emmc-flash.md) | eMMC 初回書き込み手順書(新品ボード → スタンドアロン起動) |
| [07-vendor-bsp-audit.md](07-vendor-bsp-audit.md) | ベンダ BSP 監査 — DDR/LT9611/DTS 照合結果と採用候補・リカバリ知見 |
| [08-falcon.md](08-falcon.md) | Falcon Mode — SPL 直カーネル起動の設計・A/B 統合・実測 |
| [09-boot-sequence.md](09-boot-sequence.md) | ブートシーケンス完全解説(初学者向け・図解・用語辞典付き) |
| [10-cortex-m4.md](10-cortex-m4.md) | Cortex-M4 の使い方 (remoteproc・ベアメタル雛形・デバッグ手法) |
| [11-splash-optimization.md](11-splash-optimization.md) | スプラッシュ最適化 — 暗転ゼロ(seamless takeover)+ ロード実質ゼロ(1bit 手続き描画)・実測 timing |

関連: [../imx8mm-migration-design.md](../imx8mm-migration-design.md)(移行の設計判断)、
`meta-kart/recipes-kernel-imx/linux/files/imx8mm-xpi-kart.dts`(XPI 用 [DT](00-glossary.md#g-dt))。

---

## 全体のあらすじ

1. **ボード到着** — 出荷状態は NXP 純正 4.14-sumo(EVK バリアント DTB)、eMMC ブート
2. **偵察** — UART と SSH でベンダ環境を調査し、DDR/eMMC/表示チップ/ピンを確定
3. **BSP 解析** — ベンダ配布物(暗号化 zip は開けず、しかし `.sdcard` イメージから
   コンパイル済み DTB を carve → 逆コンパイル)で LT9611・ECSPI2・eMMC の実配線を採取
4. **XPI 用 DTS 作成** — 採取した実配線で `imx8mm-xpi-kart.dts` を書く
5. **netboot 環境** — 自作カーネルを eMMC に焼かず、TFTP + NFS root で試す仕組みを構築
6. **SDP/UUU で自作 U-Boot 起動** — DDR 関門を自作 SPL で突破、UUU の SPL 後段
   ハンドオフを解決して `u-boot=>` に到達
7. **自作カーネルを netboot** — 自作 U-Boot から TFTP/NFS で 6.12 を起動、login まで到達

**一度も eMMC に書き込んでいない。** 全て RAM(U-Boot)+ NFS([rootfs](00-glossary.md#g-rootfs))で行ったため、
電源を入れ直せば常にベンダ環境に戻る安全な bring up だった。
