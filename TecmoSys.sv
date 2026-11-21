//============================================================================
//
//  Tecmo System (Deroon DeroDero / Tecmo Stackers, Toukidenshou - Angel Eyes) for MiSTer.
//
//  Written for MiSTer from MAME 0.289's driver (src/mame/tecmo/tecmosys.cpp, tecmosys_v.cpp, tecmosys_m.cpp).  The 68000 is fx68k (Jorge
//  Cwik), the Z80 TV80 (Guy Hutchison), the OKI M6295 jt6295 (Jose Tejada), the YMF262 opl3_fpga (Greg Taylor, MiSTer ao486's copy); the
//  platform layer (SDRAM controller, loader, fast load, standby raster, CRT Adjust glue) and the YMZ280B follow the owner's jchan-mister core.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_DIN, DDRAM_BE, DDRAM_WE} = 0;      // read only: the fast load (below)

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;

// Aspect ratio and Scale (as the owner's other cores: video_freak turns them into VIDEO_ARX / ARY)
reg   [2:0] scale_sel;
always @* case (status[34:32])
	3'd1:    scale_sel = 3'd1;   // V-Integer
	3'd2:    scale_sel = 3'd4;   // HV-Integer
	3'd3:    scale_sel = 3'd2;   // Narrower HV-Integer
	3'd4:    scale_sel = 3'd3;   // HV-Integer+
	default: scale_sel = 3'd0;   // Normal
endcase
wire  [1:0] ar         = status[122:121];
// Video Timing (rtl/ts_cen.sv, ts_pixgen): 0 Original (the board's 7 MHz dots, 448 x 272, 15.625 kHz), 1 RT4K DV1 (6 MHz dots, 395 x 264,
// 15.166 kHz: what a RetroTINK 4K on direct video takes as "MiSTer (240p)" and shows whole and 4:3).  Both 57.44 Hz; taken at a frame's start.
wire        vt_rt4k    = status[40];
wire        fs_int     = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);
wire [11:0] arx        = fs_int ? HDMI_WIDTH  : (!ar) ? 12'd4 : (ar - 1'd1);
wire [11:0] ary        = fs_int ? HDMI_HEIGHT : (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"TecmoSys;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[40],Video Timing,Original,RT4K DV1;",
	"D2P1,CRT Adjust;",
	"D2P1O[14],CRT Adjust,Off,On;",
	"H1P1O[19:15],CRT H-Size,0,+1,+2,+3,+4,+5,+6,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[27:21],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[39:35],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"O[9:8],Volume,Normal,-6 dB,-12 dB,+6 dB;",
	"O[20],SDRAM read capture,Normal,Late;",
	"O[10],Service Mode,Off,On;",
	"-;",
	"R0,Reset;",
	"J1,Button A,Button B,Button C,Button D,Start,Coin,Start 1P+2P;",
	"jn,A,B,X,Y,Start,Select,R;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 96 MHz: the machine (68000 at 96 / 6 = 16 MHz, Z80 8 MHz, OKI 2 MHz, dots 7 MHz)
wire clk_sdram;         // 96 MHz, shifted: the SDRAM chip's clock pin
wire clk_opl;           // 24 MHz: the YMF262 (its 14.31818 MHz / 288 sample rate is a fractional enable of it)
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.outclk_2(clk_opl),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_upload;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire   [7:0] ioctl_din;
wire         ioctl_rd;
wire         dl_busy;
reg          ioctl_upload_req;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.new_vmode(vt_rt4k),                                          // a Video Timing change makes Main_MiSTer re-read the video and resend
	                                                               // direct video's DV1 infoframe (both rasters are 320 x 240, which alone
	                                                               // does not count as a change: the RT4K kept the old one's pixel repeat)
	.status_menumask({13'd0, vt_rt4k, ~status[14], direct_video}), // bit 1: the CRT Adjust values are hidden while it is Off; bit 2: it is
	                                                               // greyed out with the RT4K DV1 timing (set up for the Original raster)
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(dl_busy),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd2),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 1 / 2 start, 5 coin, 9 service coin, F2 test (MAME's defaults; the board has one coin slot)
reg key_start1, key_start2, key_coin1, key_service, key_test;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h016: key_start1  <= ps2_key[9];      // 1
			9'h01E: key_start2  <= ps2_key[9];      // 2
			9'h02E: key_coin1   <= ps2_key[9];      // 5
			9'h046: key_service <= ps2_key[9];      // 9
			9'h006: key_test    <= ps2_key[9];      // F2
			default: ;
		endcase
	end
end

// MiSTer's joystick bits: 0 right, 1 left, 2 down, 3 up, 4 - 7 buttons 1 - 4, 8 start, 9 coin, 10 start 1P+2P (CONF_STR's J1, named per
// game by the MRA's <buttons>: tools/make_mra.py).  The service coin is the keyboard's 9 only, the test switch F2 or the OSD's Service Mode.
// MAME's ports (tecmosys.cpp INPUT_PORTS, all active low):
//   P1  bit 0 up, 1 down, 2 left, 3 right, 4 - 6 buttons 1 - 3, 7 start 1, 8 coin 1, 9 SERVICE (the test switch), 10 button 4
//   P2  the same for player 2, bit 8 unused, 9 SERVICE1 (service coin), 10 button 4
// "To enter test mode, you have to press the test switch before you insert any coins" (MAME; both games enter it from attract with no
// credits, Deroon also from a held switch; the OSD's Service Mode holds it).
//
// Start 1P+2P presses both starts: Angel Eyes' I/O check ("1P & 2P START TO EXIT") leaves only when start 1 and start 2 go down in the
// same frame (its input routine at 0x30C0, run from the vblank interrupt, reads P1 then P2 about 40 us apart and keeps each port's new
// presses for that frame; in MAME a press one frame apart stays in the test, the same frame leaves).  One player cannot press two pads'
// Starts within a frame.  The button is sampled at the start of the vertical blank, the same pulse that raises the interrupt, so both
// reads of a frame see it together.  Deroon's I/O check exits on start 1 and button 1, and its MRAs hide this button.
wire        frame_tick;
reg         both_starts;
always @(posedge clk_sys) if (frame_tick) both_starts <= joystick_0[10] | joystick_1[10];
wire [15:0] in_p1_c = ~{5'b00000, joystick_0[7], key_test | status[10], joystick_0[9] | key_coin1,
                        joystick_0[8] | key_start1 | both_starts,
                        joystick_0[6:4], joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]};
wire [15:0] in_p2_c = ~{5'b00000, joystick_1[7], key_service, 1'b0,
                        joystick_1[8] | key_start2 | both_starts,
                        joystick_1[6:4], joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3]};
reg  [15:0] in_p1, in_p2;
always @(posedge clk_sys) begin in_p1 <= in_p1_c; in_p2 <= in_p2_c; end

///////////////////////   MEMORY / LOADER   ///////////////////////

// MRA index 0 is the ROM stream (tools/make_mra.py):
//   0x0000000 - 0x00000FF   header: byte 0 the protection table (0 deroon, 1 tkdensho, 2 tkdenshoa), bytes 2 - 17 the sprite slot table
//                           (slot s: byte 2 + 2s = mode | half << 2, byte 3 + 2s = SDRAM base in MB above 0x1000000; ts_sprites.sv)
//   0x0000100 - 0x0A000FF   the SDRAM image 0x0000000 - 0x09FFFFF (ts_mem.sv): program, Z80, OKI, tiles, YMZ280B samples
//   0x0A00100 - ...         the sprite slots -> SDRAM 0x1000000 + ...
// The BG tile ROMs (image 0x0300000 - 0x05FFFFF) are written with each 16 x 16 tile's rows contiguous: MAME's tile is four 8 x 8 blocks
// (TL, TR, BL, BR, 32 bytes each, 4 bytes a row); byte o of a tile goes to {o[6], o[4:2], o[5], o[1:0]}, so row r is the 8 bytes at r * 8.
// MRA index 2: the 93C46 image (128 bytes, little-endian words: MAME's nvram/<set>/eeprom), saved by the core after the game stored it.
wire        rom_dl   = ioctl_download && (ioctl_index[7:0] == 8'd0);
wire        nv_dl    = ioctl_download && (ioctl_index[7:0] == 8'd2);

// Fast load (the owner's jchan-mister): with address="0x32000000" on the MRA's index-0 <rom>, Main_MiSTer puts the whole stream into the
// DDR3 and ends a download that has no data bytes, only the image's length in ioctl_addr; ts_fastload then plays it into the loader.
reg         rom_dl_d;
always @(posedge clk_sys) rom_dl_d <= rom_dl;
wire        dl_start = rom_dl && !rom_dl_d;
wire        dl_end   = !rom_dl && rom_dl_d;
reg         fast_dl = 1'b0;
reg  [25:0] fast_len;
wire        fl_done, fl_active, fl_wr;
wire [26:0] fl_addr;
wire  [7:0] fl_data;
always @(posedge clk_sys) begin
	if (dl_start) begin fast_dl <= (ioctl_addr != 27'd0); fast_len <= ioctl_addr[25:0]; end
	else if (fl_done) fast_dl <= 1'b0;
end

wire        ld_act = fast_dl ? fl_active : rom_dl;
wire        ld_we  = fast_dl ? fl_wr     : ioctl_wr;
wire [26:0] ld_a   = fast_dl ? fl_addr   : ioctl_addr;
wire  [7:0] ld_d   = fast_dl ? fl_data   : ioctl_dout;

localparam [26:0] STR_IMG = 27'h0000100, STR_SPR = 27'h0A00100;
wire [26:0] img_a  = ld_a - STR_IMG;
wire        is_bg  = (img_a >= 27'h0300000) && (img_a < 27'h0600000);
wire [25:0] a_map  = (ld_a >= STR_SPR) ? (img_a[25:0] + 26'h0600000) :
                     is_bg            ? {img_a[25:7], img_a[6], img_a[4:2], img_a[5], img_a[1:0]} : img_a[25:0];

reg         ld_wr_q;            // the loader's write, registered once
reg  [25:0] ld_addr_q;
reg   [7:0] ld_data_q;
reg   [7:0] hdr [0:17];
always @(posedge clk_sys) begin
	ld_wr_q   <= ld_we && ld_act && (ld_a >= STR_IMG);
	ld_addr_q <= a_map;
	ld_data_q <= ld_d;
	if (ld_we && ld_act && ld_a < 27'd18) hdr[ld_a[4:0]] <= ld_d;
end
reg   [1:0] game;
reg [127:0] slots;
always @(posedge clk_sys) begin
	game <= hdr[0][1:0];
	for (int s = 0; s < 8; s++) slots[16 * s +: 16] <= {hdr[3 + 2 * s], hdr[2 + 2 * s]};
end

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

// resets: the memory system by the power-up / PLL and the OSD's Reset (never while an image streams in); the machine is held while a stream
// is received, until the SDRAM is up and after any reset.  (The watchdog's machine reset is ts_core's own.)
wire        reset_sw = RESET | status[0] | buttons[1];
wire        wd_rst;
reg         mem_rst_r = 1'b1;
reg         core_rst_r = 1'b1;
always @(posedge clk_sys) begin
	mem_rst_r  <= ~pll_locked | (reset_sw & ~ioctl_download & ~fast_dl);
	core_rst_r <= reset_sw | ioctl_download | fast_dl | ~mem_ready | ~pll_locked | mem_rst_r;
end

wire         ee_written;
wire   [7:0] nv_rdata;
wire         audio_valid;
wire signed [15:0] audio_l, audio_r;
wire         o_ce, o_hs, o_vs, o_hb, o_vb;
wire  [8:0]  o_x, o_y;
wire  [7:0]  o_r, o_g, o_b;

ts_core u_core
(
	.clk(clk_sys), .rst(core_rst_r), .clk_opl(clk_opl),
	.game(game), .slots(slots), .vmode(vt_rt4k),
	.mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
	.zrom_req(zrom_req), .zrom_addr(zrom_addr), .zrom_ack(zrom_ack), .zrom_data(zrom_data),
	.ymz_req(ymz_req), .ymz_addr(ymz_addr), .ymz_ack(ymz_ack), .ymz_data(ymz_data),
	.oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack), .oki_data(oki_data),
	.trom_req(trom_req), .trom_addr(trom_addr), .trom_len(trom_len), .trom_ack(trom_ack), .trom_valid(trom_valid), .trom_data(trom_data),
	.srom_req(srom_req), .srom_addr(srom_addr), .srom_len(srom_len), .srom_ack(srom_ack), .srom_valid(srom_valid), .srom_data(srom_data),
	.in_p1(in_p1), .in_p2(in_p2),
	.nv_wr(nv_dl && ioctl_wr && (ioctl_addr[26:7] == 20'd0)), .nv_addr(ioctl_addr[6:0]), .nv_data(ioctl_dout),
	.nv_raddr(ioctl_addr[6:0]), .nv_rdata(nv_rdata), .ee_written(ee_written),
	.audio_valid(audio_valid), .audio_l(audio_l), .audio_r(audio_r),
	.o_ce(o_ce), .o_x(o_x), .o_y(o_y), .o_hs(o_hs), .o_vs(o_vs), .o_hb(o_hb), .o_vb(o_vb), .o_r(o_r), .o_g(o_g), .o_b(o_b),
	.wd_rst(wd_rst), .ev_vbl_o(frame_tick), .dbg_late(), .dbg_halted(), .dbg_zpc()
);

ts_mem u_mem
(
	.clk(clk_sys), .rst(mem_rst_r), .ready(mem_ready), .i_rd_late(status[20]),
	.mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
	.zrom_req(zrom_req), .zrom_addr(zrom_addr), .zrom_ack(zrom_ack), .zrom_data(zrom_data),
	.ymz_req(ymz_req), .ymz_addr(ymz_addr), .ymz_ack(ymz_ack), .ymz_data(ymz_data),
	.oki_req(oki_req), .oki_addr(oki_addr), .oki_ack(oki_ack), .oki_data(oki_data),
	.trom_req(trom_req), .trom_addr(trom_addr), .trom_len(trom_len), .trom_ack(trom_ack), .trom_valid(trom_valid), .trom_data(trom_data),
	.srom_req(srom_req), .srom_addr(srom_addr), .srom_len(srom_len), .srom_ack(srom_ack), .srom_valid(srom_valid), .srom_data(srom_data),
	.dl_wr(ld_wr_q), .dl_addr(ld_addr_q), .dl_data(ld_data_q), .dl_busy(dl_busy),
	.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
	.stat_busy(), .stat_words()
);

ts_fastload u_fl
(
	.clk(clk_sys), .rst(mem_rst_r), .go(fast_dl && dl_end), .len(fast_len),
	.active(fl_active), .wr(fl_wr), .addr(fl_addr), .data(fl_data), .busy(dl_busy), .done(fl_done),
	.ddr_rd(DDRAM_RD), .ddr_addr(DDRAM_ADDR), .ddr_burst(DDRAM_BURSTCNT), .ddr_busy(DDRAM_BUSY),
	.ddr_dout(DDRAM_DOUT), .ddr_dready(DDRAM_DOUT_READY)
);
assign DDRAM_CLK = clk_sys;

///////////////////////   NVRAM   ///////////////////////

// the 93C46's image goes to the HPS a second after the game's last write to it
assign ioctl_din = nv_rdata;
reg [26:0] save_timer;
always @(posedge clk_sys) begin
	ioctl_upload_req <= 1'b0;
	if (core_rst_r) save_timer <= 27'd0;
	else if (ee_written) save_timer <= 27'd96_000_000;
	else if (save_timer != 27'd0) begin
		save_timer <= save_timer - 27'd1;
		if (save_timer == 27'd1) ioctl_upload_req <= 1'b1;
	end
end

///////////////////////   AUDIO   ///////////////////////

// the board's mix at 48 kHz (ts_audio48); Volume: normal, -6, -12, +6 dB (saturating)
reg signed [15:0] snd_l, snd_r;
function signed [15:0] gain(input signed [15:0] s, input [1:0] g);
	reg signed [16:0] t;
	begin
		case (g)
			2'd1:    gain = s >>> 1;
			2'd2:    gain = s >>> 2;
			2'd3:    begin t = {s, 1'b0}; gain = (t > 17'sd32767) ? 16'h7FFF : (t < -17'sd32768) ? 16'h8000 : t[15:0]; end
			default: gain = s;
		endcase
	end
endfunction
always @(posedge clk_sys) begin
	if (audio_valid) begin
		snd_l <= gain(audio_l, status[9:8]);
		snd_r <= gain(audio_r, status[9:8]);
	end
end
assign AUDIO_L = snd_l;
assign AUDIO_R = snd_r;

///////////////////////   VIDEO   ///////////////////////

// while the machine is held (the image streaming in, the OSD's Reset) its raster does not run: a blank one of the same timing keeps the
// framework's OSD (its "Loading" pop-up) alive (rtl/ts_standby.sv)
wire        sb_ce, sb_hblank, sb_vblank, sb_hs, sb_vs;
ts_standby u_standby (.clk(clk_sys), .vmode_req(vt_rt4k), .o_ce(sb_ce), .o_hblank(sb_hblank), .o_vblank(sb_vblank), .o_hs(sb_hs), .o_vs(sb_vs));
reg         sb_on = 1'b1;
always @(posedge clk_sys) sb_on <= core_rst_r;

wire        vid_ce      = sb_on ? sb_ce      : o_ce;
wire        vid_hblank  = sb_on ? sb_hblank  : o_hb;
wire        vid_vblank  = sb_on ? sb_vblank  : o_vb;
wire        vid_hs      = sb_on ? sb_hs      : o_hs;
wire        vid_vs      = sb_on ? sb_vs      : o_vs;
wire [23:0] vid_rgb     = sb_on ? 24'd0      : {o_r, o_g, o_b};

reg [23:0] vq_rgb;
reg        vq_hb, vq_vb, vq_vbn, vq_hs, vq_vs, vq_ce;
always @(posedge clk_sys) begin
	vq_rgb <= vid_rgb; vq_hb <= vid_hblank; vq_vb <= vid_vblank; vq_hs <= vid_hs; vq_vs <= vid_vs; vq_ce <= vid_ce;
	vq_vbn <= (o_y >= 9'd239) && (o_y <= 9'd270);
end

// CRT Adjust (rmonic79's MiSTer-CRT-Adjust, modules/crt_adjust), set up as in the owner's jchan-mister for the Original raster (held off with
// the RT4K DV1 timing, whose analog picture is not meant for a CRT's adjustments): 448 dots of 13 clocks
// in a 6144-clock line (320 idle clocks = 24.6 dots in front of the first dot: CRT_HBIAS = 25 - 1), 272 lines.  The bias is computed, not
// measured on a bench yet (docs/status.md).
localparam signed [8:0] CRT_HBIAS = 9'sd24;
wire crt_sd = (|status[5:3]) | forced_scandoubler;
wire        [4:0] crt_hs_i = status[19:15];
wire signed [5:0] crt_hsz = (crt_hs_i <= 5'd6) ? $signed({1'b0, crt_hs_i}) : $signed({1'b0, crt_hs_i}) - 6'sd23;
wire        [6:0] crt_hp = status[27:21];
wire signed [8:0] crt_hpos = (crt_hp <= 7'd20) ? $signed({2'b00, crt_hp}) : $signed({2'b00, crt_hp}) - 9'sd69;
wire signed [6:0] crt_vs_t = 7'sd0 - $signed({status[39], status[39], status[39:35]});
reg               crt_on;
reg signed  [4:0] crt_hsize;
reg signed  [8:0] crt_hoff;
reg signed  [5:0] crt_voff;
always @(posedge clk_sys) if (vq_ce) begin
	crt_on    <= status[14] & ~crt_sd & ~sb_on & ~vt_rt4k;
	crt_hsize <= crt_hsz[4:0];
	crt_hoff  <= crt_hpos + CRT_HBIAS;
	crt_voff  <= crt_vs_t[5:0];
end

wire       crt_hs_ref;
reg        crt_hs_ref_d;
wire [8:0] crt_period = 9'd104 + {{4{crt_hsize[4]}}, crt_hsize};
reg  [8:0] crt_acc;
wire       crt_tick = (crt_acc + 9'd8) >= crt_period;
always @(posedge clk_sys) begin
	crt_hs_ref_d <= crt_hs_ref;
	if      (crt_hs_ref & ~crt_hs_ref_d) crt_acc <= 9'd0;
	else if (crt_tick)                   crt_acc <= crt_acc + 9'd8 - crt_period;
	else                                 crt_acc <= crt_acc + 9'd8;
end
wire crt_rd_en = crt_on ? crt_tick : vq_ce;

wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb_unused;
crt_adjust #(.VTOTAL(272), .HTOTAL(448), .HPOS_MODE(1)) u_crt
(
	.clk(clk_sys), .pxl_cen(vq_ce), .pxl2_cen(crt_rd_en), .active(crt_on),
	.hsize(crt_hsize), .hoffset(crt_hoff), .voffset(crt_voff),
	.r_in(vq_rgb[23:16]), .g_in(vq_rgb[15:8]), .b_in(vq_rgb[7:0]),
	.hs_in(vq_hs), .vs_in(vq_vs), .hb_in(vq_hb), .vb_in(vq_vbn),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb_unused),
	.hs_ref_out(crt_hs_ref)
);

wire vga_de_av;
arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_on ? crt_rd_en : vq_ce),
	.RGB_in(crt_on ? {crt_r, crt_g, crt_b} : vq_rgb),
	.HBlank(crt_on ? (crt_hb | crt_hs) : vq_hb),
	.VBlank(crt_on ? 1'b0 : vq_vb),
	.HSync(crt_on ? crt_hs : vq_hs),
	.VSync(crt_on ? crt_vs : vq_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(vga_de_av),
	.VGA_SL(VGA_SL),

	.fx(status[5:3]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_av),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

///////////////////////   LEDs   ///////////////////////

reg led_vbl_toggle;
always @(posedge clk_sys) if (frame_tick) led_vbl_toggle <= ~led_vbl_toggle;
assign LED_USER = core_rst_r ? 1'b1 : led_vbl_toggle;

endmodule
