// Clock enables of the Tecmo System board, from the 96 MHz machine clock.  The board's crystals (tecmosys.cpp): 16 MHz (X3: the 68000, the Z80
// at 16 / 2, the OKI at 16 / 8), 28 MHz (X2: the video), 14.31818 MHz (X1: the YMF262, its own clock domain here: ts_opl3.sv) and 16.9344 MHz
// (X4: the YMZ280B, whose sample tick is a fractional enable inside ts_ymz280b.sv).
//
//   cen_phi1 / cen_phi2   the 68000's phase enables, 16 MHz = 96 / 6 (phases 3 clocks apart; the SDC's multicycle paths rely on this)
//   cen_z80               the Z80, 8 MHz = 96 / 12
//   cen_oki               the OKI M6295, 2 MHz = 96 / 48 (pin 7 high: sample rate 2 MHz / 132)
//   ce_pix                the dot clock, 28 MHz / 4 = 7 MHz: LINE_DOTS (448) enables per line, 13 clocks apart after a gap of 320 clocks at the start
//                         of the line; every line is exactly 6144 clocks (64 us: a 15.625 kHz line, 272 lines = 57.4449 Hz, MAME's 57.4458 Hz)
//
// The CPU phases run during reset too (the 68000 needs clocks to take its reset); only the pixel phase restarts.
`default_nettype none
module ts_cen #(
    parameter CLK_HZ    = 96_000_000,
    parameter CPU_DIV   = 6,
    parameter PIX_HZ    = 7_000_000,
    parameter LINE_DOTS = 448,
    parameter LINES     = 272
) (
    input  wire clk,
    input  wire rst,
    output reg  cen_phi1,
    output reg  cen_phi2,
    output reg  cen_z80,
    output reg  cen_oki,
    output wire ce_pix
);
    localparam HALF = CPU_DIV / 2;
    reg [7:0] c = 8'd0;
    reg [5:0] d48 = 6'd0;
    always_ff @(posedge clk) begin
        c <= (c == CPU_DIV - 1) ? 8'd0 : c + 8'd1;
        cen_phi1 <= (c == CPU_DIV - 1);
        cen_phi2 <= (c == HALF - 1);
        d48 <= (d48 == 6'd47) ? 6'd0 : d48 + 6'd1;
        cen_z80 <= (d48 == 6'd11) || (d48 == 6'd23) || (d48 == 6'd35) || (d48 == 6'd47);
        cen_oki <= (d48 == 6'd47);
    end

    ts_pixgen #(.CLK_HZ(CLK_HZ), .PIX_HZ(PIX_HZ), .LINE_DOTS(LINE_DOTS), .LINES(LINES)) u_pix (
        .clk(clk), .rst(rst), .ce_pix(ce_pix), .line_start());
endmodule

// The regular pixel enable (jchan-mister's jchan_pixgen, renamed): a line of LINE_I clocks (the long line LINE_I + xl) = GAP idle clocks, then
// LINE_DOTS enables DOT clocks apart.  With 96 MHz, 7 MHz and 448 dots the line is exactly 6144 clocks and the frame has no fraction to carry
// (xl = 0): every line is the same.  line_start pulses on the first clock of a line.
module ts_pixgen #(
    parameter CLK_HZ    = 96_000_000,
    parameter PIX_HZ    = 7_000_000,
    parameter LINE_DOTS = 448,
    parameter LINES     = 272,
    parameter LONG_LY   = 260
) (
    input  wire clk,
    input  wire rst,
    output reg  ce_pix,
    output reg  line_start
);
    localparam DOT      = CLK_HZ / PIX_HZ;                                    // clocks per dot: 13
    localparam [39:0] LINE_NUM = 40'(CLK_HZ) * 40'(LINE_DOTS);
    localparam LINE_I   = int'(LINE_NUM / 40'(PIX_HZ));                       // 6144
    localparam LINE_R   = int'(LINE_NUM % 40'(PIX_HZ));                       // 0
    localparam GAP      = LINE_I - DOT * LINE_DOTS;                           // 320
    localparam [39:0] FR_R = 40'(LINES) * 40'(LINE_R);
    localparam FR_I     = int'(FR_R / 40'(PIX_HZ));
    localparam FR_F     = int'(FR_R % 40'(PIX_HZ));

    logic [13:0] lc;
    logic [8:0]  ly;
    logic [31:0] facc;
    logic [8:0]  nd;
    logic [4:0]  dm;
    logic [6:0]  xl;
    wire  [8:0]  ly_n   = (ly == 9'(LINES - 1)) ? 9'd0 : ly + 9'd1;
    wire  [13:0] len_m1 = (ly == 9'(LONG_LY)) ? 14'(LINE_I - 1) + 14'(xl) : 14'(LINE_I - 1);
    wire  [32:0] facc_s = {1'b0, facc} + 33'(FR_F);
    wire         carry  = (facc_s >= 33'(PIX_HZ));
    always_ff @(posedge clk) begin
        ce_pix     <= 1'b0;
        line_start <= 1'b0;
        if (rst) begin
            lc <= '0; xl <= 7'(FR_I); ly <= 9'(LINES - 1); facc <= '0; nd <= '0; dm <= '0;
        end else begin
            if (lc == len_m1) begin
                lc <= '0;
                ly <= ly_n;
                nd <= '0;
                dm <= '0;
                line_start <= 1'b1;
                if (ly_n == 9'(LONG_LY - 1)) begin
                    facc <= carry ? facc_s[31:0] - 32'(PIX_HZ) : facc_s[31:0];
                    xl   <= 7'(FR_I) + (carry ? 7'd1 : 7'd0);
                end
            end else begin
                lc <= lc + 14'd1;
            end
            if (lc == len_m1) begin
                if (GAP == 0) begin ce_pix <= 1'b1; nd <= 9'd1; dm <= 5'd1; end
            end else if (nd == 9'd0) begin
                if (lc + 14'd1 == 14'(GAP)) begin ce_pix <= 1'b1; nd <= 9'd1; dm <= 5'd1; end
            end else if (nd != 9'(LINE_DOTS)) begin
                if (dm == 5'(DOT)) begin ce_pix <= 1'b1; nd <= nd + 9'd1; dm <= 5'd1; end
                else dm <= dm + 5'd1;
            end
        end
    end
endmodule
`default_nettype wire
