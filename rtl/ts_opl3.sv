// The YMF262 (OPL3) of the sound board: Greg Taylor's opl3_fpga (LGPL-3.0, the copy of MiSTer's ao486 core, modules/opl3: see
// modules/VENDOR.md for the TECMOSYS changes) on its own clock (clk_opl, 24 MHz from the PLL: the chip's 14.31818 MHz / 288 sample rate is a
// fractional enable of it), with the Z80 side on the machine clock.
//
//   Z80 side (clk):  wr = one clock per I/O write to ports 00-03 (a = port & 3: 0 / 2 address of bank 0 / 1, 1 / 3 data); dout = the status
//                    byte for port 0 (IRQ, FT1, FT2 in bits 7-5) and 0xff for ports 1-3, as MAME's ymfm, valid one clock after `a` settles.
//   irq_n            the chip's IRQ output (timer flags), synchronised to clk: the Z80's INT (MAME: ymf.irq_handler -> audiocpu line 0)
//   out_l / out_r    the chip's output, A + C on the left and B + D on the right as MAME routes the four outputs, held from one sample to the
//                    next and moved into the clk domain with a toggle handshake (the samples are stable for ~480 clk_opl clocks).
//                    On the chip's own scale: opl3_fpga makes an operator's output ((exp | 0x400) << 1) >> shift (at most 4,084), as Nuked
//                    OPL3 (traced from the die) and as MAME's own YMF262 until ymfm replaced it in 0.231 ("12 bits here (as in real chip)").
//                    ymfm's operator is twice that ((exp | 0x400) << 2: 8,168, its YMF262 mixing marked "need verification").  MAME 0.289
//                    plays these games' FM 6 dB louder against the YMZ280B and the OKI than the driver's balance (docs/status.md, MAME flaw
//                    11: a 0.225 output bug doubled it, 0.227's rebalance kept the doubling, ymfm's scale kept it since); ts_audio48 mixes
//                    this scale at the driver's balance.  X2 = 1 doubles the output to ymfm's scale (saturated to 16 bits, as ymfm clamps):
//                    MAME 0.289's balance, as in the test builds before the release.
`default_nettype none
module ts_opl3 #(
    parameter X2 = 0
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         clk_opl,

    input  wire         wr,
    input  wire [1:0]   a,
    input  wire [7:0]   din,
    output wire [7:0]   dout,
    output wire         irq_n,

    output logic signed [15:0] out_l,
    output logic signed [15:0] out_r,
    output logic        out_valid               // one clk clock per new sample
);
    wire               s_valid;
    wire signed [15:0] s_l, s_r;
    wire               irq_n_o;

    opl3 u_opl3 (
        .clk(clk_opl), .clk_host(clk), .clk_dac(clk),
        .ic_n(~rst),
        .cs_n(~wr), .rd_n(1'b1), .wr_n(~wr),
        .address(a), .din(din), .dout(dout),
        .sample_valid(s_valid), .sample_l(s_l), .sample_r(s_r),
        .led(), .irq_n(irq_n_o));

    // irq_n into the clk domain
    logic [1:0] irq_s = 2'b11;
    always_ff @(posedge clk) irq_s <= {irq_s[0], irq_n_o};
    assign irq_n = irq_s[1];

    // samples: held in the clk_opl domain on sample_valid with a toggle; copied into clk when the synchronised toggle changes
    logic signed [15:0] h_l = 16'sd0, h_r = 16'sd0;
    logic               tog = 1'b0;
    function automatic logic signed [15:0] x2(input logic signed [15:0] v);   // X2: 2 v, saturated; else v
        if (X2 == 0) return v;
        return (v > 16'sd16383) ? 16'sh7fff : (v < -16'sd16384) ? 16'sh8000 : (v <<< 1);
    endfunction
    always_ff @(posedge clk_opl) if (s_valid) begin h_l <= x2(s_l); h_r <= x2(s_r); tog <= ~tog; end
    logic [2:0] tog_s = 3'b000;
    always_ff @(posedge clk) begin
        tog_s <= {tog_s[1:0], tog};
        out_valid <= 1'b0;
        if (tog_s[2] != tog_s[1]) begin out_l <= h_l; out_r <= h_r; out_valid <= 1'b1; end
        if (rst) begin out_l <= 16'sd0; out_r <= 16'sd0; end
    end
endmodule
`default_nettype wire
