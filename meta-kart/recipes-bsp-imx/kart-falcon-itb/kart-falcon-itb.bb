SUMMARY = "Falcon boot FITs (ATF + kernel + DTB) and U-Boot proper fallback FIT"
DESCRIPTION = "SPL が直接ロードする falcon.itb をスロット毎 (root=p5/p6 焼き分け) に \
生成し、OTA 試行時に SPL が読む u-boot.itb (proper フォールバック) も組む。\
設計は docs/imx8mm-xpi-bringup/08-falcon.md。kas/imx8mm-falcon.yml から使う。"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

DEPENDS = "u-boot-tools-native dtc-native"

# SPL スプラッシュのロゴは u-boot 側 (SPL) に 1bit マスクで埋め込み済み
# (scripts/gen-splash-raw.py → kart_splash_logo.h、0010 パッチ)。falcon.itb に
# ロゴ画像は不要。KART_SPLASH は splash ビルドの印 (kas/imx8mm-splash.yml が "1"):
# mem=2042M と /chosen kart,splash-active を付けるかの分岐に使う
KART_SPLASH ?= ""

inherit deploy nopackages

COMPATIBLE_MACHINE = "imx8mm-xpi"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_compile[depends] += " \
    virtual/kernel:do_deploy \
    imx-atf:do_deploy \
    u-boot-fslc:do_deploy \
"

# アドレスは U-Boot パッチ (0001-imx8mm-kart-falcon-mode.patch) の
# KART_FALCON_* 定数、および SPL heap (0x42200000) と衝突しないこと
FALCON_ATF_ADDR = "0x920000"
FALCON_KERNEL_ADDR = "0x40400000"
FALCON_FDT_ADDR = "0x43100000"
FALCON_UBOOT_ADDR = "0x40200000"

# extlinux と同じカーネル引数系 (machine conf の UBOOT_EXTLINUX_KERNEL_ARGS を共有)
FALCON_BOOTARGS_COMMON = "console=ttymxc1,115200 ${UBOOT_EXTLINUX_KERNEL_ARGS}"

do_compile() {
    cp ${DEPLOY_DIR_IMAGE}/Image ${B}/Image
    cp ${DEPLOY_DIR_IMAGE}/bl31-imx8mm.bin ${B}/bl31.bin
    cp ${DEPLOY_DIR_IMAGE}/u-boot-nodtb.bin ${B}/u-boot-nodtb.bin
    cp ${DEPLOY_DIR_IMAGE}/u-boot-proper.dtb ${B}/u-boot-proper.dtb

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

    # スロット毎の falcon.itb (bootargs の root= だけが差分)
    for slot in a b; do
        case $slot in
            a) rootpart=5 ;;
            b) rootpart=6 ;;
        esac
        cp ${DEPLOY_DIR_IMAGE}/imx8mm-xpi-kart.dtb ${B}/falcon-$slot.dtb
        fdtput -c ${B}/falcon-$slot.dtb /chosen 2>/dev/null || true
        fdtput -t s ${B}/falcon-$slot.dtb /chosen bootargs \
            "root=/dev/mmcblk2p$rootpart rootwait rw ${FALCON_BOOTARGS_COMMON}$splash_args"
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

do_deploy() {
    install -m 0644 ${B}/falcon-a.itb ${DEPLOYDIR}/falcon-a.itb
    install -m 0644 ${B}/falcon-b.itb ${DEPLOYDIR}/falcon-b.itb
    install -m 0644 ${B}/u-boot.itb ${DEPLOYDIR}/u-boot.itb
    install -m 0644 ${B}/args ${DEPLOYDIR}/args
}
addtask deploy after do_compile before do_build
