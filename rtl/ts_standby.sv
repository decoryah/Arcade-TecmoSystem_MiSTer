// A blank raster of the video's own timing (ts_video, either Video Timing: 448 x 272 or 395 x 264 dots, 320 x 240 picture) for the time
// the machine is held in reset (the ROM image streaming in, the OSD's Reset).  The MiSTer framework draws its "Loading" pop-up as part of the
// OSD, which needs a video signal with sync to sit on.  (The owner's jchan-mister jchan_standby, with this board's timing.)  The sync positions
// are ts_video's (Original: hs dots 344 - 375, vs lines 248 - 250; RT4K DV1: hs dots 342 - 369, vs lines 244 - 246): keep them equal.
`default_nettype none
module ts_standby (
    input  wire clk,
    input  wire vmode_req,                      // the OSD's Video Timing (ts_pixgen takes it at a frame's start)
    output reg  o_ce,
    output reg  o_hblank,
    output reg  o_vblank,
    output reg  o_hs,
    output reg  o_vs
);
    wire ce, first, frame, mode;
    ts_pixgen u_pix (.clk(clk), .rst(1'b0), .mode_req(vmode_req), .ce_pix(ce), .first(first), .frame(frame), .mode(mode), .line_start());
    reg [8:0]  hc = 9'd0, vc = 9'd0;
    initial begin o_ce = 1'b0; o_hblank = 1'b1; o_vblank = 1'b1; o_hs = 1'b0; o_vs = 1'b0; end
    // as ts_video: the counters move at a dot, the outputs are the previous dot's (one dot late, all alike)
    always @(posedge clk) begin
        o_ce <= 1'b0;
        if (ce) begin
            o_ce <= 1'b1;
            if (first) begin
                hc <= 9'd0;
                vc <= frame ? 9'd0 : vc + 9'd1;
            end else
                hc <= hc + 9'd1;
            o_hblank <= !(hc < 9'd320);
            o_vblank <= !(vc < 9'd240);
            o_hs     <= mode ? (hc >= 9'd342) && (hc < 9'd370) : (hc >= 9'd344) && (hc < 9'd376);
            o_vs     <= mode ? (vc >= 9'd244) && (vc < 9'd247) : (vc >= 9'd248) && (vc < 9'd251);
        end
    end
endmodule
`default_nettype wire
