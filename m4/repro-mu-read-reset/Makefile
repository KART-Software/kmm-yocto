# Reproduction case for: i.MX8MM M4 + live rpmsg/MU session + GPIO read
# => silent SoC hard reset. See README.md.
#
# Prereq: clone rpmsg-lite (v5.4.1) once:
#   git clone --depth 1 --branch v5.4.1 \
#       https://github.com/nxp-mcuxpresso/rpmsg-lite ../lib/rpmsg-lite
#
#   make            -> repro.elf (GPIO3 read loop: resets the SoC)
#                      repro_control.elf (SCTR read loop: runs forever)
CROSS   ?= arm-none-eabi-
RL      := ../lib/rpmsg-lite/lib

CFLAGS  := -mcpu=cortex-m4 -mthumb -mfloat-abi=soft -Os -ffreestanding \
           -Wall -g -I. -I../shim \
           -I$(RL)/include -I$(RL)/include/environment/bm \
           -I$(RL)/include/platform/imx8mm_m4
LDFLAGS := -nostdlib -Wl,-T,m4-tcm.ld -Wl,--build-id=none -Wl,--gc-sections

SRCS := startup.c rsc_table.c ../shim/libc_min.c \
        $(RL)/rpmsg_lite/rpmsg_lite.c \
        $(RL)/rpmsg_lite/rpmsg_ns.c \
        $(RL)/virtio/virtqueue.c \
        $(RL)/common/llist.c \
        $(RL)/rpmsg_lite/porting/environment/rpmsg_env_bm.c \
        $(RL)/rpmsg_lite/porting/platform/imx8mm_m4/rpmsg_platform.c

all: repro.elf repro_control.elf

repro.elf: main.c $(SRCS) m4-tcm.ld
	$(CROSS)gcc $(CFLAGS) -DPERIPH_READ=1 $(LDFLAGS) -o $@ main.c $(SRCS)
	$(CROSS)size $@

repro_control.elf: main.c $(SRCS) m4-tcm.ld
	$(CROSS)gcc $(CFLAGS) -DPERIPH_READ=0 $(LDFLAGS) -o $@ main.c $(SRCS)
	$(CROSS)size $@

clean:
	rm -f repro.elf repro_control.elf

.PHONY: all clean
