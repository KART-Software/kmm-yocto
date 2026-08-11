# 05 — 残課題と直し方

login まで到達したが未完の 2 点と、その先。**どれも実機なしで [DTS](00-glossary.md#g-dts)/構成を
直して再ビルド → 次の netboot で確認できる。**

> **2026-08-11 追記: A と B は解決済み。** 実体は当初の見立てと大きく違った
> ([04-pitfalls](04-pitfalls.md) #14〜#16 参照)。
> - 「login 後のネットワーク断」の正体は **ネットワークではなくウォッチドッグ
>   リセット** (U-Boot が武装した WDOG1 60s を誰も引き継いでいなかった)。
> - deferred probe の正体は「[pinctrl](00-glossary.md#g-pinctrl) グループ未定義」ではなく、
>   **スリム化の巻き添えで CONFIG_PINCTRL / CONFIG_GPIOLIB がカーネルから
>   消えていた** (グループは全部 DTB に存在した)。
> - 修正: `watchdog.cfg` (IMX2_WDT=m) + `pinctrl-gpio.cfg` (PINCTRL/GPIOLIB 復活)
>   + `kas/imx8mm-netboot.yml` の `KART_NETBOOT` スイッチ (networkd mask 焼き込み)
>   + XPI DTS の EVK 残骸無効化 + mxsfb の NO_CONNECTOR パッチ。
> - 実機検証: pet 無しで uptime 233s 生存 / PMIC・ECSPI2・cpufreq の deferred 解消 /
>   **LT9611 revision 0xe2 を I2C で実読** / mcp251x が SPI で実チップと会話
>   (HAT 未装着なので err=110 は期待通り)。

## A. NFS root + networkd の完全分離(netboot 用)— 解決済み

現状は [NFS](00-glossary.md#g-nfs) ディレクトリに手で mask を投入している([03](03-boot-flow.md))。
これを **netboot オーバーレイに正式に組み込む**。実機の [eMMC](00-glossary.md#g-emmc) 起動イメージには
入れない(ローカル root では networkd が必要)。

**実装 (2026-08-11)**: `kart-image.bb` の `netboot_mask_networkd`
(ROOTFS_POSTPROCESS、`KART_NETBOOT = "1"` のときだけ有効) +
`kas/imx8mm-netboot.yml` がスイッチを立てる。networkd 3 ユニットの
mask が rootfs に焼き込まれることを tar で確認済み。
なお「mask 後もネットワーク断が残る」ように見えたのは B の
ウォッチドッグリセットの誤認で、ネットワーク自体は安定している。

## B. pinctrl の deferred probe(LT9611 / CAN / backlight)— 解決済み

login 時の実機ログ(`local/`… または再取得)にこの一覧が出た:

```
32e00000.lcdif : mxsfb: Cannot connect bridge        (LT9611 待ち)
i2c 3-003b     : wait for supplier .../lt9611grp      (LT9611)
30830000.spi   : wait for supplier .../ecspi2csgrp    (CAN の CS)
30660000.pwm   : wait for supplier .../backlightgrp
backlight      : supplier 30660000.pwm not ready
i2c 0-004b     : wait for supplier .../pmicirqgrp
33800000.pcie  : wait for supplier .../pcie0grp       (PCIe は XPI に無い)
```

**当初の見立て(誤り):** 「参照している pinctrl グループが iomuxc に未定義、
または名前の食い違い」と推定していた。

**実際の原因 (2026-08-11 確定):** グループは**全部 DTB に存在していた**
(自作 FDT パーサで確認)。真犯人は **スリム化の依存崩壊で
`CONFIG_PINCTRL` / `CONFIG_GPIOLIB` がカーネルから消えていた**こと。
slim-imx-arch.cfg が他ベンダー SoC (ARCH_*) を削った結果、PINCTRL/GPIOLIB の
ゲートを select する構成が居なくなり、defconfig が明示していた
`PINCTRL_IMX8MM=y` / `GPIO_MXC=y` も依存不成立で olddefconfig に黙って
落とされた (fragment には一行も書いていないのに消える)。
pinctrl ドライバが永遠に現れないので、fw_devlink がグループ supplier を
待つ全 consumer が永久 deferred になっていた。`fw_devlink=off` ブートで
挙動が一変することから切り分けた ([04-pitfalls](04-pitfalls.md) #15)。

**修正一式:**
1. `pinctrl-gpio.cfg` — PINCTRL / PINCTRL_IMX8MM / GPIOLIB / GPIO_MXC を明示 =y。
2. `watchdog.cfg` — IMX2_WDT=m ([04-pitfalls](04-pitfalls.md) #14)。
3. XPI DTS で EVK 残骸を無効化。pinctrl 復活で残骸が**実際に足を駆動し始める**
   ため必須になった: `reg_pcie0` が GPIO1_IO05 (XPI では LT9611 の IRQ 線) を
   掴む / pdmgrp (micfil) が SAI5_RXD3 (CAN INT パッド) を取り合う /
   leds が GPIO3_IO16 を出力 ON で掴む等。pcie/typec/backlight/i2c3(カメラ・
   GPIO エキスパンダ)/micfil を disable、leds/ir/backlight を delete。
   PMIC (BD71847, IRQ=GPIO1_IO03) は EVK と同配線 (ベンダ DT で確認) なので
   そのまま生かす → probe 成功、cpufreq も解消。
4. `0001-drm-mxsfb-attach-bridge-with-NO_CONNECTOR.patch` +
   `CONFIG_DRM_DISPLAY_CONNECTOR=y` — 6.12 の lontium-lt9611 は
   NO_CONNECTOR 前提 (自前コネクタ機構が無い) なので、mxsfb を
   `DRM_BRIDGE_ATTACH_NO_CONNECTOR` + `drm_bridge_connector_init()` に変更
   ([04-pitfalls](04-pitfalls.md) #16)。

## C. その先(A/B が通ってから)

1. **CAN 実機確認** — MCP2515 HAT を挿し、`ip link set can0 up type can bitrate 1000000`
   → `candump`。DTS の CAN INT(GPIO3_IO24)と ECSPI2 配線の検証。
2. **HDMI 表示** — LT9611 が connect したら [weston](00-glossary.md#g-weston)/[kmm](00-glossary.md#g-kmm) が画を出すか。
   `/sys/class/drm/card0-HDMI-A-1/status`。
3. **userspace→GUI の実測** — 移行判断で唯一未実測の値。RPi5 の [UART](00-glossary.md#g-uart) 計測
   ハーネス(`docs/boot-timing.md`)をそのまま適用。A53 + [etnaviv](00-glossary.md#g-etnaviv) での weston+kmm
   起動時間が移行の損益を決める。
4. **eMMC への本焼き — 完了 (2026-08-11 実機実証)**。手順は UUU/`ums` ではなく
   **netboot Linux から dd** が最も簡単だった(全部実績のある経路のみ使う):
   1. `./scripts/build.sh imx8mm --emmc` → `kart-image-...-emmc.wic`(3.9GB raw)
   2. wic を NFS root の `/root/` に置き、ボード上で
      `dd if=/root/kart-emmc.wic of=/dev/mmcblk2 bs=1M`(user 領域のみ。
      **boot0 のベンダブートローダは無傷**。先頭 8MiB は
      `local/xpi-backup/emmc-head-8mib.img` に退避済み)
   3. SDP U-Boot から `mmc partconf 2 0 7 0`(BOOT_PARTITION_ENABLE=0x7 =
      user 領域)。ベンダ復帰は `mmc partconf 2 0 1 0`
   4. S1 を `0110 1010`(eMMC)にして電源投入
   実測: ROM が `Trying to boot from MMC2` → wic に焼き込んだ A/B env で
   `KART: booting slot a (mmc 2:1)` → **U-Boot 段 ≈2.1s / login +15.4s**
   (シリアル初バイト起点)。extlinux の `rw` は systemd が ro に再マウントし
   read-only rootfs 維持、`/data`(p7) rw マウント、systemd が
   RuntimeWatchdogSec=15 で watchdog を open、`kart-ab-status` も動作。
   残: OTA (`ota-update.sh`) の i.MX 経路と B スロット試行/フォールバックの
   実機検証、U-Boot A/B (PSB) の検証。
5. **XPI 用 machine の正式化** — 今は EVK machine(`imx8mm-lpddr4-evk`)を流用。
   ベンダ [BSP](00-glossary.md#g-bsp) か自前で XPI machine を作れば `imx8mm-lpddr4-evk` 依存が消える。

## 未確認・要検証のまま残っている前提

- **DDR は 2GB・EVK 設定で動く**が、温度/個体ばらつきの余裕は未評価。
- **自作 [SPL](00-glossary.md#g-spl) の DDR タイミング**がベンダ(2018.03)と厳密に同一かは未確認
  (両方 training PASS したので実用上は問題無いが)。
- **CAN INT のパッド(SAI5_RXD3=GPIO3_IO24)**は HW ガイドの 40 ピン表からの
  推定。実機で MCP2515 割り込みが上がるかは未検証。
- **LT9611 の電源シーケンス** — mainline binding は vdd/vcc supply 必須。
  今は regulator-fixed でダミー供給。実際の電源制御が要るかは表示検証時に判明。
