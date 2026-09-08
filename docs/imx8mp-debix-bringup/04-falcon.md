# 04 — Falcon mode 移植(2026-09-01 実機確定)

SPL が U-Boot proper を飛ばして FAT の falcon.itb(ATF + Image + DTB)を直接起動する
構成を 8MP へ移植した。設計・A/B 統合・OTA 委譲は 8MM と同一
([../imx8mm-xpi-bringup/08-falcon.md](../imx8mm-xpi-bringup/08-falcon.md))。
本書は **8MP(NXP uboot-imx lf_v2024.04)固有の差分と落とし穴**の確定記録。

実測結果: 電源 ON → GUI(kmm READY)**約 5.2 秒**
(SPL+DDR ~0.6s / env+デッドマン 0.43s / falcon.itb 35MB ロード **0.19s** /
kernel 1.3s / userspace→kmm READY 2.7s)。
SPL の eMMC は **HS400 Enhanced Strobe @200MHz**(`debix-falcon.cfg` の
`CONFIG_SPL_MMC_HS400(_ES)_SUPPORT` + 高速 pinctrl の bootph を足す 0003 パッチ。
SPL 用 DT の usdhc3 には mmc-hs400-1_8v / enhanced-strobe が元から付いている)。
これで生の読みは 119ms(295MB/s)になる。もう一つの支配項が落とし穴④
(35MB の無駄 memmove)で、除去後にロード合計 0.19s。falcon 発動時のシリアルは

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
| `meta-kart/recipes-bsp-imx/falcon-itb/` | falcon-a/b.itb・u-boot.itb・args 生成(8MM と共通レシピ、8MP は DT 無効化焼き込みが追加) |

パッチの中身(`0002-imx8mp-debix-falcon-mode.patch`):

- `board/freescale/imx8mp_evk/spl.c` —
  `spl_board_boot_device()` を BOOTROM → `BOOT_DEVICE_MMC2` に(FAT 経路へ)。
  `spl_start_uboot()`(デッドマンスイッチ、後述)、`emit_bl33_shim()`(8MM と
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
| 0xBFE00000 | SPL スプラッシュ FB(2MB) | 0005 パッチ SPLASH_FB_ADDR。dts の reserved-memory `splash-fb@bfe00000`(no-map)でカーネルから隠す |

### DRAM バンクと /memory(2026-09-08 修正)

DEBIX D4E32 の 4GB は **3GB @0x40000000 + 1GB @0x100000000**(U-Boot の PHYS_SDRAM /
PHYS_SDRAM_2、SoC のアドレス空間で 0xC0000000 まで + 4GB 境界の上)。falcon 経路では
SPL の `spl_perform_fixups()` が /memory を書くが、8MP スプラッシュパッチはこれを
「2GB-2MB @0x40000000 + 2GB @0x100000000」と決め打ちしていた(8MM の 2GB 設計の名残)。
結果、カーネルは存在しない 0x140000000〜0x17FFFFFFF の 1GB を RAM と信じ、実在する
0xC0000000〜0xFFFFFFFF の 1GB を使わず、memtester 2GB がその領域に触った瞬間にバスが
止まり WDT → PMIC 経由リセット(SRSR は POR のみ、シリアルに panic なし、DP100 の
出力は 5.106V/0.5A で無傷)。通常運用ではメモリ使用量が少なく踏まないが、OTA の
rootfs dd(1.5GB のページキャッシュ)で ssh が切れた open-issues #12 も同根の疑い。
U-Boot proper 経路は `fdt_fixup_memory_banks` が正しく 3GB+1GB を書くため無症状だった。

修正: SPL は `dram_init_banksize()` の bi_dram(3GB+1GB)で /memory を書き、FB の
2MB は dts の reserved-memory(no-map)で隠す(旧 `mem=2042M` は 8MP では廃止、
falcon-itb の `SPLASH_FB_HIDE_ARG`)。修正後の `/proc/iomem` は 0x40000000〜0xFFFFFFFF
と 0x110000000〜0x13FFFFFFF(0x100000000〜 の 256MB は EVK dts の gpu_reserved)、
memtester 2000M 1 周(33 分)エラー 0・リセットなし。0xC0000000〜0xFFFFFFFF の 1GB は
EVK dts の `linux,cma`(960MB)が占めるが、VPU/GPU 不使用なので縮められる(未着手)。

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
→ ハード構成は製品で固定なので、**falcon-itb がビルド時に該当ノードを
status=disabled で焼き込む**(`FALCON_DTB_DISABLE_NODES:imx8mp-debix`)。
リストは実機の `/sys/firmware/fdt` を proper ブートと falcon ブートで採取して
diff した実測値。proper のリストにある `pgc/power-domain@19〜22` は NXP ベンダー
カーネルの番号付けで、fslc(メインライン系)DTB には存在しない(proper でも
NOTFOUND で素通り)。fslc 側で実際に失敗し続けるのは `power-domain@8` なので
それを無効化している。

### ④ mkimage の 4B 詰めが 35MB の無駄 memmove を生む

HS400 化後もロードに 0.86s かかり、計装で内訳を取ると **FAT 読み自体は 119ms
(295MB/s)で、残り 0.72s は読み込み後の memcpy** だった。機序:
`mkimage -E` は external data を 4B 詰めで並べるため、2 個目以降の blob の
ファイル内 offset が SPL の読みバッファ境界(bl_len=64)に乗らない。spl_fit は
「境界に丸めた位置から読み → `memcpy(load_ptr, load_ptr+ズレ, 全長)`」で補正する
ので、カーネル 35MB 全体のずらしコピーが発生する(SPL は dcache 無効なので
CPU コピーが ~50MB/s しか出ない)。
→ 二段で解決: falcon-itb が **falcon.itb の blob を 64B の倍数へゼロ
パディング**(offset が常に境界に乗る)+ u-boot 側 0004 パッチで **src == dst の
memcpy をスキップ**(mainline の後年修正と同型)。ロード合計 0.90s → 0.19s。

**注意: u-boot-nodtb.bin だけは絶対にパディングしない。** U-Boot proper は
「自分の末尾(_end)直後に control DTB」の前提で DTB を探すため、パディングで
隙間ができるとコンソール初期化前に無音ハングし、**デッドマンの落ち先(proper)が
丸ごと死ぬ**(2026-09-02 実測 — boot_os=no と組み合わさり遠隔復旧不能になった)。
教訓: **フォールバック経路は、その構成物を触るたびに回帰テストする**。

## デッドマンスイッチ(8MM に無い追加)

`spl_start_uboot()` の判定:

1. `upgrade_available=1`(OTA 試行中)→ proper(bootcount/altbootcmd に任せる。8MM と同じ)
2. `boot_os` が **yes でなければ proper**(デフォルト安全側)
3. falcon 発動時は **ジャンプ前に `boot_os=no` を書き戻す**(SPL_SAVEENV + SPL_MMC_WRITE)

falcon 経路がどこでクラッシュしても次回は必ず proper に落ちるため、
**ブートローダ実験でロックアウトしない**(今回のデバッグ中、毎クラッシュ後に
自動復帰することを繰り返し実測)。

再アーム(チケット補充)は **falcon-rearm.service**
(`meta-kart/recipes-bsp-imx/falcon-rearm/`、falcon ビルドのみ
kas/imx8mp-falcon.yml が IMAGE_INSTALL)が担う: 起動早期(~3s、basic 付近)に
**無条件で** `fw_setenv boot_os yes`。設計判断:
- 無条件補充の帰結 = 補充ミス(電源断等)は次の proper 起動で自動回復。
  falcon.itb が恒久的に壊れている場合のみ毎ブート ~2.5s のクラッシュ迂回が
  挟まる(必ず proper で完全起動はする)— シンプルさ優先で許容
- 検討した代替: 経路限定補充(proper では補充しない)は補充ミス 1 回で健全
  falcon を永久喪失、連続失敗カウンタは両立するが複雑 — 採用見送り。
  経路判定が要る場合は `/proc/device-tree/chosen/u-boot,version` の有無で可能
  (proper のみ注入、実機確認済み)
- 実行を GUI(kmm READY)まで遅らせない — falcon 経路の健全性はカーネルが
  userspace に到達した時点で証明済み(GUI 故障は proper でも同じに壊れる)
- OTA 試行中(ua=1)は SPL が boot_os を見ずに proper へ行くため干渉なし

手動アームなし 2 連続コールドブートで自律サイクル(falcon → 補充 → falcon)を
実機確認済み(2026-09-02)。

### 落ち先(proper)が死んでいた — スプラッシュ稼働中ドメインの引き継ぎ(2026-09-07)

**症状**: スプラッシュ中(SPL が `boot_os=no` を書いてから falcon-rearm が `yes` を
書き戻すまでの ≈1.5s)に電源断すると、次回から proper 経路になるが、その proper
経路で**カーネルが console 切替直後(≈0.93s)に停止**(RCU stall、CPU2 の pid 1 が
PC=0、`quiet` だと "Starting kernel ..." の後に無音)。5/5 再現。デッドマンの落ち先が
死んでいたので、電源断のタイミング次第で手動介入(`setenv boot_os yes; saveenv`)まで
二度と起動しなかった。

**原因**: SPL スプラッシュは HDMIMIX / HDMI_PHY の電源ドメインと HDMI blk-ctrl の
クロック/リセット、PHY PLL を立ち上げたまま proper に渡す(`spl_splash_quiesce()` は
LCDIF と PHY の電源だけ落とす)。falcon 経路はカーネルに `splash-active` を渡して
養子縁組(0010〜0013)させるが、proper 経路には渡していなかったため、素の
imx8mp-blk-ctrl がこの「稼働中ドメイン」を再シーケンスしてバスごと固まる。
切り分け: DT で HDMI blk-ctrl ノードだけ無効化すると起動(LCDIF / dw-hdmi / PHY /
DRM master の無効化では不変)、`pd_ignore_unused clk_ignore_unused` では不変、
`splash-active` を足すと 3/3 起動して GUI も出る。カーネル/DTB は falcon.itb の
中身と同一、DDR(mtest)と DMA(領域 crc の時間差)は異常なし。
フォールバック経路の最終確認は 09-01 で、takeover(09-02)以降は未検証だった。

**修正**: U-Boot proper の `ft_board_setup`(`0006-imx8mp-debix-proper-splash-adopt.patch`、
`kas/imx8mp-splash.yml` で注入)が GPC PU_PWRHSK(0x303a0190)bit13 = SPL の HDMIMIX
ADB400 handshake 要求を見て、立っていれば `/chosen splash-active` を立てる。
u-boot.itb(falcon-itb が組む proper FIT)の差し替えだけで済み、imx-boot の
書き換えは不要。SPL の quiesce はそのまま(表示は止まった状態から養子縁組経路で
再初期化され、GUI が出る)。

**検証(2026-09-07)**: `fw_setenv boot_os no` → 電源断入 → SPL → proper → extlinux の
実経路で 3/3 ログイン(電源→login 11s)、weston/kmm active、GUI 表示、falcon-rearm が
`boot_os=yes` を自動補充。

**電源断スイープ(2026-09-07)**: 電源投入 t 秒後に電源断 → 3s 後に再投入 → 次の起動が
GUI(kmm READY、weston/kmm active)まで到達し `boot_os=yes` に再アームされるかを、DP100 と
シリアルで自動判定。t = 0.61〜6.1s の 19 点(SPL のデッドマン env_save 前後 0.61/0.62/0.75、
falcon.itb ロード、カーネル、userspace、falcon-rearm 前後 2.2〜3.5、GUI 後)で **19/19 回復**。
0.6〜3.5s の断は次回 proper 経路(bos=0)で起動して自動再アーム、3.9s 以降は falcon 経路。
0.6s 未満(BootROM / DDR init / SPL の env 読み込み〜デッドマン書き込み中)は
ON→OFF を 1 プロセス内で行う経路で 7 点(0.05 / 0.15 / 0.25 / 0.35 / 0.45 / 0.55 / 0.60s、
0.60s は "Saving Environment" の最中)、**7/7 回復**(いずれも次回 falcon 経路、env 破損なし)。
合計 26 点で不回復ゼロ。ツール: scratchpad `powercut-sweep.py`(DP100 + シリアル + journal)。

**教訓(再掲)**: フォールバック経路はその構成物(SPL / proper / カーネル / DT)を
触るたびに `fw_setenv boot_os no` + 電源断入で回帰テストする。falcon が健全なほど
proper 経路は走らず、壊れていても気付かない。

### OTA と SPL/proper ↔ カーネル契約の整合(2026-09-07 確定)

SPL は **MBR の bootable フラグが立った BOOT パーティション**から u-boot.itb と
falcon.itb を読む(ab-commit がフラグを新スロットへ移す)。したがって try 中
(`upgrade_available=1`、SPL は proper 経路に落とす)は **旧スロットの u-boot.itb** が
新スロットのカーネルを起動する。u-boot.itb と falcon.itb を新スロットの BOOT に
コピーする OTA 手順は、commit 後にしか効かない。

SPL/proper とカーネルの間の契約(`/chosen splash-active` のプロパティ名、logo.bin の
マジック "LOGO")を変える更新では、この非対称が try 起動を殺す:
名前の一掃(2026-09-07)で実際に踏んだ(新 SPL + 旧カーネルは falcon 経路で固まりデッドマンで
proper に落ち、try は旧 u-boot.itb が旧プロパティ名を立てて新カーネルが養子縁組せず
固まった → bootlimit で旧スロットへ復帰)。手順は次のとおり:

1. `uboot-update <imx-boot>` で SPL を更新(A=新、B=前版)
2. 旧スロットの BOOT(/boot、ro マウント)へ新 u-boot.itb をコピー
3. OTA(try → commit)。commit 後は falcon.itb/u-boot.itb とも新スロットのもの
4. もう一度 OTA して旧スロットも新イメージにする(フォールバック先を整合させる)

U-Boot の A/B 環境変数名(`ab_slot` / `ab_fallback_slot` / `ab_boot` / `ab_bootpart` /
`ab_mmcdev`)を変えた更新も同類: 変数は eMMC の saved env に永続で、
uboot-env.bin(既定 env)は焼き直し時にしか適用されない。旧名で稼働中のデバイスは
新ツール(ab-commit/ab-status は新名を読む)を使う前に `fw_setenv -s` で ab-env.txt
相当(bootcmd / altbootcmd / ab_* 一式)を saved env に書き込み、旧変数は
`fw_setenv <旧変数名>`(値なし)で消す。

契約を変えない通常の OTA では不要。

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
