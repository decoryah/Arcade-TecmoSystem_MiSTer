// PLL: 50 MHz reference in; the 96 MHz machine clock, the same clock shifted for the SDRAM chip's clock pin (pll_0002.v), and 24 MHz for the
// YMF262 (ts_opl3).  The SDRAM phase (-5078 ps) is the one of the owner's metro-mister / jchan-mister (hardware-proven with the same controller).
`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk   96 MHz, the machine
		output wire  outclk_1, // outclk1.clk   96 MHz, shifted: SDRAM_CLK
		output wire  outclk_2, // outclk2.clk   24 MHz, the YMF262
		output wire  locked    //  locked.export
	);

	pll_0002 pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
		.locked   (locked)
	);

endmodule
