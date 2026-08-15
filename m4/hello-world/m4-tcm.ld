/* XPI-iMX8MM Cortex-M4 TCM リンカスクリプト (remoteproc 用 ELF)
 *
 * コード/データは TCML、bss/スタックは TCMU。アドレスは M4 視点
 * (A53 視点では TCML=0x007E0000, TCMU=0x00800000 — imx_rproc の
 * アドレス変換テーブルが p_paddr から写す)。
 * .data も TCML に直置き (TCM は RAM なのでコピー用 LMA 分離が不要)。
 */
MEMORY
{
	TCML (rwx) : ORIGIN = 0x1FFE0000, LENGTH = 128K
	TCMU (rw)  : ORIGIN = 0x20000000, LENGTH = 128K
}

ENTRY(Reset_Handler)

SECTIONS
{
	.text :
	{
		KEEP(*(.vectors))
		*(.text*)
		*(.rodata*)
		*(.data*)
	} > TCML

	.bss (NOLOAD) :
	{
		*(.bss*)
		*(COMMON)
	} > TCMU

	_estack = ORIGIN(TCMU) + LENGTH(TCMU);

	/DISCARD/ : { *(.ARM.exidx*) *(.comment) }
}
