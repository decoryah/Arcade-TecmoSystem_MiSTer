// Bench top for the MiSTer top module itself (TecmoSys.sv, `emu`): the real emu + ts_core + ts_mem, the 64 MB SDRAM model, and behavioural
// stand-ins for the framework's pll / hps_io / arcade_video (emu_stubs.sv).  The ROM stream the "HPS" plays is the MRA's (tools/ts_rom.py
// --stream, which tools/make_mra.py --check proves equal to the MRAs): the header, the loader's address remap (BG tile rows, the sprite area),
// the nvram, the resets and the picture all go through the shipping code.  (After the owner's jchan-mister sim/tb_jchan_emu_top.sv.)
//
//   +STREAM=<stream> [+FAST=1] [+VERIFY=<sdram image of tools/ts_rom.py>] [+NVM=f +NVMOUT=f] [+STATUS=hex] [+GAP=n]
`default_nettype none
module tb_emu_top (
    input  wire         clk,
    input  wire         reset,
    input  wire         joy_en,
    input  wire [31:0]  joy0,
    input  wire [31:0]  joy1,
    output wire         o_ce,
    output wire         o_hb,
    output wire         o_vb,
    output wire [8:0]   o_x,
    output wire [8:0]   o_y,
    output wire [7:0]   o_r,
    output wire [7:0]   o_g,
    output wire [7:0]   o_b,
    output wire         ev_vbl,
    output wire         core_rst,
    output wire         led_user,
    output wire         verified
);
    wire [12:0] sd_a; wire [1:0] sd_ba; wire [15:0] sd_dq; wire sd_dqml, sd_dqmh, sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_cke, sd_clk;
    wire [7:0] vga_r, vga_g, vga_b;
    wire vga_hs, vga_vs, vga_de, clk_video, ce_pixel;
    wire [15:0] audio_l, audio_r;
    wire [12:0] arx, ary;
    wire        ddr_clk, ddr_rd, ddr_we;
    wire [7:0]  ddr_burst, ddr_be;
    wire [28:0] ddr_addr;
    wire [63:0] ddr_din;
    reg         ddr_busy;
    reg  [63:0] ddr_dout;
    reg         ddr_dready;

    emu u_emu (
        .CLK_50M(clk), .RESET(reset),
        .CLK_VIDEO(clk_video), .CE_PIXEL(ce_pixel), .VIDEO_ARX(arx), .VIDEO_ARY(ary),
        .HDMI_WIDTH(12'd0), .HDMI_HEIGHT(12'd0),
        .DDRAM_CLK(ddr_clk), .DDRAM_BUSY(ddr_busy), .DDRAM_BURSTCNT(ddr_burst), .DDRAM_ADDR(ddr_addr), .DDRAM_DOUT(ddr_dout),
        .DDRAM_DOUT_READY(ddr_dready), .DDRAM_RD(ddr_rd), .DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we),
        .VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b), .VGA_HS(vga_hs), .VGA_VS(vga_vs), .VGA_DE(vga_de),
        .AUDIO_L(audio_l), .AUDIO_R(audio_r), .LED_USER(led_user),
        .SDRAM_CLK(sd_clk), .SDRAM_CKE(sd_cke), .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_DQ(sd_dq), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh),
        .SDRAM_nCS(sd_ncs), .SDRAM_nCAS(sd_ncas), .SDRAM_nRAS(sd_nras), .SDRAM_nWE(sd_nwe));

    ts_sdram_model u_sdram (.clk(clk), .A(sd_a), .BA(sd_ba), .DQ(sd_dq), .DQML(sd_dqml), .DQMH(sd_dqmh),
        .nCS(sd_ncs), .nRAS(sd_nras), .nCAS(sd_ncas), .nWE(sd_nwe), .CKE(sd_cke));

    // the DDR3 as the fast load sees it (jchan-mister's model): one command at a time, busy at random, a few clocks of latency, one beat a
    // clock with the odd bubble; the image is the hps_io stand-in's `rom` at byte 0x32000000
    localparam [28:0] IMG_BASE = 29'h6400000;
    integer ds, dlat, dleft, dnext, bk;
    reg [28:0] da;
    reg [31:0] lf;
    initial begin ds = 0; ddr_busy = 1'b0; ddr_dready = 1'b0; ddr_dout = 64'd0; lf = 32'h1234abcd; dleft = 0; dnext = 0; dlat = 0; end
    always @(posedge clk) begin
        lf <= {lf[30:0], lf[31] ^ lf[21] ^ lf[1] ^ lf[0]};
        ddr_dready <= 1'b0;
        case (ds)
            0: begin
                ddr_busy <= lf[3] & lf[7];
                if (ddr_rd && !ddr_busy) begin
                    da <= ddr_addr; dleft <= ddr_burst; dnext <= 0; dlat <= 4 + (lf[5:3] & 3'd7); ddr_busy <= 1'b1; ds <= 1;
                end
            end
            1: begin
                if (dlat != 0) dlat <= dlat - 1;
                else if (dleft != 0 && lf[9:8] != 2'd0) begin
                    for (bk = 0; bk < 8; bk = bk + 1)
                        ddr_dout[8*bk +: 8] <= u_emu.hps_io.rom[(da - IMG_BASE + dnext) * 8 + bk];
                    ddr_dready <= 1'b1; dnext <= dnext + 1; dleft <= dleft - 1;
                    if (dleft == 1) begin ddr_busy <= 1'b0; ds <= 0; end
                end
            end
            default: ds <= 0;
        endcase
    end

    assign o_ce = u_emu.o_ce;
    assign o_hb = u_emu.o_hb;
    assign o_vb = u_emu.o_vb;
    assign o_x  = u_emu.o_x;
    assign o_y  = u_emu.o_y;
    assign o_r  = u_emu.o_r;
    assign o_g  = u_emu.o_g;
    assign o_b  = u_emu.o_b;
    assign ev_vbl = u_emu.frame_tick;
    assign core_rst = u_emu.core_rst_r;

    // when the core is first released: the SDRAM model's contents against tools/ts_rom.py's image (+VERIFY=), over the loaded windows
    // (image 0 - 0xA00000, the sprite area from 0x1000000 to the image file's end)
    integer vfd;
    logic   core_rst_q, ver;
    assign verified = ver;
    initial begin core_rst_q = 1'b1; ver = 1'b0; end
    always @(posedge clk) begin
        core_rst_q <= core_rst;
        if (core_rst_q && !core_rst && !ver) begin
            string p;
            integer fd, bad, i, n, total;
            ver <= 1'b1;
            if ($value$plusargs("VERIFY=%s", p)) begin
                fd = $fopen(p, "rb");
                bad = 0; total = 0;
                for (i = 0; i < 64 * 1024 * 1024; i++) begin
                    n = $fgetc(fd);
                    if (n < 0) break;
                    if (i < 32'hA00000 || i >= 32'h1000000) begin
                        total = total + 1;
                        if (n != u_sdram.mem_b[i]) begin
                            if (bad < 5) $display("VERIFY: SDRAM byte 0x%0x is %02x, image has %02x", i, u_sdram.mem_b[i], n);
                            bad = bad + 1;
                        end
                    end
                end
                $fclose(fd);
                $display("VERIFY: %0d of %0d bytes in the loaded windows differ", bad, total);
            end
            $display("header: game %0d, slots %032x", u_emu.game, u_emu.slots);
        end
    end
endmodule
`default_nettype wire
