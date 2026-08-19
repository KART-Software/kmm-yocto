# clk-test — ECSPI2 クロック/アクセスのブレッドクラム実験 (rpmsg 無し最小)
CROSS   ?= arm-none-eabi-

CFLAGS  := -mcpu=cortex-m4 -mthumb -mfloat-abi=soft -Os -ffreestanding -Wall -g -I.
LDFLAGS := -nostdlib -Wl,-T,m4-tcm.ld -Wl,--build-id=none -Wl,--gc-sections

SRCS := main.c startup.c rsc_table.c

clk_test.elf: $(SRCS) m4-tcm.ld
	$(CROSS)gcc $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS)
	$(CROSS)size $@

clean:
	rm -f clk_test.elf
