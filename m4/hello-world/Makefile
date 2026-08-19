# XPI-iMX8MM M4 hello world — arm-none-eabi-gcc だけでビルドできる
# (apt: gcc-arm-none-eabi。MCUXpresso SDK 不要)
#
#   make          → hello.elf (remoteproc がそのまま読める)
#   make deploy   → 実機へ scp + remoteproc で再起動
#   make stop     → M4 停止

CROSS   ?= arm-none-eabi-
HOST    ?= root@100.87.109.114
CFLAGS  := -mcpu=cortex-m4 -mthumb -mfloat-abi=soft -Os -ffreestanding \
           -Wall -Wextra -g
LDFLAGS := -nostdlib -Wl,-T,m4-tcm.ld -Wl,--build-id=none

hello.elf: hello.c m4-tcm.ld
	$(CROSS)gcc $(CFLAGS) $(LDFLAGS) -o $@ hello.c
	$(CROSS)size $@

deploy: hello.elf
	scp hello.elf $(HOST):/tmp/hello.elf
	ssh $(HOST) '\
	  echo stop > /sys/class/remoteproc/remoteproc0/state 2>/dev/null; \
	  echo -n /tmp > /sys/module/firmware_class/parameters/path; \
	  echo -n hello.elf > /sys/class/remoteproc/remoteproc0/firmware; \
	  echo start > /sys/class/remoteproc/remoteproc0/state; \
	  cat /sys/class/remoteproc/remoteproc0/state'

stop:
	ssh $(HOST) 'echo stop > /sys/class/remoteproc/remoteproc0/state; \
	  cat /sys/class/remoteproc/remoteproc0/state'

clean:
	rm -f hello.elf

.PHONY: deploy stop clean
