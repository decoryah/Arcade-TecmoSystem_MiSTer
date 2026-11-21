// Clock enables of the Tecmo System board, from the 96 MHz machine clock.  The board's crystals (tecmosys.cpp): 16 MHz (X3: the 68000, the Z80
// at 16 / 2, the OKI at 16 / 8), 28 MHz (X2: the video), 14.31818 MHz (X1: the YMF262, its own clock domain here: ts_opl3.sv) and 16.9344 MHz
// (X4: the YMZ280B, whose sample tick is a fractional enable inside ts_ymz280b.sv).
//
//   cen_phi1 / cen_phi2   the 68000's phase enables, 16 MHz = 96 / 6 (phases 3 clocks apart; the SDC's multicycle paths rely on this)
//   cen_z80               the Z80, 8 MHz = 96 / 12
//   cen_oki               the OKI M6295, 2 MHz = 96 / 48 (pin 7 high: sample rate 2 MHz / 132)
//   ce_pix                the dots, in the raster the OSD's Video Timing chooses (ts_pixgen)
//
// The CPU phases run during reset too (the 68000 needs clocks to take its reset); only the pixel phase restarts.
`default_nettype none
module ts_cen #(
    parameter CLK_HZ    = 96_000_000,
    parameter CPU_DIV   = 6
) (
    input  wire clk,
    input  wire rst,
    input  wire vmode_req,                      // the OSD's Video Timing: 0 Original, 1 RT4K DV1 (taken at the next frame)
    output reg  cen_phi1,
    output reg  cen_phi2,
    output reg  cen_z80,
    output reg  cen_oki,
    output wire ce_pix,
    output wire pix_first,                      // with ce_pix: the first dot of a line
    output wire pix_frame,                      // with pix_first: and that line is the first of a frame
    output wire vmode                           // the raster of the frame in progress
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

    ts_pixgen u_pix (.clk(clk), .rst(rst), .mode_req(vmode_req), .ce_pix(ce_pix), .first(pix_first), .frame(pix_frame), .mode(vmode),
        .line_start());
endmodule

// The dots of the two rasters (after the owner's jchan-mister jchan_pixgen: a line = GAP idle clocks, then the dots DOT clocks apart; every line
// of a raster the same, as the RetroTINK 4K's direct video wants).  The raster is taken at the start of a frame, so a change never cuts one.
//
//   mode 0, Original (the first release's): the board's 7 MHz dots (28 MHz / 4) on 13-clock steps, 448 a line after a 320-clock gap; 6144
//           clocks a line (64 us: 15.625 kHz), 272 lines = 57.4449 Hz (MAME: 57.4458 Hz on a placeholder 512 x 512 raster; the board's
//           totals are not documented).  The picture is 43.3 us of the 64 us line.
//   mode 1, RT4K DV1: 16-clock dots (6 MHz), 395 a line after a 10-clock gap; 6330 clocks a line (65.94 us: 15.166 kHz), 264 lines =
//           57.4465 Hz.  For the RetroTINK 4K on MiSTer's direct video (docs/status.md, "The RetroTINK 4K"): it sorts the signal by its
//           lines per frame (264 is "MiSTer (240p)", 272 "MiSTer Gen.") and crops the picture from the DV1 infoframe (the pixel repeat,
//           the offset from the hsync, the size), and it **centres its crop between the hsyncs**: in direct video's DE, from 4 dots after
//           an hsync to the next one (the owner's tests 2026-11-21: the Original's picture, 17 us after the hsync, came out cut on the
//           right; 20261121c, a 4-dot hsync, and 20261121d, this 4.7 us one, both with the picture centred, came out whole).  So the
//           picture sits centred there, and the hsync is a CRT's: a CRT holds this raster too.  (ts_video: picture dots 0-319, front
//           porch 22 (3.7 us), hsync 342-369 (28 dots, 4.7 us), back porch 25 + the gap (4.3 us).)
//
// The line counts are kept here only to take the mode at a frame's start; ts_video / ts_standby count the dots and lines from first / frame.
module ts_pixgen (
    input  wire clk,
    input  wire rst,
    input  wire mode_req,
    output reg  ce_pix,
    output reg  first,
    output reg  frame,
    output reg  mode,
    output reg  line_start
);
    localparam [4:0]  DOT0   = 5'd13,      DOT1   = 5'd16;
    localparam [8:0]  DOTS0  = 9'd448,     DOTS1  = 9'd395;
    localparam [13:0] CLKS0  = 14'd6144,   CLKS1  = 14'd6330;
    localparam [8:0]  LINES0 = 9'd272,     LINES1 = 9'd264;
    localparam [13:0] GAP0   = CLKS0 - 14'(DOT0) * 14'(DOTS0);               // 320
    localparam [13:0] GAP1   = CLKS1 - 14'(DOT1) * 14'(DOTS1);               // 10

    wire [4:0]  dot   = mode ? DOT1   : DOT0;
    wire [8:0]  dots  = mode ? DOTS1  : DOTS0;
    wire [13:0] clks  = mode ? CLKS1  : CLKS0;
    wire [8:0]  lines = mode ? LINES1 : LINES0;
    wire [13:0] gap   = mode ? GAP1   : GAP0;

    logic [13:0] lc;
    logic [8:0]  ly;
    logic [8:0]  nd;
    logic [4:0]  dm;
    always_ff @(posedge clk) begin
        ce_pix     <= 1'b0;
        first      <= 1'b0;
        frame      <= 1'b0;
        line_start <= 1'b0;
        if (rst) begin
            lc <= '0; ly <= '0; nd <= '0; dm <= '0; mode <= mode_req;
        end else begin
            if (lc == clks - 14'd1) begin
                lc <= '0;
                nd <= '0;
                dm <= '0;
                line_start <= 1'b1;
                if (ly == lines - 9'd1) begin ly <= '0; mode <= mode_req; end
                else ly <= ly + 9'd1;
            end else begin
                lc <= lc + 14'd1;
                if (nd == 9'd0) begin
                    if (lc + 14'd1 == gap) begin ce_pix <= 1'b1; first <= 1'b1; frame <= (ly == 9'd0); nd <= 9'd1; dm <= 5'd1; end
                end else if (nd != dots) begin
                    if (dm == dot) begin ce_pix <= 1'b1; nd <= nd + 9'd1; dm <= 5'd1; end
                    else dm <= dm + 5'd1;
                end
            end
        end
    end
endmodule
`default_nettype wire
