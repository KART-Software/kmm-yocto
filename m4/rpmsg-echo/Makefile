# rpmsg echo — rpmsg-lite (ベンダリング済み lib/) + 自前シムでビルド
CROSS   ?= arm-none-eabi-
HOST    ?= root@100.87.109.114
RL      := ../lib/rpmsg-lite/lib

CFLAGS  := -mcpu=cortex-m4 -mthumb -mfloat-abi=soft -Os -ffreestanding \
           -Wall -g -I. -I../shim \
           -I$(RL)/include -I$(RL)/include/environment/bm \
           -I$(RL)/include/platform/imx8mm_m4
LDFLAGS := -nostdlib -Wl,-T,m4-tcm.ld -Wl,--build-id=none -Wl,--gc-sections

SRCS := main.c startup.c rsc_table.c ../shim/libc_min.c \
        $(RL)/rpmsg_lite/rpmsg_lite.c \
        $(RL)/rpmsg_lite/rpmsg_ns.c \
        \
        $(RL)/virtio/virtqueue.c \
        $(RL)/common/llist.c \
        $(RL)/rpmsg_lite/porting/environment/rpmsg_env_bm.c \
        $(RL)/rpmsg_lite/porting/platform/imx8mm_m4/rpmsg_platform.c

rpmsg_echo.elf: $(SRCS) m4-tcm.ld
	$(CROSS)gcc $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS)
	$(CROSS)size $@

deploy: rpmsg_echo.elf
	scp rpmsg_echo.elf $(HOST):/tmp/rpmsg_echo.elf
	ssh $(HOST) '\
	  echo stop > /sys/class/remoteproc/remoteproc0/state 2>/dev/null; \
	  echo -n /tmp > /sys/module/firmware_class/parameters/path; \
	  echo -n rpmsg_echo.elf > /sys/class/remoteproc/remoteproc0/firmware; \
	  echo start > /sys/class/remoteproc/remoteproc0/state; \
	  cat /sys/class/remoteproc/remoteproc0/state'

stop:
	ssh $(HOST) 'echo stop > /sys/class/remoteproc/remoteproc0/state'

clean:
	rm -f rpmsg_echo.elf

.PHONY: deploy stop clean
