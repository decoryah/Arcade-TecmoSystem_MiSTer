// A blank raster of the video's own timing (ts_video: 448 x 272 dots, 320 x 240 picture, 7 MHz dots as ts_cen's 13-clock enable) for the time
// the machine is held in reset (the ROM image streaming in, the OSD's Reset).  The MiSTer framework draws its "Loading" pop-up as part of the
// OSD, which needs a video signal with sync to sit on.  (The owner's jchan-mister jchan_standby, with this board's timing.)  The sync positions
// are ts_video's (hs dots 344 - 375, vs lines 248 - 250): keep them equal.
`default_nettype none
module ts_standby #(
    parameter CLK_HZ = 96_000_000,
    parameter PIX_HZ = 7_000_000
) (
    input  wire clk,
    output reg  o_ce,
    output reg  o_hblank,
    output reg  o_vblank,
    output reg  o_hs,
    output reg  o_vs
);
    wire ce;
    ts_pixgen #(.CLK_HZ(CLK_HZ), .PIX_HZ(PIX_HZ), .LINE_DOTS(448), .LINES(272)) u_pix (.clk(clk), .rst(1'b0), .ce_pix(ce), .line_start());
    reg [8:0]  hc = 9'd0, vc = 9'd0;
    initial begin o_ce = 1'b0; o_hblank = 1'b1; o_vblank = 1'b1; o_hs = 1'b0; o_vs = 1'b0; end
    always @(posedge clk) begin
        o_ce <= 1'b0;
        if (ce) begin
            o_ce <= 1'b1;
            if (hc == 9'd447) begin
                hc <= 9'd0;
                vc <= (vc == 9'd271) ? 9'd0 : vc + 9'd1;
            end else
                hc <= hc + 9'd1;
            o_hblank <= (hc >= 9'd319) && (hc != 9'd447);
            o_hs     <= (hc >= 9'd343) && (hc < 9'd375);
            o_vblank <= (vc >= 9'd240);
            o_vs     <= (vc >= 9'd248) && (vc < 9'd251);
        end
    end
endmodule
`default_nettype wire
