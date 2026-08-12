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
2. **HDMI 表示 — 完了 (2026-08-11)**。[weston](00-glossary.md#g-weston)/[kmm](00-glossary.md#g-kmm) の GUI 表示を実機確認
   (開発用 800x480 パネル + TFP401、コールドブート再現込み)。
   **LT9611 は低ピクセルクロックで使用不能**なため、「108MHz ラスタに
   800x480 アクティブだけ置く」カスタムモードで解決
   ([04-pitfalls](04-pitfalls.md) #17)。weston.ini (mx8mm override) に焼き込み済み。
   CAN 実トラフィック (142fps) + GUI 更新の同時負荷も実測済み: CPU 33%
   (うち kmm 21% — 当時 1080p 描画。現 800x480 描画では大幅減の見込み)。
3. **userspace→GUI の実測 — 完了 (2026-08-11)**。未最適化の初回実測は
   電源→GUI ≈13s (SPL+U-Boot 2.13s / カーネル→userspace 4.42s /
   userspace→GUI 5.86s)。GPU は etnaviv (GC600) ハードレンダリング、
   DVFS 1.8GHz まで有効。

   **最適化 2 ラウンドで ≈6.3s まで短縮 (2026-08-11、コールドブート実測)**:
   - fbdev エミュレーション無効 (lcdif probe 内の初回モードセット =
     EDID 読取+500ms settle がカーネル起動から消える): カーネル 4.42→2.28s
   - cmdline `quiet` (115200 への printk 垂れ流し停止): カーネル→0.67s
   - EDID をファームウェアファイル供給 (`drm.edid_firmware=`。LT9611 の
     DDC 経由読取 1.1〜1.4s を全廃): weston 1.57→0.53s
   - lt9611 settle 500ms→100ms (0003 パッチ、video check で安定裏取り)
   - resolved の sysinit preset 再作成バグ修正 (timesyncd と同じ
     IMAGE_PREPROCESS 方式。**RPi5 イメージにも効く**): sysinit -0.5s
   内訳 (現在): SPL+U-Boot 2.13s / カーネル→userspace 0.67s /
   userspace→GUI 3.28s (kmm READY monotonic 3.95s)。**RPi5 の 8.59s を逆転**。
   次の伸びしろ: SPL+U-Boot 2.13s (Falcon Mode 領域)、basic.target まで
   の 2.2s (eMMC デバイス settle ~2s が主)、kmm 0.43s。
4. **eMMC への本焼き — 完了 (2026-08-11 実機実証)**。再現手順は独立した手順書
   [06-emmc-flash.md](06-emmc-flash.md) に整理済み。初回実証は bring up で
   実績のある **netboot Linux から dd** で実施(下記)。その後 `ums` の実機検証
   (2026-08-12)を受けて、手順書の正規経路は **UMS 直書き**(uuu 1 周 +
   bmaptool、TFTP/NFS 不要)に更新し、netboot 経路はリカバリ用として温存:
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

   **OTA A→B フルサイクルも実機検証済み (2026-08-11)**: `ota-update.sh` で
   slot B 書込 → fw_setenv 試行 → tryboot → `kart-ab-commit` (読み戻し検証) →
   再起動で B 恒久ブート、まで完走。**フォールバックも実機実証**: 破壊した
   スロットへの試行が rootwait 停止 → 60s watchdog リセット → bootcount 超過 →
   `altbootcmd` が「bootlimit reached, falling back」を表示して旧スロットへ
   自動復帰 (無人復帰まで 84 秒、シリアルで全捕捉)。
   発見バグ: libubootenv の `fw_setenv -s` はスペース区切りを黙って無視する
   ([04-pitfalls](04-pitfalls.md) #18)。既知の制限: DHCP 環境では新スロットの
   machine-id 変化で IP が変わり ota-update.sh の復帰待ちがタイムアウトする
   (実際は成功している。tailscale 名運用なら影響なし)。
   **U-Boot A/B も実機検証済み・最終形完成 (2026-08-12)**: ROM の inline
   フォールバック (A copy の IVT 破壊 → SIT 経由で B copy を同一起動内で選択、
   イベントログ 0x51 で裏取り) を確認。ただし **PSB を入力に使う「B の試し
   起動」は 8MM では不可能と判明** (SRC_GPR10 は全リセットで消える) — 当初の
   kart-uboot-try/-commit は廃止し、「**B 面に一つ前の版を残す**」方式に再設計:
   - ツール: `kart-uboot-update` (A→B 退避 → 新版→A) / `kart-uboot-rollback`
     (前版へ戻す) / `kart-uboot-selfheal` (boot 時 systemd oneshot、
     フォールバックを検出したら自動 rollback) / `kart-uboot-status`
     (起動元は ROM イベントログ判定)
   - 安全機構: 全書き込み header-last (IVT を最後に。途中電源断は必ず
     「IVT 不正」に落ちもう片方で起動) / A 不正時は退避スキップ (壊れた A を
     複写して唯一の健全コピーを潰す事故を防止) / フォールバック起動中の
     update 拒否 / flock (`/run/kart-uboot.lock`) で相互排他
   - 検証: DP100 で各局面に実電源断 (退避中/A書込直後/本体書込後IVT前/
     rollback中) を当てて全て再実行一発で収束。統合検証は最終イメージを
     OTA → A破壊 → コールドブート → selfheal がサービスとして自動修復
     (journal に全証跡) → 再起動でプライマリ起動、まで**人間の介入ゼロ**で完走
   - 設計の全経緯・限界 (IVT 正当だが起動しないバイナリは救えない等) は
     [04-pitfalls](04-pitfalls.md) #19 と
     [../imx8mm-migration-design.md](../imx8mm-migration-design.md) の U-Boot A/B 節
   残: bootcmd 失敗時に U-Boot プロンプトへ落ちるケースの `; reset`
   ハードニング検討。「ソフト切替できる本物の A/B」が要るなら SPL セレクタ化
   (Falcon Mode の前提工事と同内容)。
5. **XPI 用 machine の正式化 — 完了 (2026-08-12)**。
   `meta-kart/conf/machine/imx8mm-xpi.conf` を新設し、EVK machine
   (`imx8mm-lpddr4-evk`)への依存を解消 (SoC/boot 基盤の `imx8mm-evk.inc`
   のみ継承)。kas のパッチワーク吸収・DTB リネームトリック廃止
   (extlinux FDT 直指し)・deploy dir / hostname の `imx8mm-xpi` 化まで
   実機 OTA で検証・commit 済み。tailscale 名も hostname 追従で変わる点に注意。

## 未確認・要検証のまま残っている前提

2026-08-12 のベンダ BSP 監査([07-vendor-bsp-audit](07-vendor-bsp-audit.md))で
大半を解消した。現状:

- ~~自作 SPL の DDR タイミングがベンダと同一か~~ → **解消**: ベンダ 2GB 用は
  NXP 純正 EVK 値そのままで、fslc 2025.01 とレジスタ全一致([07](07-vendor-bsp-audit.md) §1)。
  温度/個体ばらつきの実測マージンだけは未評価(ベンダ出荷品と同等、までは確定)。
  **1GB 個体は別テーブル必須**(Longsys 用再生成値が BSP にある)。
- ~~LT9611 の電源シーケンス~~ → **解消**: 制御可能なレールは存在せず常時給電。
  regulator-fixed ダミーが正しいモデル([07](07-vendor-bsp-audit.md) §2)。
- **CAN INT のパッド(SAI5_RXD3=GPIO3_IO24)は未検証のまま**。ベンダ DT は
  無言(パッドが空いていることだけ確認)、回路図バイナリは読めず。
  確定は MCP2515 割り込みの実動確認で。
- 監査で新たに判明した食い違い(PHY リセット GPIO、usbotg2 欠落、
  PMIC compatible、AM1805 RTC)は [07](07-vendor-bsp-audit.md) §3 の採用候補リストを参照。
