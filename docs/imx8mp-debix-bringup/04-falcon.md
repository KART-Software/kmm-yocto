# 04 — Falcon mode 移植(2026-09-01 実機確定)

SPL が U-Boot proper を飛ばして FAT の falcon.itb(ATF + Image + DTB)を直接起動する
構成を 8MP へ移植した。設計・A/B 統合・OTA 委譲は 8MM と同一
([../imx8mm-xpi-bringup/08-falcon.md](../imx8mm-xpi-bringup/08-falcon.md))。
本書は **8MP(NXP uboot-imx lf_v2024.04)固有の差分と落とし穴**の確定記録。

実測結果: 電源 ON → GUI(kmm READY)**約 6.0 秒**
(SPL+env ~1.0s / falcon.itb 35MB ロード 0.86s / kernel 1.3s / userspace→kmm READY 2.8s)。
SPL の eMMC は **HS400 Enhanced Strobe @200MHz**(`debix-falcon.cfg` の
`CONFIG_SPL_MMC_HS400(_ES)_SUPPORT` + 高速 pinctrl の bootph を足す 0003 パッチ。
SPL 用 DT の usdhc3 には mmc-hs400-1_8v / enhanced-strobe が元から付いている)。
これでロードは 1.54s → 0.86s になったが、proper の fatload が同一ファイルを
112ms で読むのに対しまだ ~8 倍遅い(SPL のロード経路のオーバーヘッド、未解明 —
open-issues 参照)。falcon 発動時のシリアルは

```
U-Boot SPL 2024.04-imx_v2024.04_6.6.52-2.2.0+...
Falcon: ua=0 bos=1
Falcon: shim@40200000 fdt@43100000 kernel@40400000
NOTICE:  BL31: v2.10.0 ...        ← proper のバナー無しでカーネルへ
```

## 構成要素

| ファイル | 役割 |
|---|---|
| `kas/imx8mp-falcon.yml` | u-boot-imx への cfg/パッチ注入 + falcon.itb 等の boot files 配置 |
| `meta-kart/recipes-bsp-imx/u-boot/files/debix-falcon.cfg` | SPL_OS_BOOT 系 config(下記) |
| `.../files/0002-imx8mp-debix-falcon-mode.patch` | SPL コード(下記 3 ファイル) |
| `meta-kart/recipes-bsp-imx/kart-falcon-itb/` | falcon-a/b.itb・u-boot.itb・args 生成(8MM と共通レシピ、8MP は DT 無効化焼き込みが追加) |

パッチの中身(`0002-imx8mp-debix-falcon-mode.patch`):

- `board/freescale/imx8mp_evk/spl.c` —
  `spl_board_boot_device()` を BOOTROM → `BOOT_DEVICE_MMC2` に(FAT 経路へ)。
  `spl_start_uboot()`(デッドマンスイッチ、後述)、`kart_emit_bl33_shim()`(8MM と
  同一の 8 命令 BL33 シム)、`spl_perform_fixups()`(/memory fixup + シム設置)、
  `board_spl_fit_buffer_addr()`(落とし穴①対策)
- `arch/arm/mach-imx/mmc_env.c` — SPL フェーズは env dev=1 固定
  (SPL の DM には bootph 付き usdhc が 2 台しか居らず eMMC は dev1。ROM_SW_INFO 由来の番号とずれる)
- `env/mmc.c` — save フックのガードを `CONFIG_IS_ENABLED(SAVEENV)` に変更
  (NXP ツリーは `!CONFIG_SPL_BUILD` で SPL の env 書込を落としている。デッドマンに必要)

## メモリマップ(SPL falcon 時)

| アドレス | 用途 | 決め方 |
|---|---|---|
| 0x970000 | BL31(OCRAM) | imx-atf BL31_BASE、imx-boot の ATF_LOAD_ADDR と一致 |
| 0x40200000 | BL33 シム | ATF PLAT_NS_IMAGE_OFFSET(ATF は bl31_params を無視してここへ跳ぶ) |
| 0x40400000 | kernel Image | falcon.its の load/entry。**CONFIG_SYS_LOAD_ADDR と同値な点が落とし穴①の温床** |
| 0x43000000 | args(ダミー) | CONFIG_SPL_PAYLOAD_ARGS_ADDR |
| 0x43100000 | DTB | falcon.its の fdt load |
| 0x48000000 | FIT メタデータ退避 | 落とし穴①対策(パッチで固定) |
| 0x4A000000 | SPL ヒープ | 落とし穴②対策(cfg で移動) |

## 落とし穴(すべて実機で踏んで特定)

### ① FIT メタデータバッファがカーネルの射程内に置かれる

SPL の FIT メタデータ(目次)置き場は `spl_get_fit_load_buffer()` = **ヒープに
malloc、失敗時は `spl_get_load_buffer(0)` = CONFIG_SYS_LOAD_ADDR(0x40400000)に
フォールバック**(common/spl/spl_fit.c)。ヒープは 0x42200000(②参照)、
フォールバック先はカーネルのロード先そのもの — **どちらに転んでも
カーネル 35MB(0x40400000〜~0x42720000)の射程内**で、loadables のコピー中に
メタデータ(ctx->fit)自身が上書きされる。目次が壊れると DTB ノードが引けず
fdt_addr=NULL → fixups が素通り → **シム未設置**のまま BL31 → 0x40200000(ゴミ)に
跳んで即リセット。
→ `board_spl_fit_buffer_addr()`(weak)を板側で 0x48000000 固定にし、malloc の
成否ともヒープ位置とも無関係な決定的配置にして解決(②のヒープ移動と両輪)。

### ② SPL の DRAM ヒープがカーネル Image に踏まれる

imx8mp_evk_defconfig は `CONFIG_SPL_CUSTOM_SYS_MALLOC_ADDR=0x42200000`(+0x80000)。
これは 0x40400000 + 30MB で、**Image(35.4MB)のロード範囲内**。FAT ドライバの
管理構造がヒープに居るため、読み込みが 30MB を超えた瞬間に自壊してリセットする。
8MM で動いていたのは Image が 30MB 未満だった偶然(8MM レシピの
「SPL heap 0x42200000 と衝突しないこと」コメントが伏線だった)。
→ `CONFIG_SPL_CUSTOM_SYS_MALLOC_ADDR=0x4A000000` へ移動して解決。

### ③ proper のヒューズ由来 DT fixup を素通しする

U-Boot proper は `ft_system_setup`(arch/arm/mach-imx/imx8m/soc.c、
https://github.com/nxp-imx/uboot-imx の lf_v2024.04)で**ヒューズを読み、
非搭載 IP の DT ノードを無効化してから**カーネルに渡す。i.MX8MP **Quad Lite** では
VPU(g1/g2/vc8000e + blk-ctl)と NPU(vipsi)が該当。falcon はこれをスキップする
ため、カーネルが存在しない IP を叩いて `imx-pgc ... failed to command PGC` を連発し、
galcore(GPU/NPU 統合ドライバ)が init 失敗 → /dev/galcore 不在 → weston 起動不能
になる。
→ ハード構成は製品で固定なので、**kart-falcon-itb がビルド時に該当ノードを
status=disabled で焼き込む**(`FALCON_DTB_DISABLE_NODES:imx8mp-debix`)。
リストは実機の `/sys/firmware/fdt` を proper ブートと falcon ブートで採取して
diff した実測値。proper のリストにある `pgc/power-domain@19〜22` は NXP ベンダー
カーネルの番号付けで、fslc(メインライン系)DTB には存在しない(proper でも
NOTFOUND で素通り)。fslc 側で実際に失敗し続けるのは `power-domain@8` なので
それを無効化している。

## デッドマンスイッチ(8MM に無い追加)

`spl_start_uboot()` の判定:

1. `upgrade_available=1`(OTA 試行中)→ proper(bootcount/altbootcmd に任せる。8MM と同じ)
2. `boot_os` が **yes でなければ proper**(デフォルト安全側)
3. falcon 発動時は **ジャンプ前に `boot_os=no` を書き戻す**(SPL_SAVEENV + SPL_MMC_WRITE)

falcon 経路がどこでクラッシュしても次回は必ず proper に落ちるため、
**ブートローダ実験でロックアウトしない**(今回のデバッグ中、毎クラッシュ後に
自動復帰することを繰り返し実測)。起動成功時の再アームは `fw_setenv boot_os yes`。

## リカバリ経路(SPL/imx-boot を壊した場合)

falcon SPL は SDPV を受けないため、UUU 経路は stock 退避版
`local/recovery/imx-boot-imx8mp-stock` + `local/recovery/debix-recover.uuu` を使う
(DIP 001)。8MP は ROM プロトコルが **SDPS**。`.uuu` スクリプトは
**先頭に `uuu_version` 行が無いとブートイメージと誤認される**(実測)。
stock U-Boot の `ums 0 mmc 2` は DEBIX では USB ガジェットが列挙されないことがあり、
その場合は **`dhcp` + `tftpboot` + `mmc write`**(母艦の tftpd)が確実:

```
setenv autoload no; dhcp                 # PHY オートネゴに 10 秒以上かかることがある
setenv serverip <母艦 IP>                # dhcp が serverip をルーターに上書きするので後から
tftpboot 0x40400000 <imx-boot>
crc32 0x40400000 <size>                  # 母艦側の crc32 と突き合わせてから書く
mmc dev 2; mmc write 0x40400000 0x40 0xB5A
```

Linux が生きていれば `dd of=/dev/mmcblk2 bs=512 seek=64` + 読み戻し md5 照合が最速。

## 検証手順

```bash
ssh root@<board> "fw_setenv boot_os yes"      # 1 回分アーム
# 電源サイクル → シリアルに Falcon: 行、proper バナー無しでカーネルへ
ssh root@<board> 'systemctl is-active weston kmm can0-up; dmesg | grep -c "failed to command PGC"'
# → 全 active / 0 件
```
