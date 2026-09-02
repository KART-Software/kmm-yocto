SUMMARY = "Falcon boot FITs (ATF + kernel + DTB) and U-Boot proper fallback FIT"
DESCRIPTION = "SPL が直接ロードする falcon.itb をスロット毎 (root=p5/p6 焼き分け) に \
生成し、OTA 試行時に SPL が読む u-boot.itb (proper フォールバック) も組む。\
設計は docs/imx8mm-xpi-bringup/08-falcon.md。kas/imx8mm-falcon.yml から使う。"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

DEPENDS = "u-boot-tools-native dtc-native"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# m4-fw.bin = data-logger-zephyr (https://github.com/KART-Software/data-logger-zephyr) の
# apps/can-gw を west でビルドした Cortex-M4 バイナリ (zephyr.bin) を
# prebuilt 同梱。KART_M4 のとき m4-fw.img に包んで boot パーティションへ配る。
#   provenance: data-logger-zephyr commit bcab881 (rsc_table を 0xB80FF000 に
#   自己 publish する attach 対応込み。SPL/BL31 先住起動 = Linux attach で必須)
SRC_URI = "file://m4-fw.bin"

# 8MP SPL スプラッシュのロゴ (単一ソースは u-boot 側の kart_splash_logo.h)。
# ロゴを SPL に埋め込むと ROM のブートイメージ上限 (docs 04-falcon.md ⑤) を
# 超えるため、boot パーティションの logo.bin として配りファイル読みする。
# ヘッダ: "KLGO" + w/h/x/y (各 LE32) + 1bit マスク。
FILESEXTRAPATHS:prepend := "${THISDIR}/../u-boot/files:"
SRC_URI:append:imx8mp-debix = " file://kart_splash_logo.h"

# SPL スプラッシュのロゴは u-boot 側 (SPL) に 1bit マスクで埋め込み済み
# (scripts/gen-splash-raw.py → kart_splash_logo.h、0010 パッチ)。falcon.itb に
# ロゴ画像は不要。KART_SPLASH は splash ビルドの印 (kas/imx8mm-splash.yml が "1"):
# mem=2042M と /chosen kart,splash-active を付けるかの分岐に使う
KART_SPLASH ?= ""

# KART_M4 は M4 ビルドの印 (kas/imx8mm-m4.yml が "1")。m4-fw.bin をヘッダ付き
# コンテナ m4-fw.img (magic K4FW + size + CRC32 + version) に包んで deploy し、
# boot パーティションに置く (IMAGE_BOOT_FILES は kas/imx8mm-m4.yml が append)。
# SPL がファイルとして読み検証して DDR ステージングへ、BL31 が TCML コピー +
# SRC 解除で Linux より前に M4 を起動し、Linux は attach する。
# falcon.itb には埋め込まない (M4 更新を Yocto 非依存にするため —
# 設計 docs/imx8mm-xpi-bringup/12-m4-standalone-bin-design.md、実証 10 ④)。
KART_M4 ?= ""

inherit deploy nopackages

COMPATIBLE_MACHINE = "(imx8mm-xpi|imx8mp-debix)"
PACKAGE_ARCH = "${MACHINE_ARCH}"

KART_FALCON_UBOOT_DEPLOY = "u-boot-fslc:do_deploy"
KART_FALCON_UBOOT_DEPLOY:imx8mp-debix = "u-boot-imx:do_deploy"
do_compile[depends] += " \
    virtual/kernel:do_deploy \
    imx-atf:do_deploy \
    ${KART_FALCON_UBOOT_DEPLOY} \
"

# アドレスは U-Boot パッチ (0001-imx8mm-kart-falcon-mode.patch) の
# KART_FALCON_* 定数、および SPL heap (0x42200000) と衝突しないこと
# 8MM: BL31_BASE 0x920000 / 8MP: 0x970000 (imx-atf platform_def.h、imx-boot の
# soc.mak ATF_LOAD_ADDR と一致)
FALCON_ATF_ADDR = "0x920000"
FALCON_ATF_ADDR:imx8mp-debix = "0x970000"
FALCON_KERNEL_ADDR = "0x40400000"
FALCON_FDT_ADDR = "0x43100000"
FALCON_UBOOT_ADDR = "0x40200000"

# extlinux と同じカーネル引数系 (machine conf の UBOOT_EXTLINUX_KERNEL_ARGS を共有)
FALCON_BOOTARGS_COMMON = "console=ttymxc1,115200 ${UBOOT_EXTLINUX_KERNEL_ARGS}"

# falcon は U-Boot proper の ft_system_setup (ヒューズ由来の DT fixup) を通らない。
# proper が実機で無効化しているノード (i.MX8MP Quad Lite = VPU/NPU 非搭載) を
# ビルド時に静的に焼き込む (ハード構成は製品で固定)。放置するとカーネルが
# 存在しない VPU/NPU を叩いて imx-pgc "failed to command PGC" 連発 →
# galcore (GPU/NPU 統合) が死に weston が起動しない (実測 2026-08-31)。
# リストは実機の /sys/firmware/fdt を proper ブートと falcon ブートで
# 採取して diff した実測値 (arch/arm/mach-imx/imx8m/soc.c disable_vpu_nodes 等)
FALCON_DTB_DISABLE_NODES = ""
FALCON_DTB_DISABLE_NODES:imx8mp-debix = "\
    /vpu_g1@38300000 \
    /vpu_g2@38310000 \
    /vpu_vc8000e@38320000 \
    /soc@0/blk-ctl@38330000 \
    /vipsi@38500000 \
    /soc@0/bus@30000000/gpc@303a0000/pgc/power-domain@8 \
"
# 注: proper (NXP U-Boot) の disable_vpu_nodes は pgc power-domain@19〜22 も
# 対象にするが、それは NXP ベンダーカーネル DTS の番号付け。fslc (メインライン系)
# の pgc は @0〜@18 で該当せず (proper でもここは NOTFOUND で素通りしている)。
# 実測でカーネル probe 時から失敗し続けるのは imx-pgc-domain.8 (reg 0x08、
# Quad Lite でヒューズアウトされた VPU 系 mix) なので @8 を無効化する
# machine ごとの素材名 (deploy 上のファイル名の差を吸収)
KART_FALCON_BL31 = "bl31-imx8mm.bin"
KART_FALCON_BL31:imx8mp-debix = "bl31-imx8mp.bin"
KART_FALCON_DTB = "imx8mm-xpi-kart.dtb"
KART_FALCON_DTB:imx8mp-debix = "imx8mp-debix.dtb"
KART_FALCON_NODTB = "u-boot-nodtb.bin"
KART_FALCON_NODTB:imx8mp-debix = "imx-boot-tools/u-boot-nodtb.bin-${MACHINE}-sd"
KART_FALCON_UBOOT_DTB = "u-boot-proper.dtb"
KART_FALCON_UBOOT_DTB:imx8mp-debix = "imx-boot-tools/imx8mp-evk.dtb-sd"

do_compile() {
    cp ${DEPLOY_DIR_IMAGE}/Image ${B}/Image
    cp ${DEPLOY_DIR_IMAGE}/${KART_FALCON_BL31} ${B}/bl31.bin
    cp ${DEPLOY_DIR_IMAGE}/${KART_FALCON_NODTB} ${B}/u-boot-nodtb.bin
    cp ${DEPLOY_DIR_IMAGE}/${KART_FALCON_UBOOT_DTB} ${B}/u-boot-proper.dtb

    # falcon.itb 用 blob を 64B の倍数へゼロパディング。mkimage -E は external
    # data を 4B 詰めで並べるため、2 個目以降の blob の offset が SPL の読み
    # バッファ境界 (bl_len=64) からずれ、spl_fit が「境界に丸めて読み → 全長
    # memmove」に落ちる (dcache 無効の SPL でカーネル 35MB ≈ 0.7s を実測、8MP)。
    # サイズを 64 の倍数に揃えれば offset が常に境界に乗り、u-boot 側
    # 0004 パッチ (同一アドレス memcpy スキップ) と合わせてコピーが消える。
    #
    # 【u-boot-nodtb.bin は絶対にパディングしない】U-Boot proper は「自分の
    # 末尾 (_end) 直後に control DTB が付いている」前提で DTB を探す。SPL の
    # append-fdt は「ロードアドレス + FIT 上のサイズ」に DTB を置くため、
    # パディングすると _end と DTB の間に隙間ができ、proper がコンソール
    # 初期化前に無音ハングする (2026-09-02 実測 — proper 経路が丸ごと死に、
    # デッドマンの落ち先を失って遠隔復旧不能になった)。u-boot.itb 側の
    # 小さな memmove (~1MB、数十 ms) は許容する
    for f in ${B}/Image ${B}/bl31.bin; do
        truncate -s %64 $f
    done

    # SPL スプラッシュ: ロゴは SPL に 1bit マスクで埋め込み済み (u-boot の
    # kart_splash_logo.h + 0010 パッチ) で、SPL が fill 直後・eLCDIF RUN 前に
    # 描く。よって falcon.itb に splash loadable (ロゴ画像) は載せない。
    # 旧方式 (帯 raw を FIT で FB へ直接ロード) は表示 DMA 稼働中の FB 書きが
    # ~4MB/s と激遅く FIT ロードを膨らませていた — RUN 前描画でこれを解消。
    # mem=2042M で FB 領域 (上位 6MB) をカーネルから隠す (reserved-memory の
    # 代わり。fdtput は空プロパティ no-map を作れないため簡潔なこちらを採用)。
    # clk/pd_ignore_unused: SPL が立ち上げた表示クロック/電源ドメインを
    # カーネルの「未使用掃除」から守る (養子縁組パッチ 0004/0005 の補完)
    loadables='"kernel"'
    splash_node=""
    if [ -n "${KART_SPLASH}" ]; then
        splash_args=" mem=2042M clk_ignore_unused pd_ignore_unused"
    else
        splash_args=""
    fi

    # M4 ファーム: falcon.itb には埋め込まず、ヘッダ付きコンテナ m4-fw.img を
    # 生成して boot パーティションに置く (SPL がファイルとして読み検証 →
    # DDR ステージング 0x46000000 → BL31 が TCML コピー + SRC 解除)。
    # ヘッダ: magic "K4FW" + payload長 + CRC32 + version (各 LE32)。
    # 形式は SPL パッチ 0011-imx8mm-kart-spl-m4-file-read と一致必須。
    # version には SOURCE_DATE_EPOCH を入れる (表示用)。
    if [ -n "${KART_M4}" ]; then
        python3 -c "
import struct, zlib
payload = open('${WORKDIR}/m4-fw.bin', 'rb').read()
hdr = b'K4FW' + struct.pack('<III', len(payload), zlib.crc32(payload) & 0xffffffff, ${@d.getVar('SOURCE_DATE_EPOCH') or '0'})
open('${B}/m4-fw.img', 'wb').write(hdr + payload)
"
    fi

    # スロット毎の falcon.itb (bootargs の root= だけが差分)
    for slot in a b; do
        case $slot in
            a) rootpart=5 ;;
            b) rootpart=6 ;;
        esac
        cp ${DEPLOY_DIR_IMAGE}/${KART_FALCON_DTB} ${B}/falcon-$slot.dtb
        fdtput -c ${B}/falcon-$slot.dtb /chosen 2>/dev/null || true
        fdtput -t s ${B}/falcon-$slot.dtb /chosen bootargs \
            "root=/dev/mmcblk2p$rootpart rootwait rw ${FALCON_BOOTARGS_COMMON}$splash_args"
        # 非搭載 IP のノード無効化 (FALCON_DTB_DISABLE_NODES のコメント参照)
        for node in ${FALCON_DTB_DISABLE_NODES}; do
            fdtput -t s ${B}/falcon-$slot.dtb "$node" status disabled
        done
        # SPL スプラッシュ時は lcdif/dsi の assigned-clocks を削除する。
        # 素の DT だと lcdif probe (~0.3s) が LCDIF_PIXEL を 24MHz に
        # 強制設定し、108MHz で走査中のスプラッシュ表示が即死する (実測特定)。
        # weston の modeset はモード由来のレートを自前で設定するため機能損失なし
        if [ -n "${KART_SPLASH}" ]; then
            for prop in assigned-clocks assigned-clock-parents assigned-clock-rates; do
                fdtput -d ${B}/falcon-$slot.dtb /soc@0/bus@32c00000/lcdif@32e00000 $prop || true
                fdtput -d ${B}/falcon-$slot.dtb /soc@0/bus@32c00000/dsi@32e10000 $prop 2>/dev/null || true
            done
            # /chosen に kart,splash-active を立てる。カーネル側の splash 引き継ぎ
            # パッチ (0004-0009) はこのプロパティで発動する。SPL 実行時セットは
            # 未実装なので、splash ビルド (KART_SPLASH) の falcon DTB に焼き込む。
            # パッチ側は実ハード状態 (ドメイン ON / チップ生存 / 解像度一致) も
            # 検証してから引き継ぐので、万一 splash 未描画でも安全にフォールバックする。
            fdtput -t s ${B}/falcon-$slot.dtb /chosen kart,splash-active "1"
        fi

        # DTB も 64B 倍数へ (fdtput 編集後に。totalsize はヘッダ内なので
        # 末尾ゼロ埋めは無害)
        truncate -s %64 ${B}/falcon-$slot.dtb

        cat > ${B}/falcon-$slot.its << EOF
/dts-v1/;
/ {
	description = "kart falcon boot slot $slot (ATF + Linux + XPI DTB)";
	#address-cells = <1>;
	images {
		atf {
			description = "ARM Trusted Firmware (bl31)";
			data = /incbin/("bl31.bin");
			type = "firmware";
			/* os 無し: SPL 側 spl_perform_fixups が falcon FIT を識別する印 */
			arch = "arm64";
			compression = "none";
			load = <${FALCON_ATF_ADDR}>;
			entry = <${FALCON_ATF_ADDR}>;
		};
		kernel {
			description = "Linux Image";
			data = /incbin/("Image");
			type = "kernel";
			os = "linux";
			arch = "arm64";
			compression = "none";
			load = <${FALCON_KERNEL_ADDR}>;
			entry = <${FALCON_KERNEL_ADDR}>;
		};
		fdt {
			description = "XPI DTB (root=p$rootpart baked)";
			data = /incbin/("falcon-$slot.dtb");
			type = "flat_dt";
			arch = "arm64";
			compression = "none";
			load = <${FALCON_FDT_ADDR}>;
		};$splash_node
	};
	configurations {
		default = "conf";
		conf {
			description = "falcon";
			firmware = "atf";
			loadables = $loadables;
			fdt = "fdt";
		};
	};
};
EOF
        # 外部データ必須: 埋め込みだと SPL が FIT 全体 (21MB+) を 512KB heap に
        # malloc しようとして死ぬ
        mkimage -E -p 0x1000 -f ${B}/falcon-$slot.its ${B}/falcon-$slot.itb
    done

    # OTA 試行時 (upgrade_available=1) に SPL が読む proper フォールバック FIT。
    # flash.bin 内の binman FIT と同じ構造 (firmware=uboot os=u-boot + atf + fdt)
    cat > ${B}/uboot-fallback.its << EOF
/dts-v1/;
/ {
	description = "kart falcon fallback: U-Boot proper via ATF";
	#address-cells = <1>;
	images {
		uboot {
			description = "U-Boot proper (nodtb)";
			data = /incbin/("u-boot-nodtb.bin");
			type = "standalone";
			os = "u-boot";
			arch = "arm64";
			compression = "none";
			load = <${FALCON_UBOOT_ADDR}>;
		};
		atf {
			description = "ARM Trusted Firmware (bl31)";
			data = /incbin/("bl31.bin");
			type = "firmware";
			arch = "arm64";
			compression = "none";
			load = <${FALCON_ATF_ADDR}>;
			entry = <${FALCON_ATF_ADDR}>;
		};
		fdt {
			description = "U-Boot control DTB";
			data = /incbin/("u-boot-proper.dtb");
			type = "flat_dt";
			arch = "arm64";
			compression = "none";
		};
	};
	configurations {
		default = "conf";
		conf {
			description = "u-boot proper";
			firmware = "uboot";
			loadables = "atf";
			fdt = "fdt";
		};
	};
};
EOF
    mkimage -E -p 0x1000 -f ${B}/uboot-fallback.its ${B}/u-boot.itb

    # SPL falcon 機構が要求する args ファイル (FIT+ATF 設計では未使用のダミー)
    dd if=/dev/zero of=${B}/args bs=512 count=1
}

do_compile:append:imx8mp-debix() {
    # kart_splash_logo.h → logo.bin (SPL がファイル読みする 1bit マスク)
    python3 - <<'PYEOF'
import re, struct
src = open('${WORKDIR}/kart_splash_logo.h').read()
def val(name):
    return int(re.search(rf'#define {name} (\d+)', src).group(1))
w, h, x, y = val('KART_LOGO_W'), val('KART_LOGO_H'), val('KART_LOGO_X'), val('KART_LOGO_Y')
bits = bytes(int(b, 16) for b in re.findall(r'0x[0-9a-fA-F]{2}', src.split('kart_logo_bits')[1]))
open('${B}/logo.bin', 'wb').write(b'KLGO' + struct.pack('<4I', w, h, x, y) + bits)
PYEOF
}

do_deploy() {
    install -m 0644 ${B}/falcon-a.itb ${DEPLOYDIR}/falcon-a.itb
    install -m 0644 ${B}/falcon-b.itb ${DEPLOYDIR}/falcon-b.itb
    install -m 0644 ${B}/u-boot.itb ${DEPLOYDIR}/u-boot.itb
    install -m 0644 ${B}/args ${DEPLOYDIR}/args
    if [ -f ${B}/logo.bin ]; then
        install -m 0644 ${B}/logo.bin ${DEPLOYDIR}/logo.bin
    fi
    if [ -n "${KART_M4}" ]; then
        install -m 0644 ${B}/m4-fw.img ${DEPLOYDIR}/m4-fw.img
    fi
}
addtask deploy after do_compile before do_build
