// The Tecmo System main board as the 68000 sees it (MAME 0.289 tecmo/tecmosys.cpp, tecmosys_state::main_map): address decode, the work RAM,
// the video RAMs / palettes / sprite RAM with their video-side ports, the scroll and sprite registers, the inputs, the 93C46, the protection
// device, the sound latch, the vblank interrupt and the watchdog.  The CPU itself (ts_m68k) is instantiated here; the video and the sound board
// are outside (ts_core.sv).
//
// Bus protocol (jchan-mister's): req (held, addr / rnw / be / wdata stable) -> ack (level, rdata valid) -> req drops -> ack drops.  Internal
// slaves answer one clock after req (block RAMs addressed straight from the CPU's address bus); ROM reads go out through mrom_* (req level, data
// with a one-clock ack).
//
//   000000-0fffff  program ROM (1 MB)                     880000-88002f  W video registers (00 sprite X offset, 02 sprite Y offset,
//   200000-20ffff  work RAM                                              08 sprite list select, 22 watchdog); R 880000 = 1 outside the
//   210000-210001  (nopr: reads 0)                                       vertical blank, 880002-88000b = 0
//   300000-300fff  BG1 tile RAM (tilemap 1)                900000-907fff  sprite palette (16 K entries, xGGGGGRRRRRBBBBB)
//   301000-3013ff  BG1 line RAM (unused by the video)      980000-980fff  tilemap palette (2 K entries, same format)
//   400000-400fff  BG2 tile RAM  401000-4013ff line RAM    a00000         W 93C46: bit 11 DI, bit 10 CLK (inverted), bit 9 CS (high byte)
//   500000-500fff  BG3 tile RAM  501000-5013ff line RAM    a80000-a80005  W scroll of tilemap 2 (X, Y, flip)
//   700000-703fff  text tile RAM (tilemap 0)               b00000-b00005  W scroll of tilemap 3
//   800000-80ffff  sprite RAM (four lists of 16 KB)        b80000         R/W protection status (ts_prot)
//   c00000-c00005  W scroll of tilemap 0 (flip only)       c80000-c80005  W scroll of tilemap 1
//   d00000 / d00002  R P1 / P2                             d80000         R 93C46: DO in bit 11
//   e00001         W sound latch                           e80000         W protection data (high byte)
//   f00001         R sound latch pending                   f80000         R protection data (high byte)
// Everything else reads 0 and ignores writes (MAME's unmapped space; the write-only registers read 0).
//
// Interrupt: level 1 at the start of the vertical blank (MAME's irq1_line_hold on the screen's vblank: held until acknowledged), autovectored.
// Watchdog: MAME's WATCHDOG_TIMER with a vblank count of 400 (a guess in the driver): 400 vertical blanks without a write to 880022 reset the
// machine (wd_rst, one clock).  WDOG_FRAMES = 0 turns it off.
`default_nettype none
module ts_main #(
    parameter SIM_GATE    = 0,
    parameter WDOG_FRAMES = 400
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         cen_phi1,
    input  wire         cen_phi2,
    input  wire [1:0]   game,                   // protection tables (ts_prot)

    // program ROM (word reads)
    output wire         mrom_req,
    output wire [19:1]  mrom_addr,
    input  wire         mrom_ack,
    input  wire [15:0]  mrom_data,

    // raster
    input  wire         ev_vbl,                 // one clock: the vertical blank starts (line 240)
    input  wire         vblank,                 // level: the raster is in lines 240..271

    // inputs (MAME's port values, active low)
    input  wire [15:0]  in_p1,
    input  wire [15:0]  in_p2,

    // 93C46 image: the saved file in (little-endian words, MAME's nvram/<set>/eeprom) and out
    input  wire         nv_wr,
    input  wire [6:0]   nv_addr,
    input  wire [7:0]   nv_data,
    input  wire [6:0]   nv_raddr,
    output wire [7:0]   nv_rdata,
    output wire         ee_written,

    // sound board
    output logic        latch_wr,               // one clock: the 68000 wrote the sound latch
    output logic [7:0]  latch_data,
    input  wire         snd_pending,            // the latch holds a byte the Z80 has not read

    // video side: memories (port B, one-clock reads) and registers (live)
    input  wire [12:0]  tx_addr,
    output wire [15:0]  tx_data,
    input  wire [10:0]  bg1_addr,
    output wire [15:0]  bg1_data,
    input  wire [10:0]  bg2_addr,
    output wire [15:0]  bg2_data,
    input  wire [10:0]  bg3_addr,
    output wire [15:0]  bg3_data,
    input  wire [14:0]  spr_addr,
    output wire [15:0]  spr_data,
    input  wire [10:0]  tpal_addr,
    output wire [15:0]  tpal_data,
    input  wire [13:0]  spal_addr,
    output wire [15:0]  spal_data,
    output wire [191:0] scroll,                 // {scroll_3, scroll_2, scroll_1, scroll_0}, each {flip, Y, X} (16 bits each)
    output wire [1:0]   spr_list,               // 880008 & 3
    output wire [15:0]  spr_xoff,               // 880000
    output wire [15:0]  spr_yoff,               // 880002

    output logic        wd_rst,
    output wire         dbg_halted
);
    // ---------------------------------------------------------------- the CPU
    wire         m_req, m_rnw, m_iack;
    wire [23:1]  m_addr;
    wire [1:0]   m_be;
    wire [15:0]  m_wdata;
    logic [15:0] m_rdata;
    wire         m_ack;
    wire [2:0]   m_iack_lvl;
    logic        pend1;
    ts_m68k #(.SIM_GATE(SIM_GATE)) u_cpu (
        .clk(clk), .rst(rst), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2),
        .req(m_req), .addr(m_addr), .rnw(m_rnw), .be(m_be), .wdata(m_wdata), .ack(m_ack), .rdata(m_rdata),
        .ipl(pend1 ? 3'd1 : 3'd0), .iack(m_iack), .iack_lvl(m_iack_lvl), .halted(dbg_halted));

    // ---------------------------------------------------------------- decode
    wire [23:0] ma = {m_addr, 1'b0};
    wire sel_rom  = ma[23:20] == 4'h0;
    wire sel_wram = ma[23:16] == 8'h20;
    wire sel_bg1  = ma[23:12] == 12'h300;
    wire sel_l1   = ma[23:10] == 14'h0C04;              // 301000-3013ff
    wire sel_bg2  = ma[23:12] == 12'h400;
    wire sel_l2   = ma[23:10] == 14'h1004;              // 401000-4013ff
    wire sel_bg3  = ma[23:12] == 12'h500;
    wire sel_l3   = ma[23:10] == 14'h1404;              // 501000-5013ff
    wire sel_tx   = ma[23:14] == 10'h1C0;               // 700000-703fff
    wire sel_spr  = ma[23:16] == 8'h80;
    wire sel_r88  = ma[23:6]  == 18'h22000;             // 880000-88003f
    wire sel_spal = ma[23:15] == 9'h120;                // 900000-907fff
    wire sel_tpal = ma[23:12] == 12'h980;
    wire sel_eew  = ma[23:1]  == 23'h500000;            // a00000
    wire sel_sc2  = ma[23:3]  == 21'h150000;            // a80000
    wire sel_sc3  = ma[23:3]  == 21'h160000;            // b00000
    wire sel_pst  = ma[23:1]  == 23'h5C0000;            // b80000
    wire sel_sc0  = ma[23:3]  == 21'h180000;            // c00000
    wire sel_sc1  = ma[23:3]  == 21'h190000;            // c80000
    wire sel_p1   = ma[23:1]  == 23'h680000;            // d00000
    wire sel_p2   = ma[23:1]  == 23'h680001;            // d00002
    wire sel_eer  = ma[23:1]  == 23'h6C0000;            // d80000
    wire sel_lat  = ma[23:1]  == 23'h700000;            // e00000 / e00001
    wire sel_pdw  = ma[23:1]  == 23'h740000;            // e80000
    wire sel_pnd  = ma[23:1]  == 23'h780000;            // f00000 / f00001
    wire sel_pdr  = ma[23:1]  == 23'h7C0000;            // f80000

    // ---------------------------------------------------------------- bus cycle
    // cnt: the cycle's second clock and later (internal slaves answer then); ext_done remembers the ROM's one-clock ack
    logic cnt, ext_done;
    wire  ext      = sel_rom && m_rnw;
    wire  first    = m_req && !cnt;
    wire  wr_pulse = first && !m_rnw && !ext && (m_be != 2'b00);
    wire  rd_pulse = first && m_rnw;
    assign m_ack   = m_req && (ext ? (mrom_ack || ext_done) : cnt);
    always_ff @(posedge clk) begin
        if (!m_req) begin cnt <= 1'b0; ext_done <= 1'b0; end
        else begin
            cnt <= 1'b1;
            if (ext && mrom_ack) ext_done <= 1'b1;
        end
    end
    assign mrom_req  = m_req && ext && !ext_done;
    assign mrom_addr = m_addr[19:1];

    // ---------------------------------------------------------------- interrupt
    always_ff @(posedge clk) begin
        if (rst) pend1 <= 1'b0;
        else begin
            if (m_iack && m_iack_lvl == 3'd1) pend1 <= 1'b0;
            if (ev_vbl) pend1 <= 1'b1;
        end
    end

    // ---------------------------------------------------------------- RAMs (write enables registered: the cycle's address and data are stable)
    logic we_wram, we_bg1, we_bg2, we_bg3, we_l1, we_l2, we_l3, we_tx, we_spr, we_spal, we_tpal;
    always_ff @(posedge clk) begin
        we_wram <= wr_pulse && sel_wram;
        we_bg1  <= wr_pulse && sel_bg1;
        we_bg2  <= wr_pulse && sel_bg2;
        we_bg3  <= wr_pulse && sel_bg3;
        we_l1   <= wr_pulse && sel_l1;
        we_l2   <= wr_pulse && sel_l2;
        we_l3   <= wr_pulse && sel_l3;
        we_tx   <= wr_pulse && sel_tx;
        we_spr  <= wr_pulse && sel_spr;
        we_spal <= wr_pulse && sel_spal;
        we_tpal <= wr_pulse && sel_tpal;
    end
    wire [15:0] wram_q, bg1_q, bg2_q, bg3_q, l1_q, l2_q, l3_q, tx_q, spr_q, spal_q, tpal_q;
    ts_spram  #(.AW(15)) u_wram (.clk(clk), .we(we_wram), .be(m_be), .addr(m_addr[15:1]), .wdata(m_wdata), .rdata(wram_q));
    ts_spram  #(.AW(9))  u_l1   (.clk(clk), .we(we_l1),   .be(m_be), .addr(m_addr[9:1]),  .wdata(m_wdata), .rdata(l1_q));
    ts_spram  #(.AW(9))  u_l2   (.clk(clk), .we(we_l2),   .be(m_be), .addr(m_addr[9:1]),  .wdata(m_wdata), .rdata(l2_q));
    ts_spram  #(.AW(9))  u_l3   (.clk(clk), .we(we_l3),   .be(m_be), .addr(m_addr[9:1]),  .wdata(m_wdata), .rdata(l3_q));
    ts_tdpram #(.AW(11)) u_bg1  (.clk(clk),
        .a_we(we_bg1), .a_be(m_be), .a_addr(m_addr[11:1]), .a_wdata(m_wdata), .a_rdata(bg1_q),
        .b_we(1'b0), .b_be(2'b00), .b_addr(bg1_addr), .b_wdata(16'h0), .b_rdata(bg1_data));
    ts_tdpram #(.AW(11)) u_bg2  (.clk(clk),
        .a_we(we_bg2), .a_be(m_be), .a_addr(m_addr[11:1]), .a_wdata(m_wdata), .a_rdata(bg2_q),
        .b_we(1'b0), .b_be(2'b00), .b_addr(bg2_addr), .b_wdata(16'h0), .b_rdata(bg2_data));
    ts_tdpram #(.AW(11)) u_bg3  (.clk(clk),
        .a_we(we_bg3), .a_be(m_be), .a_addr(m_addr[11:1]), .a_wdata(m_wdata), .a_rdata(bg3_q),
        .b_we(1'b0), .b_be(2'b00), .b_addr(bg3_addr), .b_wdata(16'h0), .b_rdata(bg3_data));
    ts_tdpram #(.AW(13)) u_tx   (.clk(clk),
        .a_we(we_tx), .a_be(m_be), .a_addr(m_addr[13:1]), .a_wdata(m_wdata), .a_rdata(tx_q),
        .b_we(1'b0), .b_be(2'b00), .b_addr(tx_addr), .b_wdata(16'h0), .b_rdata(tx_data));
    ts_tdpram #(.AW(15)) u_spr  (.clk(clk),
        .a_we(we_spr), .a_be(m_be), .a_addr(m_addr[15:1]), .a_wdata(m_wdata), .a_rdata(spr_q),
        .b_we(1'b0), .b_be(2'b00), .b_addr(spr_addr), .b_wdata(16'h0), .b_rdata(spr_data));
    ts_tdpram #(.AW(14)) u_spal (.clk(clk),
        .a_we(we_spal), .a_be(m_be), .a_addr(m_addr[14:1]), .a_wdata(m_wdata), .a_rdata(spal_q),
        .b_we(1'b0), .b_be(2'b00), .b_addr(spal_addr), .b_wdata(16'h0), .b_rdata(spal_data));
    ts_tdpram #(.AW(11)) u_tpal (.clk(clk),
        .a_we(we_tpal), .a_be(m_be), .a_addr(m_addr[11:1]), .a_wdata(m_wdata), .a_rdata(tpal_q),
        .b_we(1'b0), .b_be(2'b00), .b_addr(tpal_addr), .b_wdata(16'h0), .b_rdata(tpal_data));

    // ---------------------------------------------------------------- registers
    function automatic [15:0] mrg(input [15:0] old, input [15:0] d, input [1:0] b);
        mrg = {b[1] ? d[15:8] : old[15:8], b[0] ? d[7:0] : old[7:0]};
    endfunction
    logic [15:0] sc [0:11];                     // scroll_0 x, y, flip, scroll_1 ..., scroll_2 ..., scroll_3 ...
    logic [15:0] r88_0, r88_1;
    logic [1:0]  list_q;
    logic        wd_kick;
    wire  [1:0]  wi = m_addr[2:1];
    always_ff @(posedge clk) begin
        wd_kick <= 1'b0;
        if (rst) begin
            for (int i = 0; i < 12; i++) sc[i] <= 16'h0;
            r88_0 <= 16'h0; r88_1 <= 16'h0; list_q <= 2'd0;
        end else if (wr_pulse) begin
            if (sel_sc0 && wi != 2'd3) sc[0 + wi] <= mrg(sc[0 + wi], m_wdata, m_be);
            if (sel_sc1 && wi != 2'd3) sc[3 + wi] <= mrg(sc[3 + wi], m_wdata, m_be);
            if (sel_sc2 && wi != 2'd3) sc[6 + wi] <= mrg(sc[6 + wi], m_wdata, m_be);
            if (sel_sc3 && wi != 2'd3) sc[9 + wi] <= mrg(sc[9 + wi], m_wdata, m_be);
            if (sel_r88 && ma[5:0] < 6'h30) begin
                case (ma[5:1])
                    5'h00: r88_0 <= mrg(r88_0, m_wdata, m_be);
                    5'h01: r88_1 <= mrg(r88_1, m_wdata, m_be);
                    5'h04: list_q <= m_wdata[1:0];          // m_spritelist = data & 3
                    5'h11: wd_kick <= 1'b1;                 // 880022
                    default: ;
                endcase
            end
        end
    end
    genvar g;
    generate for (g = 0; g < 12; g++) begin : g_sc
        assign scroll[16*g +: 16] = sc[g];
    end endgenerate
    assign spr_list = list_q;
    assign spr_xoff = r88_0;
    assign spr_yoff = r88_1;

    // ---------------------------------------------------------------- watchdog (MAME: vblank count 400)
    logic [9:0] wd_cnt;
    always_ff @(posedge clk) begin
        wd_rst <= 1'b0;
        if (rst || wd_kick) wd_cnt <= 10'd0;
        else if (ev_vbl && WDOG_FRAMES != 0) begin
            if (wd_cnt == 10'(WDOG_FRAMES - 1)) begin wd_rst <= 1'b1; wd_cnt <= 10'd0; end
            else wd_cnt <= wd_cnt + 10'd1;
        end
    end

    // ---------------------------------------------------------------- 93C46 (eeprom_w: ACCESSING_BITS_8_15 only)
    logic ee_cs, ee_clkl, ee_di, ee_clk_edge;
    always_ff @(posedge clk) begin
        ee_clk_edge <= 1'b0;
        if (rst) begin ee_cs <= 1'b0; ee_clkl <= 1'b0; ee_di <= 1'b0; end
        else if (wr_pulse && sel_eew && m_be[1]) begin
            ee_di   <= m_wdata[11];
            ee_cs   <= m_wdata[9];
            ee_clkl <= ~m_wdata[10];                        // (data & 0x0400) ? CLEAR_LINE : ASSERT_LINE
            ee_clk_edge <= ~m_wdata[10] & ~ee_clkl;         // the clock line rises
        end
    end
    wire ee_do;
    ts_eeprom u_ee (
        .clk(clk), .i_cs(ee_cs), .i_clk(ee_clk_edge), .i_di(ee_di), .o_do(ee_do),
        .i_ld_wr(1'b0), .i_ld_addr(7'd0), .i_ld_data(8'd0),
        .i_nv_wr(nv_wr), .i_nv_addr(nv_addr), .i_nv_data(nv_data), .i_nv_raddr(nv_raddr), .o_nv_rdata(nv_rdata),
        .o_written(ee_written));

    // ---------------------------------------------------------------- protection
    wire [7:0] prot_v;
    logic [7:0] prot_q;
    ts_prot u_prot (.clk(clk), .rst(rst), .game(game),
        .wr(wr_pulse && sel_pdw), .wdata(m_wdata[15:8]), .rd(rd_pulse && sel_pdr), .value(prot_v));
    always_ff @(posedge clk) if (rd_pulse && sel_pdr) prot_q <= prot_v;     // the value before the read's side effect

    // ---------------------------------------------------------------- sound latch (e00001: the low byte)
    always_ff @(posedge clk) begin
        latch_wr <= 1'b0;
        if (wr_pulse && sel_lat && m_be[0]) begin latch_wr <= 1'b1; latch_data <= m_wdata[7:0]; end
    end

    // ---------------------------------------------------------------- read data
    logic [15:0] romq;
    always_ff @(posedge clk) if (mrom_ack) romq <= mrom_data;
    always_comb begin
        m_rdata = 16'h0000;
        if (sel_rom)        m_rdata = mrom_ack ? mrom_data : romq;
        else if (sel_wram)  m_rdata = wram_q;
        else if (sel_bg1)   m_rdata = bg1_q;
        else if (sel_l1)    m_rdata = l1_q;
        else if (sel_bg2)   m_rdata = bg2_q;
        else if (sel_l2)    m_rdata = l2_q;
        else if (sel_bg3)   m_rdata = bg3_q;
        else if (sel_l3)    m_rdata = l3_q;
        else if (sel_tx)    m_rdata = tx_q;
        else if (sel_spr)   m_rdata = spr_q;
        else if (sel_r88)   m_rdata = (ma[5:1] == 5'd0) ? {15'd0, ~vblank} : 16'h0000;
        else if (sel_spal)  m_rdata = spal_q;
        else if (sel_tpal)  m_rdata = tpal_q;
        else if (sel_pst)   m_rdata = m_be[1] ? 16'h0000 : 16'h00c0;
        else if (sel_p1)    m_rdata = in_p1;
        else if (sel_p2)    m_rdata = in_p2;
        else if (sel_eer)   m_rdata = {4'd0, ee_do, 11'd0};
        else if (sel_pnd)   m_rdata = {15'd0, snd_pending};
        else if (sel_pdr)   m_rdata = {prot_q, 8'h00};
    end
endmodule
`default_nettype wire
