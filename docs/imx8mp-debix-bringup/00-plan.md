# 00 — DEBIX Infinity (EMB-IMX8MP-06-D4E32) ブリングアップ計画

一次資料は DEBIX 公式ドキュメント(User Manual v1.11・回路図・product brief、
https://debix.io)、公式イメージ/ソース(https://download.debix.io、
https://github.com/debix-tech)。ここには**移行計画と実測ログ**を置く。
XPI-iMX8MM の docs (`../imx8mm-xpi-bringup/`) が形式のリファレンス。

## ボード要点(survey からの抜粋、詳細は 01-survey.md)

| 項目 | 値 | XPI-iMX8MM との差分 |
|---|---|---|
| SoC | i.MX8MP Quad **Lite**(NPU/ISP なし)A53×4 @1.6GHz + **M7** @800MHz | A53 1.8→1.6GHz、M4→M7 |
| RAM / eMMC | LPDDR4 4GB / 32GB | 2GB/8GB → 4GB/32GB |
| CAN | **FlexCAN ×2 内蔵** | MCP2515(SPI)+M4 GW → ネイティブ。**rpmsg candev 構成が不要になる見込み** |
| 表示 | **HDMI ネイティブ** + LVDS + MIPI-DSI | DSI→LT9611 ブリッジの苦労が消える |
| Ethernet | GbE ×2(eqos TSN + fec) | ×1 → ×2 |
| デバッグ UART | UART2 = J2 Pin7/9/11(GND/RX/TX)115200 | J63 相当 |
| 書込 | DIP `001`=UUU / `010`=eMMC / `011`=SD | S1 相当 |

## 既知の罠(survey §要注意より)

1. debix-tech Yocto レシピの SRCBRANCH が現存しない(リネーム済み)— 修正必須
2. 公開 U-Boot ソースは 2GB DDR 前提 — **D4E32(4GB)で最初に `bdinfo`/`free` 確認**
3. 公開 DTS は最小構成(eqos 1 本のみ)— fec/CAN/LVDS/PCIe/WiFi の DTS 整備が主要作業

## 進め方

1. **公式イメージで実機確認**(SD、DIP=011): 4GB/eMMC/GbE×2/HDMI/CAN。動く DTB と
   kernel config を吸い出してリファレンス化(XPI の「ベンダ DTB carve」の流儀)
2. **スキャフォールドビルド**: `kas/imx8mp-dev.yml`(machine=imx8mp-lpddr4-evk 流用)で
   kart-image が組めるか。EVK 想定との差分を洗う
3. **machine 正式化**: `imx8mp-debix.conf`(imx8mm-xpi.conf の流儀)+ DEBIX DTS
4. 製品機能の移植: eMMC A/B + OTA / read-only rootfs / Tailscale / weston+kmm /
   Falcon+スプラッシュ / serial autologin — 8MM で確立済みのものを順次
5. CAN 再設計: FlexCAN ネイティブ化(M4/M7 ゲートウェイ廃止の判断込み)。
   ADS8688 等のセンサ収集を M7 に残すかも合わせて設計

## 実測ログ

### 2026-08-27 — 工場イメージで初回起動(計画 step 1)

LAN DHCP で `ssh debix@192.168.0.7`(pass: debix)。確認結果:

| 項目 | 結果 |
|---|---|
| OS / kernel | Ubuntu 20.04.3 + **5.10.72 NXP BSP**(hostname imx8mpevk、GNOME on Wayland/gdm) |
| RAM | **3.8Gi 認識 = 4GB OK**(懸念だった 2GB U-Boot 問題は工場イメージでは非発現) |
| eMMC | mmcblk2 28.9G、p1=/boot 490M + p2=/ 28.3G から起動(console=ttymxc1=UART2) |
| **起動 DTB** | **`/boot/imx8mp-evk.dtb`**(live FDT との diff は U-Boot fixup の 28 行のみ。md5 は `imx8mp-debix-core-board.dtb` と同一物。`imx8mp-debix-4g-board.dtb` は**未使用** — 4GB は U-Boot の memory fixup で対応) |
| CAN | **can0/can1 両方 netdev として存在**(工場 DTS は FlexCAN×2 有効、clock 40MHz)。can0 を loopback モード + 500kbps で up → cansend/candump 成功。※loopback はコントローラ+ドライバ+クロックの確認まで。**トランシーバ/ピンの実配線はまだ陽性対照なし** |
| HDMI | dwhdmi(DesignWare HDMI TX v2.13a)bound、EDID 取得、card1-HDMI-A-1 connected |
| Ethernet | ens33/ens34 の 2 本(GbE×2)、WiFi 88W8987(mlan0/uap0)あり |
| GPU | Vivante galcore 6.4.3.p2 |
| M7 | remoteproc ノードなし(工場 DTS に cm7 なし — [01-m7.md](01-m7.md) の想定どおり) |
| A53 | max 1.6GHz |

工場イメージから採取したリファレンス:
live-fdt.dtb(+dts)、/proc/config.gz、dmesg.txt、
imx8mp-evk.dtb / imx8mp-debix-4g-board.dtb / imx8mp-debix-io-board.dtb(各 dts 化済み)。
