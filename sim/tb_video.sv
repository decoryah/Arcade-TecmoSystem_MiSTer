// Frozen-state video bench: ts_video + ts_mem + the SDRAM model (the set's image), its RAMs and registers preloaded from a MAME state of
// tools/capture.py.  MAME's picture of state N is drawn from the tilemaps / palettes / scroll of state N and the sprite bitmap of state N - 1:
// the sprite RAM and the 880000 registers are loaded from +SPRSTATE (N - 1), everything else from +STATE (N).  The first vertical blank takes
// the sprite list; the picture scanned out after it is the one to compare (tb_video.cpp).
//
//   +IMAGE=<set.sdram> +HDR=<set.hdr> +STATE=<dir/fNNNNN> +SPRSTATE=<dir/fMMMMM>
`default_nettype none
module tb_video (
    input  wire         clk,
    input  wire         reset,
    output wire         ev_vbl,
    output wire         o_ce,
    output wire [8:0]   o_x,
    output wire [8:0]   o_y,
    output wire         o_hb,
    output wire         o_vb,
    output wire [7:0]   o_r,
    output wire [7:0]   o_g,
    output wire [7:0]   o_b,
    output wire         late
);
    logic [15:0] tx [0:8191];
    logic [15:0] bg1 [0:2047], bg2 [0:2047], bg3 [0:2047];
    logic [15:0] spr [0:32767];
    logic [15:0] tpal [0:2047];
    logic [15:0] spal [0:16383];
    logic [15:0] rg [0:35];          // scroll_0..3 (3 words each), then 880000regs (24 words)
    logic [15:0] rgs [0:35];         // the same of the sprite state
    logic [7:0]  hdr [0:255];
    logic [127:0] slots;
    initial begin : load
        string st, ss, p;
        int fd, n;
        if (!$value$plusargs("STATE=%s", st)) $fatal(1, "needs +STATE=");
        if (!$value$plusargs("SPRSTATE=%s", ss)) ss = st;
        $readmemh({st, ".tx"}, tx);
        $readmemh({st, ".bg1"}, bg1);
        $readmemh({st, ".bg2"}, bg2);
        $readmemh({st, ".bg3"}, bg3);
        $readmemh({st, ".tpal"}, tpal);
        $readmemh({st, ".pal"}, spal);
        $readmemh({st, ".regs"}, rg);
        $readmemh({ss, ".spr"}, spr);
        $readmemh({ss, ".regs"}, rgs);
        if (!$value$plusargs("HDR=%s", p)) $fatal(1, "needs +HDR=");
        fd = $fopen(p, "rb"); n = $fread(hdr, fd); $fclose(fd);
        for (int s = 0; s < 8; s++) slots[16 * s +: 16] = {hdr[3 + 2 * s], hdr[2 + 2 * s]};
    end
    wire [191:0] scroll;
    genvar g;
    generate for (g = 0; g < 12; g++) begin : g_sc
        assign scroll[16 * g +: 16] = rg[g];
    end endgenerate

    wire [12:0] tx_a; wire [10:0] bg1_a, bg2_a, bg3_a, tpal_a; wire [14:0] spr_a; wire [13:0] spal_a;
    logic [15:0] tx_q, bg1_q, bg2_q, bg3_q, spr_q, tpal_q, spal_q;
    always_ff @(posedge clk) begin
        tx_q <= tx[tx_a]; bg1_q <= bg1[bg1_a]; bg2_q <= bg2[bg2_a]; bg3_q <= bg3[bg3_a];
        spr_q <= spr[spr_a]; tpal_q <= tpal[tpal_a]; spal_q <= spal[spal_a];
    end

    // +VMODE=1: the RT4K DV1 raster (ts_cen.sv); the dots restart with the video, as the core's do with the machine's reset
    logic vmode_req = 1'b0;
    initial begin : vm
        integer v;
        if ($value$plusargs("VMODE=%d", v)) vmode_req = (v != 0);
    end
    wire trom_req, trom_ack, trom_valid, srom_req, srom_ack, srom_valid, mem_ready;
    wire ce_pix, pix_first, pix_frame, vmode;
    ts_pixgen u_pix (.clk(clk), .rst(reset | ~mem_ready), .mode_req(vmode_req), .ce_pix(ce_pix), .first(pix_first), .frame(pix_frame),
        .mode(vmode), .line_start());

    wire [24:0] trom_addr, srom_addr;
    wire [6:0]  trom_len, srom_len;
    wire [15:0] trom_data, srom_data;
    ts_video u_video (
        .clk(clk), .rst(reset | ~mem_ready), .ce_pix(ce_pix), .pix_first(pix_first), .pix_frame(pix_frame), .vmode(vmode),
        .tx_addr(tx_a), .tx_data(tx_q), .bg1_addr(bg1_a), .bg1_data(bg1_q), .bg2_addr(bg2_a), .bg2_data(bg2_q),
        .bg3_addr(bg3_a), .bg3_data(bg3_q), .spr_addr(spr_a), .spr_data(spr_q),
        .tpal_addr(tpal_a), .tpal_data(tpal_q), .spal_addr(spal_a), .spal_data(spal_q),
        .scroll(scroll), .spr_list(rgs[12 + 4][1:0]), .spr_xoff(rgs[12 + 0]), .spr_yoff(rgs[12 + 1]), .slots(slots),
        .trom_req(trom_req), .trom_addr(trom_addr), .trom_len(trom_len), .trom_ack(trom_ack), .trom_valid(trom_valid), .trom_data(trom_data),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_len(srom_len), .srom_ack(srom_ack), .srom_valid(srom_valid), .srom_data(srom_data),
        .ev_vbl(ev_vbl), .vblank(),
        .o_ce(o_ce), .o_x(o_x), .o_y(o_y), .o_hs(), .o_vs(), .o_hb(o_hb), .o_vb(o_vb), .o_r(o_r), .o_g(o_g), .o_b(o_b),
        .late(late));

    wire [12:0] sd_a; wire [1:0] sd_ba; wire [15:0] sd_dq; wire sd_dqml, sd_dqmh, sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_cke;
    ts_mem #(.SHORT_INIT(1)) u_mem (
        .clk(clk), .rst(reset), .ready(mem_ready), .i_rd_late(1'b0),
        .mrom_req(1'b0), .mrom_addr(19'd0), .mrom_ack(), .mrom_data(),
        .zrom_req(1'b0), .zrom_addr(18'd0), .zrom_ack(), .zrom_data(),
        .ymz_req(1'b0), .ymz_addr(24'd0), .ymz_ack(), .ymz_data(),
        .oki_req(1'b0), .oki_addr(19'd0), .oki_ack(), .oki_data(),
        .trom_req(trom_req), .trom_addr(trom_addr), .trom_len(trom_len), .trom_ack(trom_ack), .trom_valid(trom_valid), .trom_data(trom_data),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_len(srom_len), .srom_ack(srom_ack), .srom_valid(srom_valid), .srom_data(srom_data),
        .dl_wr(1'b0), .dl_addr(26'd0), .dl_data(8'd0), .dl_busy(),
        .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_DQ(sd_dq), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh),
        .SDRAM_nCS(sd_ncs), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_nWE(sd_nwe), .SDRAM_CKE(sd_cke),
        .stat_busy(), .stat_words());
    ts_sdram_model u_sdram (.clk(clk), .A(sd_a), .BA(sd_ba), .DQ(sd_dq), .DQML(sd_dqml), .DQMH(sd_dqmh),
        .nCS(sd_ncs), .nRAS(sd_nras), .nCAS(sd_ncas), .nWE(sd_nwe), .CKE(sd_cke));
    initial begin : fill
        string p;
        int fd, n;
        if (!$value$plusargs("IMAGE=%s", p)) $fatal(1, "needs +IMAGE=");
        fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
        n = $fread(u_sdram.mem_b, fd); $fclose(fd);
    end

    integer t_run, t_max, s_run, s_max;
    initial begin t_run = 0; t_max = 0; s_run = 0; s_max = 0; end
    always @(posedge clk) begin
        if (u_video.t_busy) t_run <= t_run + 1; else begin if (t_run > t_max) t_max <= t_run; t_run <= 0; end
        if (u_video.s_busy) s_run <= s_run + 1; else begin if (s_run > s_max) s_max <= s_run; s_run <= 0; end
    end
    final $display("line render: tiles longest %0d clocks, sprites longest %0d clocks (budget 6144, RT4K DV1 6330)", t_max, s_max);
endmodule
`default_nettype wire
