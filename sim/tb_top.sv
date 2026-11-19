// Whole-machine bench top: ts_core + ts_mem + the 64 MB SDRAM model (preloaded with tools/ts_rom.py's SDRAM image), the header bytes of the
// ROM stream (+HDR=), the inputs (+P1= / +P2=, or the C++ driver's per-frame overrides), and debug taps.
//
//   +IMAGE=<set.sdram>  +HDR=<set.hdr (the stream's first 256 bytes)>  +P1=<hex> +P2=<hex>
`default_nettype none
module tb_top #(
    parameter SIM_GATE = 1,
    parameter WDOG_FRAMES = 400
) (
    input  wire         clk,
    input  wire         clk_opl,
    input  wire         reset,
    input  wire [15:0]  in_p1,
    input  wire [15:0]  in_p2,

    output wire         ev_vbl,
    output wire         o_ce,
    output wire [8:0]   o_x,
    output wire [8:0]   o_y,
    output wire         o_hb,
    output wire         o_vb,
    output wire [7:0]   o_r,
    output wire [7:0]   o_g,
    output wire [7:0]   o_b,
    output wire         audio_valid,
    output wire [15:0]  audio_l,
    output wire [15:0]  audio_r,
    output wire         late,
    output wire         halted,
    output wire [15:0]  zpc,
    output wire         wd_rst,
    output wire         ee_written,
    output wire [23:0]  maddr               // the 68000's address bus (debug)
);
    assign maddr = {u_core.u_main.m_addr, 1'b0};
    // ---------------------------------------------------------------- header
    logic [7:0] hdr [0:255];
    logic [1:0] game;
    logic [127:0] slots;
    initial begin : load_hdr
        string p;
        int fd, n;
        for (int i = 0; i < 256; i++) hdr[i] = 8'h00;
        if (!$value$plusargs("HDR=%s", p)) $fatal(1, "needs +HDR=<header file>");
        fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
        n = $fread(hdr, fd); $fclose(fd);
        game = hdr[0][1:0];
        for (int s = 0; s < 8; s++) slots[16 * s +: 16] = {hdr[3 + 2 * s], hdr[2 + 2 * s]};
        $display("header: game %0d, slots %032x", game, slots);
    end

    // ---------------------------------------------------------------- core + memory system
    wire         mem_ready;
    wire         mrom_req, mrom_ack, zrom_req, zrom_ack, ymz_req, ymz_ack, oki_req, oki_ack;
    wire [19:1]  mrom_addr;
    wire [15:0]  mrom_data;
    wire [17:0]  zrom_addr;
    wire  [7:0]  zrom_data, ymz_data, oki_data;
    wire [23:0]  ymz_addr;
    wire [18:0]  oki_addr;
    wire         trom_req, trom_ack, trom_valid, srom_req, srom_ack, srom_valid;
    wire [24:0]  trom_addr, srom_addr;
    wire  [6:0]  trom_len, srom_len;
    wire [15:0]  trom_data, srom_data;
    wire core_rst = reset | ~mem_ready;

    ts_core #(.SIM_GATE(SIM_GATE), .WDOG_FRAMES(WDOG_FRAMES)) u_core (
        .clk(clk), .rst(core_rst), .clk_opl(clk_opl),
        .game(game), .slots(slots),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
        .zrom_req(zrom_req), .zrom_addr(zrom_addr), .zrom_ack(zrom_ack), .zrom_data(zrom_data),
        .ymz_req(ymz_req), .ymz_addr(ymz_addr), .ymz_ack(ymz_ack), .ymz_data(ymz_data),
        .oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack), .oki_data(oki_data),
        .trom_req(trom_req), .trom_addr(trom_addr), .trom_len(trom_len), .trom_ack(trom_ack), .trom_valid(trom_valid), .trom_data(trom_data),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_len(srom_len), .srom_ack(srom_ack), .srom_valid(srom_valid), .srom_data(srom_data),
        .in_p1(in_p1), .in_p2(in_p2),
        .nv_wr(1'b0), .nv_addr(7'd0), .nv_data(8'd0), .nv_raddr(7'd0), .nv_rdata(), .ee_written(ee_written),
        .audio_valid(audio_valid), .audio_l(audio_l), .audio_r(audio_r),
        .o_ce(o_ce), .o_x(o_x), .o_y(o_y), .o_hs(), .o_vs(), .o_hb(o_hb), .o_vb(o_vb), .o_r(o_r), .o_g(o_g), .o_b(o_b),
        .wd_rst(wd_rst), .ev_vbl_o(ev_vbl), .dbg_late(late), .dbg_halted(halted), .dbg_zpc(zpc));

    wire [12:0] sd_a; wire [1:0] sd_ba; wire [15:0] sd_dq; wire sd_dqml, sd_dqmh, sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_cke;
    wire [31:0] st_busy, st_words;
    ts_mem #(.SHORT_INIT(1)) u_mem (
        .clk(clk), .rst(reset), .ready(mem_ready), .i_rd_late(1'b0),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
        .zrom_req(zrom_req), .zrom_addr(zrom_addr), .zrom_ack(zrom_ack), .zrom_data(zrom_data),
        .ymz_req(ymz_req), .ymz_addr(ymz_addr), .ymz_ack(ymz_ack), .ymz_data(ymz_data),
        .oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack), .oki_data(oki_data),
        .trom_req(trom_req), .trom_addr(trom_addr), .trom_len(trom_len), .trom_ack(trom_ack), .trom_valid(trom_valid), .trom_data(trom_data),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_len(srom_len), .srom_ack(srom_ack), .srom_valid(srom_valid), .srom_data(srom_data),
        .dl_wr(1'b0), .dl_addr(26'd0), .dl_data(8'd0), .dl_busy(),
        .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_DQ(sd_dq), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh),
        .SDRAM_nCS(sd_ncs), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_nWE(sd_nwe), .SDRAM_CKE(sd_cke),
        .stat_busy(st_busy), .stat_words(st_words));
    ts_sdram_model u_sdram (.clk(clk), .A(sd_a), .BA(sd_ba), .DQ(sd_dq), .DQML(sd_dqml), .DQMH(sd_dqmh),
        .nCS(sd_ncs), .nRAS(sd_nras), .nCAS(sd_ncas), .nWE(sd_nwe), .CKE(sd_cke));
    initial begin : fill
        string p;
        int fd, n;
        if (!$value$plusargs("IMAGE=%s", p)) $fatal(1, "needs +IMAGE=<sdram image>");
        fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
        n = $fread(u_sdram.mem_b, fd); $fclose(fd);
        $display("SDRAM image: %0d bytes", n);
    end
    final $display("SDRAM stats: busy %0d clocks, %0d words", st_busy, st_words);

    // ---------------------------------------------------------------- the Z80's writes to the sound chips (+SNDLOG=<file>: "frame port data",
    // as tools/lua/sndlog.lua writes MAME's; tools/cmp_sndlog.py compares them)
    integer sfd, sframe;
    initial begin : open_snd
        string p;
        sfd = 0; sframe = 0;
        if ($value$plusargs("SNDLOG=%s", p)) sfd = $fopen(p, "w");
    end
    always @(posedge clk) begin
        if (ev_vbl) sframe <= sframe + 1;
        if (sfd != 0 && u_core.u_sound.io_wr_p) begin
            case (u_core.u_sound.port)
                8'h00, 8'h01, 8'h02, 8'h03, 8'h10, 8'h20, 8'h30, 8'h50, 8'h60, 8'h61:
                    $fdisplay(sfd, "%0d %02x %02x", sframe, u_core.u_sound.port, u_core.u_sound.cpu_do);
                default: ;
            endcase
        end
    end

    // ---------------------------------------------------------------- the three chips' outputs at each 48 kHz output sample (+CHIPS=<file>:
    // "ymz_l ymz_r opl_l opl_r oki" per line, the values ts_audio48 holds; tools/fit_mix.py fits the mixer's gains to MAME's recording)
    integer cfd;
    initial begin : open_chips
        string p;
        cfd = 0;
        if ($value$plusargs("CHIPS=%s", p)) cfd = $fopen(p, "w");
    end
    always @(posedge clk)
        if (cfd != 0 && audio_valid)
            $fdisplay(cfd, "%0d %0d %0d %0d %0d", u_core.ymz_l, u_core.ymz_r, u_core.opl_l, u_core.opl_r, u_core.oki_out);

    // ---------------------------------------------------------------- the 68000's program fetches: clocks from a ROM read's request to the
    // cache's answer (fx68k samples DTACK about 9 clocks into the cycle: a later answer costs wait states the board does not have)
    longint r_n, r_clk, r_slow, r_max; integer r_cur;
    initial begin r_n = 0; r_clk = 0; r_slow = 0; r_max = 0; r_cur = 0; end
    always @(posedge clk) begin
        if (u_core.u_main.mrom_req) r_cur <= r_cur + 1;
        if (u_core.u_main.mrom_ack) begin
            r_n <= r_n + 1; r_clk <= r_clk + r_cur + 1;
            if (r_cur + 1 > 6) r_slow <= r_slow + 1;
            if (r_cur + 1 > r_max) r_max <= r_cur + 1;
            r_cur <= 0;
        end
    end
    final $display("68000 ROM reads: %0d, %0d clocks req -> ack (mean %0.2f), %0d over 6 clocks, longest %0d", r_n, r_clk,
                   r_n ? real'(r_clk) / real'(r_n) : 0.0, r_slow, r_max);
    // and the bus cycles' lengths (the request stays up to the end of the cycle: a zero-wait cycle is the shortest; each wait state 6 more)
    longint c_hist [0:15]; integer c_len; logic c_rom;
    initial begin for (int i = 0; i < 16; i++) c_hist[i] = 0; c_len = 0; c_rom = 0; end
    always @(posedge clk) begin
        if (u_core.u_main.m_req) begin c_len <= c_len + 1; if (u_core.u_main.ext) c_rom <= 1; end
        else if (c_len != 0) begin
            if (c_rom) c_hist[(c_len / 6) > 15 ? 15 : c_len / 6] <= c_hist[(c_len / 6) > 15 ? 15 : c_len / 6] + 1;
            c_len <= 0; c_rom <= 0;
        end
    end
    final begin
        $write("68000 ROM read cycles by length (clocks / 6):");
        for (int i = 0; i < 16; i++) if (c_hist[i] != 0) $write(" %0d:%0d", i, c_hist[i]);
        $display("");
    end

    // the Z80's: clock enables that fell while its ROM cache held WAIT low (each one a wait state the board does not have)
    longint z_wait, z_cen;
    initial begin z_wait = 0; z_cen = 0; end
    always @(posedge clk) if (u_core.u_sound.cen_z80) begin
        z_cen <= z_cen + 1;
        if (!u_core.u_sound.wait_n) z_wait <= z_wait + 1;
    end
    final $display("Z80: %0d clock enables, %0d of them with WAIT low (%0.3f %%)", z_cen, z_wait, z_cen ? 100.0 * real'(z_wait) / real'(z_cen) : 0.0);

    // ---------------------------------------------------------------- render budget: clocks a line takes (tiles, sprites)
    integer t_run, t_max, s_run, s_max, n_late;
    initial begin t_run = 0; t_max = 0; s_run = 0; s_max = 0; n_late = 0; end
    always @(posedge clk) begin
        if (u_core.u_video.t_busy) t_run <= t_run + 1;
        else begin if (t_run > t_max) t_max <= t_run; t_run <= 0; end
        if (u_core.u_video.s_busy) s_run <= s_run + 1;
        else begin if (s_run > s_max) s_max <= s_run; s_run <= 0; end
        if (u_core.u_video.draw && (u_core.u_video.t_busy || u_core.u_video.s_busy)) n_late <= n_late + 1;
    end
    final $display("line render: tiles longest %0d clocks, sprites longest %0d clocks (budget 6144), late lines %0d", t_max, s_max, n_late);

    // ---------------------------------------------------------------- the sample chips' ROM reads in time
    // YMZ280B: a sample tick while the previous sample is still being made (ts_ymz280b's `overrun` condition, counted).
    // OKI: jt6295 takes its ADPCM byte at the end of its two ADPCM slots without waiting for the ROM (jt6295_rom: no adpcm_ok); a byte not
    // yet served for the slot's address at that clock (ts_sound `oki_ok` low) is a stale byte decoded.  Also the longest ADPCM-slot wait.
    longint ymz_late, oki_take, oki_stale;
    integer oki_wait, oki_wmax;
    initial begin ymz_late = 0; oki_take = 0; oki_stale = 0; oki_wait = 0; oki_wmax = 0; end
    always @(posedge clk) begin
        if (u_core.u_sound.u_ymz.tick && (u_core.u_sound.u_ymz.tick_q || u_core.u_sound.u_ymz.st != 5'd0)) ymz_late <= ymz_late + 1;
        // (not while the sound board is in reset: jt6295_rom's slot sequencer has no reset and keeps turning, the byte server is cleared)
        if ((u_core.u_sound.u_oki.u_rom.st == 8'b10) && u_core.u_sound.u_oki.cen_sr32 && !u_core.u_sound.rst) begin
            oki_take <= oki_take + 1;
            if (!u_core.u_sound.oki_ok) oki_stale <= oki_stale + 1;
        end
        if (u_core.u_sound.u_oki.u_rom.st == 8'b1 || u_core.u_sound.u_oki.u_rom.st == 8'b10) begin
            if (!u_core.u_sound.oki_ok) oki_wait <= oki_wait + 1;
            else begin if (oki_wait > oki_wmax) oki_wmax <= oki_wait; oki_wait <= 0; end
        end else oki_wait <= 0;
    end
    final $display("sample ROMs: YMZ280B late samples %0d; OKI ADPCM bytes taken %0d, stale %0d, longest wait in the slots %0d clocks (window 384)",
                   ymz_late, oki_take, oki_stale, oki_wmax);

    // ---------------------------------------------------------------- the OKI's output at its own rate (+OKILOG=<file>: "frame sound" per
    // 15.15 kHz sample, jt6295 `sound` as it is at the sample enable, i.e. the sample before; tools/oki_decode.py compares a phrase with MAME's
    // ADPCM decode of the ROM)
    integer ofd;
    initial begin : open_oki
        string p;
        ofd = 0;
        if ($value$plusargs("OKILOG=%s", p)) ofd = $fopen(p, "w");
    end
    always @(posedge clk)
        if (ofd != 0 && u_core.u_sound.u_oki.cen_sr) $fdisplay(ofd, "%0d %0d", sframe, u_core.u_sound.oki_out);
endmodule
`default_nettype wire
