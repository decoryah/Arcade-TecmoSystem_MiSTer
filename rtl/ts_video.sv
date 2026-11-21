// The Tecmo System video: raster, the tilemap and sprite line renderers (ts_tiles, ts_sprites) a line ahead of the display, and the final mix
// of MAME 0.289 tecmosys_v.cpp (do_final_mix) with the two palettes.
//
// Raster: the OSD's Video Timing (ts_cen.sv, ts_pixgen: the dots and the frame's mode come from there).  The picture is dots 0-319 of lines
// 0-239 (MAME's visible area) in both; the vertical blank (lines 240 to the last) starts with the 68000's interrupt and the moment the sprite
// list is taken (ev_vbl); 880000 reads 0 during it (`vblank`).  Sync positions are this core's choice (the board's are not documented):
//   Original  448 dots x 272 lines (7 MHz dots, 15.625 kHz, 57.4449 Hz: MAME's 57.4458 Hz screen): hsync dots 344-375, vsync lines 248-250
//   RT4K DV1  395 dots x 264 lines (6 MHz dots, 15.166 kHz, 57.4465 Hz): hsync dots 342-369 (4.7 us), the picture centred between the
//             hsyncs as direct video's DE sees it (ts_cen.sv says why), vsync lines 244-246
//
// Line L is drawn into bank L & 1 of the two line buffers during line L - 1 (line 0 during the last line) and displayed from it during line L:
//   compose buffer  {pri[1:0], tilemap palette index[10:0]} of the topmost tilemap pixel (ts_tiles; tilemap 1 writes every pixel)
//   sprite buffer   {pri[1:0], palette[5:0], pixel[7:0]} (ts_sprites; cleared by the display as it reads it, MAME's per-frame fill(0))
//
// The mix of one pixel (do_final_mix; T = a tilemap pixel with a pen != 0, S = a sprite pixel != 0; tile colour = tilemap palette[idx],
// sprite colour = sprite palette[pal * 256 + pixel], background = sprite palette[0x3f00]; bit 15 of a palette word is its blend flag):
//   !S, !T  background                          S, T, both blend flags set   (tile colour + sprite colour) / 2 per 8-bit channel
//   !S,  T  tile colour                         S, otherwise                 sprite colour if sprite pri >= tile pri, else tile colour
// (MAME's other combinations reduce to these.)  Colours are xGGGGGRRRRRBBBBB, each 5-bit channel expanded to 8 bits as (c << 3) | (c >> 2).
`default_nettype none
module ts_video (
    input  wire         clk,
    input  wire         rst,
    input  wire         ce_pix,
    input  wire         pix_first,              // ts_pixgen: with ce_pix, the first dot of a line
    input  wire         pix_frame,              // ts_pixgen: with pix_first, the first line of a frame
    input  wire         vmode,                  // ts_pixgen: the frame's raster (0 Original, 1 RT4K DV1)

    // ts_main's memories (port B) and registers
    output wire [12:0]  tx_addr,
    input  wire [15:0]  tx_data,
    output wire [10:0]  bg1_addr,
    input  wire [15:0]  bg1_data,
    output wire [10:0]  bg2_addr,
    input  wire [15:0]  bg2_data,
    output wire [10:0]  bg3_addr,
    input  wire [15:0]  bg3_data,
    output wire [14:0]  spr_addr,
    input  wire [15:0]  spr_data,
    output wire [10:0]  tpal_addr,
    input  wire [15:0]  tpal_data,
    output wire [13:0]  spal_addr,
    input  wire [15:0]  spal_data,
    input  wire [191:0] scroll,
    input  wire [1:0]   spr_list,
    input  wire [15:0]  spr_xoff,
    input  wire [15:0]  spr_yoff,
    input  wire [127:0] slots,

    // tile ROM and sprite ROM ports (ts_mem)
    output wire         trom_req,
    output wire [24:0]  trom_addr,
    output wire [6:0]   trom_len,
    input  wire         trom_ack,
    input  wire         trom_valid,
    input  wire [15:0]  trom_data,
    output wire         srom_req,
    output wire [24:0]  srom_addr,
    output wire [6:0]   srom_len,
    input  wire         srom_ack,
    input  wire         srom_valid,
    input  wire [15:0]  srom_data,

    // raster events
    output logic        ev_vbl,
    output wire         vblank,

    // video out (one pixel per o_ce)
    output logic        o_ce,
    output logic [8:0]  o_x,
    output logic [8:0]  o_y,
    output logic        o_hs,
    output logic        o_vs,
    output logic        o_hb,
    output logic        o_vb,
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,

    output logic        late                     // sticky: a line was not finished in time
);
    // ---------------------------------------------------------------- raster
    logic [8:0] hc = 9'd447, vc = 9'd271;
    wire  [8:0] vlast = vmode ? 9'd263 : 9'd271;          // the last line of the frame in progress
    logic       line_go;
    always_ff @(posedge clk) begin
        ev_vbl  <= 1'b0;
        line_go <= 1'b0;
        if (rst) begin
            hc <= 9'd447; vc <= 9'd271;
        end else if (ce_pix) begin
            if (pix_first) begin
                hc <= 9'd0;
                vc <= (pix_frame || vc == vlast) ? 9'd0 : vc + 9'd1;    // (the two agree; vlast only matters if the resets differ)
                if (vc == 9'd239) ev_vbl <= 1'b1;
                line_go <= 1'b1;
            end else hc <= hc + 9'd1;
        end
    end
    assign vblank = (vc >= 9'd240);
    // the line drawn during this one
    wire [8:0] nl = (vc == vlast) ? 9'd0 : vc + 9'd1;

    // ---------------------------------------------------------------- renderers
    wire        t_busy, s_busy, s_ready;
    wire        t_we, s_we;
    wire [9:0]  t_wa, s_wa;
    wire [15:0] t_wd, s_wd;
    wire        draw = line_go && (nl < 9'd240);
    always_ff @(posedge clk) begin
        if (rst) late <= 1'b0;
        else if (draw && (t_busy || s_busy)) late <= 1'b1;
    end

    ts_tiles u_tiles (
        .clk(clk), .rst(rst), .start(draw && !t_busy), .line(nl[7:0]), .bank(nl[0]), .busy(t_busy),
        .scroll(scroll),
        .tx_addr(tx_addr), .tx_data(tx_data), .bg1_addr(bg1_addr), .bg1_data(bg1_data),
        .bg2_addr(bg2_addr), .bg2_data(bg2_data), .bg3_addr(bg3_addr), .bg3_data(bg3_data),
        .rom_req(trom_req), .rom_addr(trom_addr), .rom_len(trom_len), .rom_ack(trom_ack), .rom_valid(trom_valid), .rom_data(trom_data),
        .lb_we(t_we), .lb_addr(t_wa), .lb_data(t_wd));

    ts_sprites u_spr (
        .clk(clk), .rst(rst),
        .vbl(ev_vbl), .list(spr_list), .xoff(spr_xoff), .yoff(spr_yoff),
        .start(draw && !s_busy), .line(nl[7:0]), .bank(nl[0]), .busy(s_busy), .ready(s_ready),
        .spr_addr(spr_addr), .spr_data(spr_data), .slots(slots),
        .rom_req(srom_req), .rom_addr(srom_addr), .rom_len(srom_len), .rom_ack(srom_ack), .rom_valid(srom_valid), .rom_data(srom_data),
        .lb_we(s_we), .lb_addr(s_wa), .lb_data(s_wd));

    // ---------------------------------------------------------------- line buffers: A = the renderer's writes, B = the display (sprites: read, then clear)
    logic [9:0]  rd_a;
    logic        clr_we;
    wire  [15:0] cmp_q, spr_q;
    ts_tdpram #(.AW(10)) u_lbt (.clk(clk),
        .a_we(t_we), .a_be(2'b11), .a_addr(t_wa), .a_wdata(t_wd), .a_rdata(),
        .b_we(1'b0), .b_be(2'b00), .b_addr(rd_a), .b_wdata(16'h0), .b_rdata(cmp_q));
    ts_tdpram #(.AW(10)) u_lbs (.clk(clk),
        .a_we(s_we), .a_be(2'b11), .a_addr(s_wa), .a_wdata(s_wd), .a_rdata(),
        .b_we(clr_we), .b_be(2'b11), .b_addr(rd_a), .b_wdata(16'h0), .b_rdata(spr_q));

    // ---------------------------------------------------------------- display pipeline
    // hc / vc change at a ce_pix and then hold the pixel for 13 clocks.  d1: the first clock of the pixel (line buffer address out);
    // d2: the buffers' words are there (palette addresses out, the words kept, the sprite entry cleared); d3: the palettes' words are
    // there (mix).  The next ce_pix registers the pixel onto the outputs.
    logic        d1, d2, d3;
    logic [15:0] c1, s1;
    always_comb rd_a = {vc[0], hc};
    wire  vis = (hc < 9'd320) && (vc < 9'd240);
    always_ff @(posedge clk) begin
        d1 <= ce_pix;
        d2 <= d1;
        d3 <= d2;
        clr_we <= d1 && vis;
        if (d2) begin c1 <= cmp_q; s1 <= spr_q; end
    end
    wire        s_on1 = (spr_q[7:0] != 8'd0);
    assign tpal_addr = cmp_q[10:0];
    assign spal_addr = s_on1 ? spr_q[13:0] : 14'h3f00;

    function automatic [23:0] rgb(input [15:0] v);
        rgb = {v[9:5], v[9:7], v[14:10], v[14:12], v[4:0], v[4:2]};
    endfunction
    wire        t_on = (c1[3:0] != 4'd0);
    wire        s_on = (s1[7:0] != 8'd0);
    wire [23:0] tc   = rgb(tpal_data);
    wire [23:0] sc   = rgb(spal_data);
    wire [8:0]  br   = {1'b0, tc[23:16]} + {1'b0, sc[23:16]};
    wire [8:0]  bgc  = {1'b0, tc[15:8]}  + {1'b0, sc[15:8]};
    wire [8:0]  bb   = {1'b0, tc[7:0]}   + {1'b0, sc[7:0]};
    logic [23:0] mix;
    always_comb begin
        if (!s_on)                                          mix = t_on ? tc : sc;       // (sc = the background pen 0x3f00 then)
        else if (t_on && tpal_data[15] && spal_data[15])    mix = {br[8:1], bgc[8:1], bb[8:1]};
        else if (s1[15:14] >= c1[12:11])                    mix = sc;
        else                                                mix = tc;
    end
    logic [23:0] px;
    always_ff @(posedge clk) if (d3) px <= mix;

    // ---------------------------------------------------------------- output: the pixel of the previous ce_pix (one dot late, sync delayed alike)
    always_ff @(posedge clk) begin
        o_ce <= ce_pix;
        if (ce_pix) begin
            o_x  <= hc;
            o_y  <= vc;
            o_hb <= !(hc < 9'd320);
            o_vb <= !(vc < 9'd240);
            o_hs <= vmode ? (hc >= 9'd342) && (hc < 9'd370) : (hc >= 9'd344) && (hc < 9'd376);
            o_vs <= vmode ? (vc >= 9'd244) && (vc < 9'd247) : (vc >= 9'd248) && (vc < 9'd251);
            {o_r, o_g, o_b} <= (hc < 9'd320 && vc < 9'd240) ? px : 24'd0;
        end
    end
endmodule
`default_nettype wire
