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

	/* remoteproc はこの「名前のセクション」を探す — .text に統合すると
	 * 名前が消えて "No resource table in elf" になる (実測) */
	/* ALIGN はセクション定義側に置く。内側に書くとセクション先頭が
	 * 非整列のときテーブルの前にパディングが入り、カーネルが先頭を
	 * テーブルと誤読して vdev が生えない (実測 — サイズ 0x58→0x5c) */
	.resource_table ALIGN(8) :
	{
		KEEP(*(.resource_table))
	} > TCML

	.bss (NOLOAD) :
	{
		*(.bss*)
		*(COMMON)
	} > TCMU

	_estack = ORIGIN(TCMU) + LENGTH(TCMU);

	/DISCARD/ : { *(.ARM.exidx*) *(.comment) }
}
