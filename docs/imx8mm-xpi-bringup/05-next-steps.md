# 05 — 残課題と直し方

login まで到達したが未完の 2 点と、その先。**どれも実機なしで [DTS](00-glossary.md#g-dts)/構成を
直して再ビルド → 次の netboot で確認できる。**

## A. NFS root + networkd の完全分離(netboot 用)

現状は [NFS](00-glossary.md#g-nfs) ディレクトリに手で mask を投入している([03](03-boot-flow.md))。
これを **netboot オーバーレイに正式に組み込む**。実機の [eMMC](00-glossary.md#g-emmc) 起動イメージには
入れない(ローカル root では networkd が必要)。

やること:
- `kas/imx8mm-netboot.yml` に、[rootfs](00-glossary.md#g-rootfs) へ networkd/wait-online を mask する
  ROOTFS_POSTPROCESS を追加(netboot ビルド時のみ)。
- あるいは bootargs に `systemd.mask=systemd-networkd.service` 等を渡す方式でも可。
- 注意: login は出たが**その後ネットワーク断**が残っている。mask が
  networkd だけでは不十分な可能性(resolved や別経路が eth0 に触れる)。
  次回は `systemd.log_level=debug` で 16 秒以降の全ユニットを追い、
  eth0 を触る犯人を全部止める。

## B. pinctrl の deferred probe(LT9611 / CAN / backlight)

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

**症状の本質:** `imx8mm-xpi-kart.dts` が参照している [pinctrl](00-glossary.md#g-pinctrl) グループ
(`lt9611grp` / `ecspi2csgrp` / `backlightgrp` / `pmicirqgrp` / `pcie0grp`)が
**iomuxc ノードに定義されていない、または名前が食い違っている**。
DTS で `pinctrl-0 = <&pinctrl_xxx>` と書いたグループの実体が無いと、
supplier(pinctrl)が ready にならず probe が永久保留になる。

直し方:
1. `imx8mm-xpi-kart.dts` の `&iomuxc` に、参照している全グループを定義。
   今回定義済み: `pinctrl_i2c4` / `pinctrl_lt9611` / `pinctrl_ecspi2` /
   `pinctrl_ecspi2_cs` / `pinctrl_can_int` / `pinctrl_usdhc3*`。
   → だが実機ログは `lt9611grp` `ecspi2csgrp` `backlightgrp` 等の**別名**を
   待っている。これは **ベース DTS(imx8mm-evk.dts)側のノードが元々参照している
   グループ名**で、我々の include 方法(`#include "imx8mm-evk.dts"`)で
   EVK のノード(backlight, pmic irq, pcie 等)ごと引き継いだため。
2. **対処 2 択:**
   - (a) EVK から引き継いだ不要ノード(backlight/pcie/typec 等 XPI に無いもの)を
     `/delete-node/` で消す。PCIe は XPI に引き出されていないので確実に削除。
   - (b) 引き継ぐなら、それらが参照する pinctrl グループも定義する。
   XPI で使うのは [LT9611](00-glossary.md#g-lt9611) / [CAN](00-glossary.md#g-can) / eMMC / GbE のみなので **(a) で不要ノードを
   削る**のが素直。backlight は [MIPI-DSI](00-glossary.md#g-mipi-dsi) パネル直結時のみ必要。
3. `pmicirqgrp` は [PMIC](00-glossary.md#g-pmic)(BD71847)の割り込み。EVK ノードが参照。PMIC は使うので
   グループ定義を移植するか、割り込み無し構成にする。

## C. その先(A/B が通ってから)

1. **CAN 実機確認** — MCP2515 HAT を挿し、`ip link set can0 up type can bitrate 1000000`
   → `candump`。DTS の CAN INT(GPIO3_IO24)と ECSPI2 配線の検証。
2. **HDMI 表示** — LT9611 が connect したら [weston](00-glossary.md#g-weston)/[kmm](00-glossary.md#g-kmm) が画を出すか。
   `/sys/class/drm/card0-HDMI-A-1/status`。
3. **userspace→GUI の実測** — 移行判断で唯一未実測の値。RPi5 の [UART](00-glossary.md#g-uart) 計測
   ハーネス(`docs/boot-timing.md`)をそのまま適用。A53 + [etnaviv](00-glossary.md#g-etnaviv) での weston+kmm
   起動時間が移行の損益を決める。
4. **eMMC への本焼き** — netboot で全部通ったら、[UUU](00-glossary.md#g-uuu-universal-update-utility) の `FB:`(fastboot)経路 or
   `ums` で eMMC に wic を書く。A/B レイアウト(`kart-imx8mm-emmc-ab.wks`)は
   実装済み([../imx8mm-migration-design.md](../imx8mm-migration-design.md))。
   boot0 起動 vs ユーザー領域起動の切り替え(`mmc partconf`)に注意。
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
