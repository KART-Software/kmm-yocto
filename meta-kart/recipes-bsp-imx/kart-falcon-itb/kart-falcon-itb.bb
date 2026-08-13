SUMMARY = "Falcon boot FITs (ATF + kernel + DTB) and U-Boot proper fallback FIT"
DESCRIPTION = "SPL が直接ロードする falcon.itb をスロット毎 (root=p5/p6 焼き分け) に \
生成し、OTA 試行時に SPL が読む u-boot.itb (proper フォールバック) も組む。\
設計は docs/imx8mm-xpi-bringup/08-falcon.md。kas/imx8mm-falcon.yml から使う。"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

DEPENDS = "u-boot-tools-native dtc-native"

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

    # スロット毎の falcon.itb (bootargs の root= だけが差分)
    for slot in a b; do
        case $slot in
            a) rootpart=5 ;;
            b) rootpart=6 ;;
        esac
        cp ${DEPLOY_DIR_IMAGE}/imx8mm-xpi-kart.dtb ${B}/falcon-$slot.dtb
        fdtput -c ${B}/falcon-$slot.dtb /chosen 2>/dev/null || true
        fdtput -t s ${B}/falcon-$slot.dtb /chosen bootargs \
            "root=/dev/mmcblk2p$rootpart rootwait rw ${FALCON_BOOTARGS_COMMON}"

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
		};
	};
	configurations {
		default = "conf";
		conf {
			description = "falcon";
			firmware = "atf";
			loadables = "kernel";
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
