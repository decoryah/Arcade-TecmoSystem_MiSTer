// The whole Tecmo System board minus the memory controller: clock enables, the 68000 side (ts_main), the video (ts_video), the sound board
// (ts_sound) and its mix (ts_audio48).  Everything big -- the program ROMs, the tile / sprite ROMs, the sample ROMs -- is behind ports for the
// SDRAM system (ts_mem) or a testbench.
`default_nettype none
module ts_core #(
    parameter CLK_HZ      = 96_000_000,
    parameter SIM_GATE    = 0,
    parameter WDOG_FRAMES = 400
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         clk_opl,                // the YMF262's 24 MHz

    // the ROM image's header (TecmoSys.sv)
    input  wire [1:0]   game,
    input  wire [127:0] slots,
    input  wire         vmode,                  // the OSD's Video Timing: 0 Original, 1 RT4K DV1 (ts_cen.sv; taken at the next frame)

    // 68000 program
    output wire         mrom_req,
    output wire [19:1]  mrom_addr,
    input  wire         mrom_ack,
    input  wire [15:0]  mrom_data,
    // Z80 program
    output wire         zrom_req,
    output wire [17:0]  zrom_addr,
    input  wire         zrom_ack,
    input  wire [7:0]   zrom_data,
    // samples
    output wire         ymz_req,
    output wire [23:0]  ymz_addr,
    input  wire         ymz_ack,
    input  wire [7:0]   ymz_data,
    output wire         oki_req,
    output wire [18:0]  oki_addr,
    input  wire         oki_ack,
    input  wire [7:0]   oki_data,
    // tile rows / sprite chunks
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

    // inputs (MAME's P1 / P2 port values, active low)
    input  wire [15:0]  in_p1,
    input  wire [15:0]  in_p2,

    // 93C46 image
    input  wire         nv_wr,
    input  wire [6:0]   nv_addr,
    input  wire [7:0]   nv_data,
    input  wire [6:0]   nv_raddr,
    output wire [7:0]   nv_rdata,
    output wire         ee_written,

    // audio, 48 kHz
    output wire         audio_valid,
    output wire signed [15:0] audio_l,
    output wire signed [15:0] audio_r,

    // video
    output wire         o_ce,
    output wire [8:0]   o_x,
    output wire [8:0]   o_y,
    output wire         o_hs,
    output wire         o_vs,
    output wire         o_hb,
    output wire         o_vb,
    output wire [7:0]   o_r,
    output wire [7:0]   o_g,
    output wire [7:0]   o_b,

    output wire         wd_rst,                 // the watchdog reset the machine (one clock; the reset itself is held here)
    output wire         ev_vbl_o,
    output wire         dbg_late,
    output wire         dbg_halted,
    output wire [15:0]  dbg_zpc
);
    // The watchdog's reset (MAME: a soft reset of the whole machine; the RAMs keep their contents -- the cold boot relies on it, see
    // docs/status.md flaw 10) is held for 2048 clocks: the 68000 (fx68k) takes a reset only over many of its own clocks (a reset of a
    // few machine clocks left it running its "wait for the reset" loop).
    // rst_i is a register: it reaches the asynchronous clears of the Z80 and the OKI (tv80s_cen, jt6295), whose recovery paths cross the chip
    logic [10:0] wd_hold = 11'd0;
    wire         wd_req;
    logic        rst_i = 1'b1;
    always_ff @(posedge clk) begin
        if (rst) wd_hold <= 11'd0;
        else if (wd_req) wd_hold <= 11'd2047;
        else if (wd_hold != 11'd0) wd_hold <= wd_hold - 11'd1;
        rst_i <= rst | wd_req | (wd_hold != 11'd0);
    end
    assign wd_rst = wd_req;

    wire cen_phi1, cen_phi2, cen_z80, cen_oki, ce_pix, pix_first, pix_frame, vmode_q;
    ts_cen #(.CLK_HZ(CLK_HZ)) u_cen (.clk(clk), .rst(rst_i), .vmode_req(vmode), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .cen_z80(cen_z80),
        .cen_oki(cen_oki), .ce_pix(ce_pix), .pix_first(pix_first), .pix_frame(pix_frame), .vmode(vmode_q));

    wire         ev_vbl, vblank;
    wire         latch_wr, snd_pending;
    wire [7:0]   latch_data;
    wire [12:0]  tx_addr;
    wire [10:0]  bg1_addr, bg2_addr, bg3_addr, tpal_addr;
    wire [14:0]  spr_addr;
    wire [13:0]  spal_addr;
    wire [15:0]  tx_data, bg1_data, bg2_data, bg3_data, spr_data, tpal_data, spal_data;
    wire [191:0] scroll;
    wire [1:0]   spr_list;
    wire [15:0]  spr_xoff, spr_yoff;
    assign ev_vbl_o = ev_vbl;

    ts_main #(.SIM_GATE(SIM_GATE), .WDOG_FRAMES(WDOG_FRAMES)) u_main (
        .clk(clk), .rst(rst_i), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .game(game),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
        .ev_vbl(ev_vbl), .vblank(vblank),
        .in_p1(in_p1), .in_p2(in_p2),
        .nv_wr(nv_wr), .nv_addr(nv_addr), .nv_data(nv_data), .nv_raddr(nv_raddr), .nv_rdata(nv_rdata), .ee_written(ee_written),
        .latch_wr(latch_wr), .latch_data(latch_data), .snd_pending(snd_pending),
        .tx_addr(tx_addr), .tx_data(tx_data), .bg1_addr(bg1_addr), .bg1_data(bg1_data), .bg2_addr(bg2_addr), .bg2_data(bg2_data),
        .bg3_addr(bg3_addr), .bg3_data(bg3_data), .spr_addr(spr_addr), .spr_data(spr_data),
        .tpal_addr(tpal_addr), .tpal_data(tpal_data), .spal_addr(spal_addr), .spal_data(spal_data),
        .scroll(scroll), .spr_list(spr_list), .spr_xoff(spr_xoff), .spr_yoff(spr_yoff),
        .wd_rst(wd_req), .dbg_halted(dbg_halted));

    ts_video u_video (
        .clk(clk), .rst(rst_i), .ce_pix(ce_pix), .pix_first(pix_first), .pix_frame(pix_frame), .vmode(vmode_q),
        .tx_addr(tx_addr), .tx_data(tx_data), .bg1_addr(bg1_addr), .bg1_data(bg1_data), .bg2_addr(bg2_addr), .bg2_data(bg2_data),
        .bg3_addr(bg3_addr), .bg3_data(bg3_data), .spr_addr(spr_addr), .spr_data(spr_data),
        .tpal_addr(tpal_addr), .tpal_data(tpal_data), .spal_addr(spal_addr), .spal_data(spal_data),
        .scroll(scroll), .spr_list(spr_list), .spr_xoff(spr_xoff), .spr_yoff(spr_yoff), .slots(slots),
        .trom_req(trom_req), .trom_addr(trom_addr), .trom_len(trom_len), .trom_ack(trom_ack), .trom_valid(trom_valid), .trom_data(trom_data),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_len(srom_len), .srom_ack(srom_ack), .srom_valid(srom_valid), .srom_data(srom_data),
        .ev_vbl(ev_vbl), .vblank(vblank),
        .o_ce(o_ce), .o_x(o_x), .o_y(o_y), .o_hs(o_hs), .o_vs(o_vs), .o_hb(o_hb), .o_vb(o_vb), .o_r(o_r), .o_g(o_g), .o_b(o_b),
        .late(dbg_late));

    wire signed [13:0] oki_out;
    wire               oki_smp;
    wire signed [15:0] opl_l, opl_r, ymz_l, ymz_r;
    ts_sound u_sound (
        .clk(clk), .rst(rst_i), .clk_opl(clk_opl), .cen_z80(cen_z80), .cen_oki(cen_oki),
        .latch(latch_data), .latch_wr(latch_wr), .pending(snd_pending),
        .zrom_req(zrom_req), .zrom_addr(zrom_addr), .zrom_ack(zrom_ack), .zrom_data(zrom_data),
        .oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack), .oki_data(oki_data),
        .ymz_req(ymz_req), .ymz_addr(ymz_addr), .ymz_ack(ymz_ack), .ymz_data(ymz_data),
        .oki_out(oki_out), .oki_smp(oki_smp), .opl_l(opl_l), .opl_r(opl_r), .ymz_l(ymz_l), .ymz_r(ymz_r),
        .dbg_pc(dbg_zpc));

    ts_audio48 #(.CLK_HZ(CLK_HZ)) u_a48 (
        .clk(clk), .rst(rst), .ymz_l(ymz_l), .ymz_r(ymz_r), .opl_l(opl_l), .opl_r(opl_r), .oki(oki_out), .oki_smp(oki_smp),
        .out_valid(audio_valid), .out_l(audio_l), .out_r(audio_r));
endmodule
`default_nettype wire
