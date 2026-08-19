SUMMARY = "Seeded U-Boot environment image for the kart A/B boot flow"
DESCRIPTION = "Merges the built U-Boot's default environment (u-boot-initial-env) \
with the kart A/B variables and produces kart-env.bin via mkenvimage. The wks \
rawcopies it into the env storage offset, so the very first boot already runs \
the A/B bootcmd without any manual env surgery."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

DEPENDS = "u-boot-tools-native"

SRC_URI = "file://kart-ab-env.txt"

inherit deploy nopackages

COMPATIBLE_MACHINE = "(mx8mm-generic-bsp)"
PACKAGE_ARCH = "${MACHINE_ARCH}"

# u-boot-fslc の CONFIG_ENV_SIZE (kart-ab.cfg) と一致させること
KART_ENV_SIZE = "0x2000"

# initial env は u-boot-fslc:do_deploy が置く。ファイル名は
# ${UBOOT_CONFIG} (この machine では sd 固定) が付く。
KART_INITIAL_ENV = "u-boot-fslc-initial-env-sd"
do_compile[depends] += "u-boot-fslc:do_deploy"

do_compile() {
    # --- Secondary Image Table (SIT) ---
    # i.MX8M ROM のブートローダ A/B 用。sector 0x41 (33280B) に置かれ、
    # A copy (sector 0x42) が無効なとき ROM が firstSectorNumber (0x1000) +
    # 0x42 = sector 0x1042 の B copy へ自動フォールバックする。
    # 構造 (20B, LE): [8B zero][magic 0x00112233][firstSectorNumber][4B zero]
    # wic の --align は KiB 単位で sector 0x41 (32.5KiB) を直接指せないため、
    # sector 0x40 (32KiB) 起点の 1KiB ブロブ (先頭 512B は零) にして
    # --align 32 で配置する。docs.u-boot.org/en/v2021.07/imx/misc/psb.html
    dd if=/dev/zero of=${B}/kart-sit.bin bs=512 count=2 2>/dev/null
    # sector 0x41 内 offset 0x08: magic 0x00112233 (LE) / 0x0C: firstSectorNumber 0x1000 (LE)
    # seek=520 = 512 (先頭パディング) + 8 (SIT 内オフセット)。
    # bitbake のシェルパーサは $(( )) を解釈できないためリテラルで書く。
    printf '\063\042\021\000\000\020\000\000' | \
        dd of=${B}/kart-sit.bin bs=1 seek=520 conv=notrunc 2>/dev/null
    test "$(wc -c < ${B}/kart-sit.bin)" = "1024"

    # --- U-Boot environment ---
    # initial env + kart 追加分を連結し、重複キーは後勝ちでマージする
    # (mkenvimage 自体は重複を解決しないため)。# 行と空行は除去。
    cat ${DEPLOY_DIR_IMAGE}/${KART_INITIAL_ENV} ${WORKDIR}/kart-ab-env.txt \
      | awk -F= '
          /^[#[:space:]]/ || !/=/ { next }
          {
              key = $1
              sub(/^[^=]*=/, "")
              if (!(key in val)) order[++n] = key
              val[key] = $0
          }
          END { for (i = 1; i <= n; i++) print order[i] "=" val[order[i]] }
        ' > ${B}/kart-env.txt
    mkenvimage -s ${KART_ENV_SIZE} -o ${B}/kart-env.bin ${B}/kart-env.txt
}

do_deploy() {
    install -m 0644 ${B}/kart-env.bin ${DEPLOYDIR}/kart-env.bin
    install -m 0644 ${B}/kart-sit.bin ${DEPLOYDIR}/kart-sit.bin
    # 検証・デバッグ用にテキストも残す
    install -m 0644 ${B}/kart-env.txt ${DEPLOYDIR}/kart-env.txt
}
addtask deploy after do_compile before do_build
