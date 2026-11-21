// Raster bench (sim/run_raster.sh; Verilator, clocked from tb_raster.cpp): the new ts_cen / ts_video in Original mode against the first
// release's (renamed *_old), clock for clock; then the shape of both rasters, frame by frame, across switches (ts_video and the standby raster).
module tb_raster (input wire clk);
    localparam longint CMP_END = 20 + 3 * 6144 * 272 + 5000;       // three Original frames compared
    localparam longint SW1 = CMP_END + 2_400_000;                   // -> RT4K DV1, mid-frame
    localparam longint SW2 = SW1 + 6_500_000;                       // -> Original, mid-frame
    localparam longint END = SW2 + 6_000_000;
    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    wire rst  = (cyc < 20);
    wire vreq = (cyc >= SW1) && (cyc < SW2);
    wire [15:0] z16 = 16'h0;
    // ---- the release's
    wire ce_o, p1o, p2o, zo, oko;
    ts_cen_old u_co (.clk(clk), .rst(rst), .cen_phi1(p1o), .cen_phi2(p2o), .cen_z80(zo), .cen_oki(oko), .ce_pix(ce_o));
    wire oce_o, ohs_o, ovs_o, ohb_o, ovb_o, ev_o, vb_o; wire [8:0] ox_o, oy_o; wire [7:0] r_o, g_o, b_o;
    ts_video_old u_vo (.clk(clk), .rst(rst), .ce_pix(ce_o),
        .tx_addr(), .tx_data(z16), .bg1_addr(), .bg1_data(z16), .bg2_addr(), .bg2_data(z16), .bg3_addr(), .bg3_data(z16),
        .spr_addr(), .spr_data(z16), .tpal_addr(), .tpal_data(z16), .spal_addr(), .spal_data(z16),
        .scroll(192'd0), .spr_list(2'd0), .spr_xoff(z16), .spr_yoff(z16), .slots(128'd0),
        .trom_req(), .trom_addr(), .trom_len(), .trom_ack(1'b0), .trom_valid(1'b0), .trom_data(z16),
        .srom_req(), .srom_addr(), .srom_len(), .srom_ack(1'b0), .srom_valid(1'b0), .srom_data(z16),
        .ev_vbl(ev_o), .vblank(vb_o), .o_ce(oce_o), .o_x(ox_o), .o_y(oy_o), .o_hs(ohs_o), .o_vs(ovs_o), .o_hb(ohb_o), .o_vb(ovb_o),
        .o_r(r_o), .o_g(g_o), .o_b(b_o), .late());
    // ---- the new
    wire ce_n, first, frame, vmode, p1n, p2n, zn, okn;
    ts_cen u_cn (.clk(clk), .rst(rst), .vmode_req(vreq), .cen_phi1(p1n), .cen_phi2(p2n), .cen_z80(zn), .cen_oki(okn), .ce_pix(ce_n),
        .pix_first(first), .pix_frame(frame), .vmode(vmode));
    wire oce_n, ohs_n, ovs_n, ohb_n, ovb_n, ev_n, vb_n; wire [8:0] ox_n, oy_n; wire [7:0] r_n, g_n, b_n;
    ts_video u_vn (.clk(clk), .rst(rst), .ce_pix(ce_n), .pix_first(first), .pix_frame(frame), .vmode(vmode),
        .tx_addr(), .tx_data(z16), .bg1_addr(), .bg1_data(z16), .bg2_addr(), .bg2_data(z16), .bg3_addr(), .bg3_data(z16),
        .spr_addr(), .spr_data(z16), .tpal_addr(), .tpal_data(z16), .spal_addr(), .spal_data(z16),
        .scroll(192'd0), .spr_list(2'd0), .spr_xoff(z16), .spr_yoff(z16), .slots(128'd0),
        .trom_req(), .trom_addr(), .trom_len(), .trom_ack(1'b0), .trom_valid(1'b0), .trom_data(z16),
        .srom_req(), .srom_addr(), .srom_len(), .srom_ack(1'b0), .srom_valid(1'b0), .srom_data(z16),
        .ev_vbl(ev_n), .vblank(vb_n), .o_ce(oce_n), .o_x(ox_n), .o_y(oy_n), .o_hs(ohs_n), .o_vs(ovs_n), .o_hb(ohb_n), .o_vb(ovb_n),
        .o_r(r_n), .o_g(g_n), .o_b(b_n), .late());
    // ---- the new standby raster (its own free-running dots)
    wire sce, shb, svb, shs, svs;
    ts_standby u_sb (.clk(clk), .vmode_req(vreq), .o_ce(sce), .o_hblank(shb), .o_vblank(svb), .o_hs(shs), .o_vs(svs));

    // ---- compare, clock for clock (Original)
    longint mism = 0, cmp_clocks = 0;
    always @(posedge clk) begin
        if (!rst && cyc < CMP_END) begin
            cmp_clocks <= cmp_clocks + 1;
            if ({ce_o, oce_o, ohs_o, ovs_o, ohb_o, ovb_o, ev_o, vb_o, ox_o, oy_o, r_o, g_o, b_o, p1o, p2o, zo, oko} !=
                {ce_n, oce_n, ohs_n, ovs_n, ohb_n, ovb_n, ev_n, vb_n, ox_n, oy_n, r_n, g_n, b_n, p1n, p2n, zn, okn}) begin
                if (mism < 5) $display("MISMATCH at clock %0d: old ce %b hs %b vs %b hb %b vb %b x %0d y %0d | new ce %b hs %b vs %b hb %b vb %b x %0d y %0d",
                    cyc, oce_o, ohs_o, ovs_o, ohb_o, ovb_o, ox_o, oy_o, oce_n, ohs_n, ovs_n, ohb_n, ovb_n, ox_n, oy_n);
                mism <= mism + 1;
            end
        end
        if (cyc == CMP_END) $display("Original against the release: %0d clocks compared, %0d differ", cmp_clocks, mism);
        if (cyc == SW1) $display("-- Video Timing -> RT4K DV1 at clock %0d", cyc);
        if (cyc == SW2) $display("-- Video Timing -> Original at clock %0d", cyc);
        if (cyc == END) $finish;
    end

    rmeas #(.NAME("video  ")) m_v (.clk(clk), .on(cyc >= CMP_END - 1_700_000), .cyc(cyc), .mode(vmode), .ev(ev_n),
        .ce(oce_n), .hs(ohs_n), .vs(ovs_n), .hb(ohb_n), .vb(ovb_n));
    rmeas #(.NAME("standby")) m_s (.clk(clk), .on(cyc >= CMP_END - 1_700_000), .cyc(cyc), .mode(u_sb.mode), .ev(1'b0),
        .ce(sce), .hs(shs), .vs(svs), .hb(shb), .vb(svb));
endmodule

// The shape of a raster, frame by frame (a frame from a VSync rise to the next, a line from an HSync rise to the next), from its dot outputs.
module rmeas #(parameter string NAME = "") (
    input wire clk, input wire on, input longint cyc, input wire mode, input wire ev,
    input wire ce, input wire hs, input wire vs, input wire hb, input wire vb
);
    longint t_hs = -1, fr_start = -1, t_pic = -1, t_ev = -1, ev_to_pic = -1, hs_to_pic = -1, pic_len = -1;
    longint ln_min = 1 << 30, ln_max = 0;
    int dl = 0, d_min = 1 << 30, d_max = 0, lines = 0, hs_w = 0, hs_wmax = 0, pic_lines = 0, pic_dots = 0, pd = 0, vs_w = 0, pic_line = -1;
    int f = 0;
    bit hs_d = 0, vs_d = 0, hb_d = 1, vb_d = 1, mode_mixed = 0, mode_f = 0;
    always @(posedge clk) if (on) begin
        if (ev) t_ev = cyc;
        if (ce) begin
            if (mode != mode_f) mode_mixed = 1;
            dl++;
            if (hs && !hs_d) begin
                if (t_hs >= 0) begin
                    if (cyc - t_hs < ln_min) ln_min = cyc - t_hs;
                    if (cyc - t_hs > ln_max) ln_max = cyc - t_hs;
                    if (dl < d_min) d_min = dl;
                    if (dl > d_max) d_max = dl;
                end
                if (pd > 0) begin pic_lines++; pic_dots = pd; end
                t_hs = cyc; dl = 0; lines++; hs_w = 0; pd = 0;
                if (vs) vs_w++;
            end
            if (hs) begin hs_w++; if (hs_w > hs_wmax) hs_wmax = hs_w; end
            if (!hb && !vb) pd++;
            if (!hb && hb_d && !vb) begin
                hs_to_pic = cyc - t_hs; t_pic = cyc;
                if (pic_line < 0) begin pic_line = lines; ev_to_pic = (t_ev >= 0) ? cyc - t_ev : -1; end
            end
            if (hb && !hb_d && !vb && t_pic >= 0) pic_len = cyc - t_pic;
            if (vs && !vs_d) begin
                if (fr_start >= 0)
                    $display("%s %s frame %0d%s: %0d lines, %0d clocks = %.4f Hz; lines %0d..%0d clocks, %0d..%0d dots; picture %0d x %0d, %0d clocks a line (%.1f %%), starting %0d clocks (%.2f us) after the hsync's rise; hsync %0d dots, vsync %0d lines; picture from line %0d after the vsync; interrupt to the picture %.3f ms",
                        NAME, mode_f ? "RT4K DV1" : "Original", f, mode_mixed ? " (mode changed in it)" : "", lines, cyc - fr_start,
                        96.0e6 / real'(cyc - fr_start), ln_min, ln_max, d_min, d_max, pic_dots, pic_lines, pic_len,
                        100.0 * real'(pic_len) / real'(ln_max), hs_to_pic, real'(hs_to_pic) / 96.0, hs_wmax, vs_w, pic_line,
                        real'(ev_to_pic) / 96.0e3);
                fr_start = cyc; f++; lines = 0; pic_lines = 0; ln_min = 1 << 30; ln_max = 0; d_min = 1 << 30; d_max = 0; pic_line = -1;
                vs_w = 0; hs_wmax = 0; mode_mixed = 0; mode_f = mode;
            end
            hs_d = hs; vs_d = vs; hb_d = hb; vb_d = vb;
        end
    end
endmodule
