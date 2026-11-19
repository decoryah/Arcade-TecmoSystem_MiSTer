// Sprite engine of the Tecmo System video, written from MAME 0.289 tecmosys_v.cpp (render_sprites_to_bitmap), drawing line by line.
//
// MAME draws the whole sprite list into a bitmap at the start of the vertical blank (screen_update, after the tilemaps of that frame were mixed)
// and mixes that bitmap into the NEXT frame: the sprites are one frame behind the tilemaps ("prevents sprite lag in tkdensho").  Here, at the
// start of the vertical blank (vbl), the selected list (880008: one of four 16 KB lists in the sprite RAM) and the two offsets (880000 /
// 880002) are latched and the list is copied out of the sprite RAM (so that the CPU can rewrite it); during the next frame each line is drawn
// from that copy, one line ahead of the display, into the sprite line buffer.  The result is MAME's bitmap, line by line.
//
// Sprite entry (16 bytes, MAME's comment):
//   +0  ------xx xxxxxxxx  X (10 bit)          +8  x------- -------- disable        +a  ROM offset LSB (x 256 pixels)
//   +2  -------x xxxxxxxx  Y (9 bit)               --xxxxxx -------- palette           +c  xxxxxxxx -------- width / 16
//   +4  ----xxxx xxxxxxxx  zoom X (4.8)            -------- x------- flip Y                -------- xxxxxxxx height / 16
//   +6  ----xxxx xxxxxxxx  zoom Y (4.8)            -------- -x------ flip X
//                                                  -------- --xx---- priority
//                                                  -------- ----xxxx ROM offset MSB
// x = (X + 386 - xoff) & 0x3ff and y = (Y + 1 - yoff) & 0x1ff, as signed 10 / 9-bit numbers.  MAME's drawing (both of its paths are the same
// thing with the zoom 0x100 taken as 1.0): source row r goes to screen line ((y << 8) + r * zoomy) >> 8, source column c of that row to screen
// x ((x << 8) + c * zoomx) >> 8, for every row / column whose position lands in the visible 320 x 240; a pixel of value 0 is transparent, a
// later pixel (a later column, row or sprite in the list) overwrites an earlier one.  So a zoom below 0x100 draws several source rows / columns
// onto one line / pixel (the last opaque one wins), a zoom above 0x100 leaves gaps (MAME's behaviour, kept here: see docs/status.md).
// A sprite whose zoom X or zoom Y is 0 is not drawn.  The value written is (pixel + palette * 256) | priority << 14.
//
// Graphics: MAME's "sprites" region decoded to one byte per pixel (descramble) is the pixel address space here; address = (ROM offset << 8) +
// row * width + column, masked to the region (32 or 64 M pixels).  It is split into eight slots of 8 M pixels (address bits 25-23); the
// slot table (`slots`, from the ROM image's header) says per slot where its data is in the SDRAM and how it is stored:
//   mode 2  8 bpp: the two 16-bit ROMs interleaved word by word (A, B, A, B, ...): words 2g / 2g+1 hold pixels 4g..4g+3 (the A word gives the
//           high nibbles, the B word the low ones; pixel 4g+0 is {A[7:4], B[7:4]}, +1 {A[3:0], B[3:0]}, +2 {A[15:12], B[15:12]}, +3 {A[11:8], B[11:8]})
//   mode 1  4 bpp: only the B ROM (MAME loads nothing in the A half): word g holds pixels 4g..4g+3, high nibbles 0
//   mode 0  empty (zeros); `half` = only the first 4 M pixels of the slot are populated, the rest reads 0
// A 16-pixel group (16-pixel aligned in the address space: the offset is a multiple of 256, a row a multiple of 16) is one SDRAM burst of
// 8 words (mode 2) or 4 (mode 1).
`default_nettype none
module ts_sprites (
    input  wire         clk,
    input  wire         rst,

    input  wire         vbl,                      // one clock: the vertical blank starts (latch and copy the list)
    input  wire [1:0]   list,
    input  wire [15:0]  xoff,
    input  wire [15:0]  yoff,

    input  wire         start,                    // one clock: draw line `line` into bank `bank`
    input  wire [7:0]   line,
    input  wire         bank,
    output wire         busy,
    output wire         ready,                    // the copy of the list is complete (a line may be drawn)

    // the sprite RAM (one-clock reads)
    output logic [14:0] spr_addr,
    input  wire  [15:0] spr_data,

    input  wire [127:0] slots,                    // slot s = slots[16 s +: 16]: {base MB (relative to SDRAM 0x1000000) [13:8], half [2], mode [1:0]}

    // sprite ROM (ts_mem: req held until ack, then len words in order with rvalid)
    output logic        rom_req,
    output logic [24:0] rom_addr,
    output logic [6:0]  rom_len,
    input  wire         rom_ack,
    input  wire         rom_valid,
    input  wire  [15:0] rom_data,

    // sprite line buffer (two banks of 512)
    output logic        lb_we,
    output logic [9:0]  lb_addr,
    output logic [15:0] lb_data
);
    localparam [16:0] XLIM = 17'd81920;           // 320 << 8
    localparam [16:0] YLIM = 17'd61440;           // 240 << 8

    // ================================================================ tables, one entry per sprite of the latched list
    // state (the scanner's): {active, row, its 8.8 line position (signed)}: the next row to draw (normal), the last one not drawn yet (Y flip)
    logic        st_we;
    logic [9:0]  st_wa;
    logic [30:0] st_wd, st_q;
    logic [9:0]  st_ra;
    ts_sdpram_w #(.AW(10), .DW(31)) u_st (.clk(clk), .we(st_we), .waddr(st_wa), .wdata(st_wd), .raddr(st_ra), .rdata(st_q));
    // geometry (the scanner's): {height / 16, zoom Y}
    logic        g_we;
    logic [19:0] g_wd, g_q;
    ts_sdpram_w #(.AW(10), .DW(20)) u_g (.clk(clk), .we(g_we), .waddr(st_wa), .wdata(g_wd), .raddr(st_ra), .rdata(g_q));
    // drawing (the drawer's): {first column, its 8.8 x, zoom X, width / 16, height / 16, flip X, flip Y, palette, priority, ROM offset}
    typedef struct packed {
        logic [11:0] c0;
        logic [16:0] dx0;
        logic [11:0] zx;
        logic [7:0]  xs8;
        logic [7:0]  ys8;
        logic        fx;
        logic        fy;
        logic [5:0]  col;
        logic [1:0]  pri;
        logic [19:0] adr;
    } dent_t;
    logic        d_we;
    dent_t       d_wd, d_q;
    logic [9:0]  d_ra;
    ts_sdpram_w #(.AW(10), .DW($bits(dent_t))) u_d (.clk(clk), .we(d_we), .waddr(st_wa), .wdata(d_wd), .raddr(d_ra), .rdata(d_q));

    // ================================================================ copy + set-up (vertical blank)
    // The first visible row / column of a sprite whose y / x is negative: MAME steps through the rows (columns) until the position reaches 0;
    // here the step count is ceil(-pos / zoom) and the position reached is (zoom - (-pos mod zoom)) mod zoom (ts_cdiv).
    //
    // MAME FLAW 1 FIXED (docs/status.md, tools/flip_study.py): bit 15 of 880000 / 880002 flips the sprite layer.  The games' inverted screen
    // (tkdensho 0x2e5e) sets it and adds 0x30 / 0xf4 to the offsets; MAME masks it away.  Flipped, a pixel MAME would put at x (y) is put at
    // 271 - x (-5 - y): the picture turns exactly 180 degrees with the tilemaps (ts_tiles).  Here: x + 48 (y + 244) is drawn into the window
    // 0..319 (0..239) and the line buffer address is mirrored (319 - x); with the Y flip the screen's lines meet the sprite's rows from its
    // bottom, so the scanner steps the rows downwards ("reverse") and emits each line's rows in MAME's (ascending) order.
    typedef enum logic [2:0] { I_IDLE, I_RD, I_CALC, I_DIV, I_MUL, I_WR } ist_e;
    ist_e        ist;
    logic [1:0]  l_list;
    logic [15:0] l_xoff, l_yoff;
    logic [9:0]  ii;
    logic [3:0]  ij;
    logic [15:0] w [0:6];
    logic        rdy;
    assign ready = rdy;
    wire         mx = l_xoff[15];
    wire         my = l_yoff[15];

    logic        dv_go;
    logic [17:0] dvx_n, dvy_n;
    logic [11:0] dvx_d, dvy_d;
    wire  [17:0] dvx_q, dvy_q, dvy_qf;
    wire  [11:0] dvx_r, dvy_r, dvy_rf;
    wire         dvx_busy, dvy_busy;
    ts_cdiv u_dvx (.clk(clk), .go(dv_go), .n(dvx_n), .d(dvx_d), .q(dvx_q), .r_up(dvx_r), .qf(), .rf(), .busy(dvx_busy));
    ts_cdiv u_dvy (.clk(clk), .go(dv_go), .n(dvy_n), .d(dvy_d), .q(dvy_q), .r_up(dvy_r), .qf(dvy_qf), .rf(dvy_rf), .busy(dvy_busy));

    // the entry's fields
    wire [9:0]  e_x10  = 10'(w[0] + 16'd386 - l_xoff);
    wire [8:0]  e_y9   = 9'(w[1] + 16'd1 - l_yoff);
    wire signed [10:0] e_x = $signed({e_x10[9], e_x10}) + (mx ? 11'sd48 : 11'sd0);      // -512 .. 559
    wire signed [9:0]  e_y = $signed({e_y9[8], e_y9}) + (my ? 10'sd244 : 10'sd0);       // -256 .. 499
    wire [11:0] e_zx   = w[2][11:0];
    wire [11:0] e_zy   = w[3][11:0];
    wire        e_ok   = !w[4][15] && (e_zx != 12'd0) && (e_zy != 12'd0);
    wire [11:0] e_xs   = {w[6][15:8], 4'd0};
    wire [11:0] e_ys   = {w[6][7:0], 4'd0};
    wire [9:0]  e_xm   = -e_x[9:0];                 // -x (x negative: 1 .. 512)
    wire [8:0]  e_ym   = -e_y[8:0];                 // -y (y negative: 1 .. 256)
    wire signed [18:0] e_yn = 19'sd61439 - ($signed(e_y) * 19'sd256);
    logic        nx, ny;                          // x / y negative
    logic        xbig, ybig;                      // x >= 320 / y >= 240: nothing of the sprite is visible
    logic        st_we_i;                         // the set-up writes entry ii (I_WR)
    logic [16:0] px0, py0;                        // x << 8, y << 8 when not negative
    logic signed [18:0] y0s;                      // y << 8 (the Y flip's set-up)
    logic [23:0] prod;                            // (height - 1) * zoom Y

    always_comb begin
        spr_addr = {l_list, ii, ij[2:0]};
    end

    always_ff @(posedge clk) begin
        st_we_i <= 1'b0;
        dv_go   <= 1'b0;
        if (rst) begin
            ist <= I_IDLE; rdy <= 1'b0;
        end else begin
            case (ist)
                I_IDLE: if (vbl) begin
                    l_list <= list; l_xoff <= xoff; l_yoff <= yoff;
                    ii <= 10'd0; ij <= 4'd0; rdy <= 1'b0;
                    ist <= I_RD;
                end
                I_RD: begin
                    // address j out in this clock, its word in the next
                    if (ij != 4'd0) w[ij[2:0] - 3'd1] <= spr_data;
                    if (ij == 4'd7) ist <= I_CALC;
                    else ij <= ij + 4'd1;
                end
                I_CALC: begin
                    nx   <= e_x < 0;
                    ny   <= e_y < 0;
                    xbig <= e_x >= 11'sd320;
                    ybig <= e_y >= 10'sd240;
                    px0  <= {e_x[8:0], 8'd0};
                    py0  <= {1'b0, e_y[7:0], 8'd0};
                    y0s  <= $signed(e_y) * 19'sd256;
                    dvx_n <= {e_xm, 8'd0};
                    dvy_n <= my ? e_yn[17:0] : {1'b0, e_ym, 8'd0};   // the Y flip: floor((61439 - (y << 8)) / zoom), the last row above line 240
                    dvx_d <= e_zx;
                    dvy_d <= e_zy;
                    dv_go <= e_ok && ((e_x < 0) || (e_y < 0) || my);
                    ist <= I_DIV;
                end
                I_DIV: if (!dv_go && !dvx_busy && !dvy_busy) ist <= I_MUL;
                I_MUL: begin
                    prod <= (e_ys - 12'd1) * e_zy;
                    ist <= I_WR;
                end
                I_WR: begin
                    st_we_i <= 1'b1;
                    if (ii == 10'd1023) begin ist <= I_IDLE; rdy <= 1'b1; end
                    else begin ii <= ii + 10'd1; ij <= 4'd0; ist <= I_RD; end
                end
                default: ist <= I_IDLE;
            endcase
            if (vbl && ist != I_IDLE) begin                  // a new vertical blank before the copy ended: start over
                l_list <= list; l_xoff <= xoff; l_yoff <= yoff;
                ii <= 10'd0; ij <= 4'd0; rdy <= 1'b0; ist <= I_RD;
            end
        end
    end

    // the set-up's results (valid in I_WR)
    wire [17:0] c0_f  = (nx && e_ok) ? dvx_q : 18'd0;
    wire [16:0] dx0_f = nx ? {5'd0, dvx_r} : px0;
    wire        actx  = e_ok && !xbig && (c0_f < 18'(e_xs)) && (dx0_f < XLIM) && (e_ys != 12'd0);
    // normal: the first row at or below line 0
    wire [17:0] r0_f  = (ny && e_ok) ? dvy_q : 18'd0;
    wire [16:0] dy0_f = ny ? {5'd0, dvy_r} : py0;
    wire        act_n = actx && !ybig && (r0_f < 18'(e_ys)) && (dy0_f < YLIM);
    // Y flip: the last row above line 240 (the floor quotient, or the sprite's last row)
    wire        clampr = dvy_qf >= 18'(e_ys);
    wire [11:0] rh_f  = clampr ? e_ys - 12'd1 : dvy_qf[11:0];
    wire signed [18:0] dh_f = clampr ? (y0s + $signed({1'b0, prod[17:0]})) : (19'sd61439 - $signed({7'd0, dvy_rf}));
    wire        act_r = actx && !ybig && (dh_f >= 0);
    wire        act_f = my ? act_r : act_n;
    wire [11:0] row_f = my ? rh_f : r0_f[11:0];
    wire [17:0] d_f   = my ? dh_f[17:0] : {1'b0, dy0_f};

    // ================================================================ scanner (per line)
    typedef enum logic [2:0] { S_IDLE, S_START, S_SCAN, S_RCNT, S_REMIT, S_WAIT } sst_e;
    sst_e        sst;
    logic [9:0]  ei;
    logic signed [18:0] lim;                      // normal: the line's end (L + 1) << 8; Y flip: its start (239 - L) << 8
    logic [7:0]  sl;
    logic        sb;
    logic        cur_v;
    logic        cur_act;
    logic [11:0] cur_row;
    logic signed [18:0] cur_d;
    logic [7:0]  cur_ys8;
    logic [11:0] cur_zy;
    logic [11:0] r_hi, er;                        // Y flip: the line's highest row, the row being emitted
    // job FIFO: {sprite, row}
    logic [21:0] jq [0:15];
    logic [4:0]  jw, jr;
    wire         j_full  = (jw - jr) == 5'd16;
    wire         j_empty = (jw == jr);
    logic        s_wr;
    logic [30:0] s_wd;
    logic [9:0]  ei_w;
    logic        d_idle;

    wire         e_act = cur_v ? cur_act : st_q[30];
    wire [11:0]  e_row = cur_v ? cur_row : st_q[29:18];
    wire signed [18:0] e_d = cur_v ? cur_d : $signed({st_q[17], st_q[17:0]});
    wire [7:0]   e_ys8 = cur_v ? cur_ys8 : g_q[19:12];
    wire [11:0]  e_zyy = cur_v ? cur_zy  : g_q[11:0];
    wire [11:0]  e_ysz = {e_ys8, 4'd0};
    // normal
    wire         hit   = e_act && (e_d < lim) && (e_row < e_ysz);
    wire [11:0]  n_row = e_row + 12'd1;
    wire signed [18:0] n_d = e_d + $signed({7'd0, e_zyy});
    wire         more  = (n_row < e_ysz) && (n_d < lim);
    // Y flip
    wire         rhit  = e_act && (e_d >= lim);
    wire signed [18:0] p_d = cur_d - $signed({7'd0, cur_zy});   // the row below's position

    always_comb begin
        st_ra = (sst == S_SCAN || sst == S_RCNT || sst == S_REMIT) ? ei + 10'd1 : 10'd0;
        // the set-up writes in I_WR, the scanner its hits
        st_we = st_we_i | s_wr;
        st_wa = st_we_i ? ii : ei_w;
        st_wd = st_we_i ? {act_f, row_f, d_f} : s_wd;
        g_we  = st_we_i;
        g_wd  = {w[6][7:0], e_zy};
        d_we  = st_we_i;
        d_wd  = '{c0: c0_f[11:0], dx0: dx0_f, zx: e_zx, xs8: w[6][15:8], ys8: w[6][7:0], fx: w[4][6], fy: w[4][7],
                  col: w[4][13:8], pri: w[4][5:4], adr: {w[4][3:0], w[5]}};
    end

    logic        late;                            // a line start came while the previous line was still being drawn (sticky, for debugging)
    always_ff @(posedge clk) begin
        s_wr <= 1'b0;
        if (rst) begin
            sst <= S_IDLE; jw <= 5'd0; late <= 1'b0;
        end else begin
            case (sst)
                S_IDLE: if (start) begin
                    if (rdy && ist == I_IDLE) begin
                        sl <= line; sb <= bank;
                        lim <= my ? $signed({3'd0, 8'd239 - line, 8'd0}) : $signed({2'd0, {1'b0, line} + 9'd1, 8'd0});
                        sst <= S_START;
                    end
                end
                S_START: begin ei <= 10'd0; cur_v <= 1'b0; sst <= S_SCAN; end
                S_SCAN: begin
                    if (my) begin
                        // the Y flip: the rows of this line are those from e_row down while the position stays >= the line's start
                        if (rhit) begin
                            cur_v <= 1'b1; cur_act <= e_act; cur_row <= e_row; cur_d <= e_d; cur_ys8 <= e_ys8; cur_zy <= e_zyy;
                            r_hi <= e_row;
                            sst <= S_RCNT;
                        end else begin
                            cur_v <= 1'b0;
                            if (ei == 10'd1023) sst <= S_WAIT; else ei <= ei + 10'd1;
                        end
                    end else if (hit) begin
                        if (!j_full) begin
                            jq[jw[3:0]] <= {ei, e_row};
                            jw <= jw + 5'd1;
                            if (more) begin
                                cur_v <= 1'b1; cur_act <= e_act; cur_row <= n_row; cur_d <= n_d; cur_ys8 <= e_ys8; cur_zy <= e_zyy;
                            end else begin
                                s_wr <= 1'b1; ei_w <= ei;
                                s_wd <= {(n_row < e_ysz) && (n_d < $signed({2'd0, YLIM})), n_row, n_d[17:0]};
                                cur_v <= 1'b0;
                                if (ei == 10'd1023) sst <= S_WAIT; else ei <= ei + 10'd1;
                            end
                        end else begin
                            cur_v <= 1'b1; cur_act <= e_act; cur_row <= e_row; cur_d <= e_d; cur_ys8 <= e_ys8; cur_zy <= e_zyy;
                        end
                    end else begin
                        cur_v <= 1'b0;
                        if (ei == 10'd1023) sst <= S_WAIT; else ei <= ei + 10'd1;
                    end
                end
                S_RCNT: begin
                    // step down to the line's lowest row (cur_row / cur_d), then emit upwards
                    if (cur_row != 12'd0 && p_d >= lim) begin
                        cur_row <= cur_row - 12'd1; cur_d <= p_d;
                    end else begin
                        er <= cur_row;
                        sst <= S_REMIT;
                    end
                end
                S_REMIT: if (!j_full) begin
                    jq[jw[3:0]] <= {ei, er};
                    jw <= jw + 5'd1;
                    if (er == r_hi) begin
                        s_wr <= 1'b1; ei_w <= ei;
                        s_wd <= {(cur_row != 12'd0) && (p_d >= 0), cur_row - 12'd1, p_d[17:0]};
                        cur_v <= 1'b0;
                        if (ei == 10'd1023) sst <= S_WAIT; else begin ei <= ei + 10'd1; sst <= S_SCAN; end
                    end else er <= er + 12'd1;
                end
                S_WAIT: if (j_empty && d_idle) sst <= S_IDLE;
                default: sst <= S_IDLE;
            endcase
            if (start && sst != S_IDLE) late <= 1'b1;
        end
    end
    assign busy = (sst != S_IDLE);

    // ================================================================ drawer
    typedef enum logic [2:0] { D_IDLE, D_LD, D_MUL, D_RUN, D_DRAIN } dst_e;
    dst_e        dst;
    wire  [21:0] jh = jq[jr[3:0]];
    always_comb d_ra = jh[21:12];
    dent_t       dc;                              // the job's sprite
    logic [11:0] drow;
    logic [11:0] ressy;
    logic [27:0] rowbase;
    logic [11:0] xcnt;                            // source column being drawn
    logic [11:0] ressx;                           // its pixel in the row (flip applied)
    logic [16:0] dx;
    wire  [11:0] xsz = {dc.xs8, 4'd0};

    // chunk fetcher: chunks of 16 pixels of the row, in drawing order
    logic [23:0] fca;                             // next chunk address (pixel address >> 4)
    logic [8:0]  fleft;                           // chunks still to fetch
    logic        stop;                            // the job is finished: no more fetches
    // two chunk buffers
    logic [1:0]  sv;                              // slot holds data ready
    logic [1:0]  sw;                              // slot waits for SDRAM data
    logic [15:0] abuf [0:1][0:3];
    logic [15:0] bbuf [0:1][0:3];
    logic        bmode [0:1];                     // 1 = 8 bpp (A words present)
    logic        fslot;                           // the next slot to allocate
    logic        cslot;                           // the slot the drawer reads
    // in-flight SDRAM requests, oldest first: their slots and lengths
    logic        q_slot [0:1];
    logic        q_m8   [0:1];
    logic [1:0]  qc;
    logic [2:0]  fwc;                             // words of the oldest request received
    // the queue index a request raised now takes (after this clock's completion, if any)
    wire         q_pop = rom_valid && qc != 2'd0 && (fwc == (q_m8[0] ? 3'd7 : 3'd3));
    wire  [1:0]  qc_n0 = qc - (q_pop ? 2'd1 : 2'd0);
    wire         qc_n  = qc_n0[0];

    // the chunk at fca: slot table look-up
    wire  [2:0]  ts   = fca[21:19];
    wire  [15:0] te   = slots[16 * ts +: 16];
    wire  [1:0]  tm   = te[1:0];
    wire         tz   = (tm == 2'd0) || (tm == 2'd3) || (te[2] && fca[18]);
    wire  [24:0] tbw  = 25'h800000 + {te[13:8], 19'd0};
    wire  [24:0] taddr = (tm == 2'd2) ? tbw + {3'd0, fca[18:0], 3'd0} : tbw + {4'd0, fca[18:0], 2'd0};

    // the pixel the drawer is at
    wire  [3:0]  pn   = ressx[3:0];
    wire  [15:0] pa_w = abuf[cslot][pn[3:2]];
    wire  [15:0] pb_w = bbuf[cslot][pn[3:2]];
    function automatic [3:0] nib(input [15:0] v, input [1:0] s);
        case (s)
            2'd0: nib = v[7:4];
            2'd1: nib = v[3:0];
            2'd2: nib = v[15:12];
            default: nib = v[11:8];
        endcase
    endfunction
    wire  [7:0]  pix  = {bmode[cslot] ? nib(pa_w, pn[1:0]) : 4'd0, nib(pb_w, pn[1:0])};
    wire  [17:0] dx_n = {1'b0, dx} + {6'd0, dc.zx};
    wire         last = (xcnt + 12'd1 >= xsz) || (dx_n >= {1'b0, XLIM});
    wire         chunk_end = dc.fx ? (ressx[3:0] == 4'd0) : (ressx[3:0] == 4'd15);

    assign d_idle = (dst == D_IDLE);

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        if (rst) begin
            dst <= D_IDLE; jr <= 5'd0; rom_req <= 1'b0; sv <= 2'b00; sw <= 2'b00; qc <= 2'd0; fwc <= 3'd0;
        end else begin
            // ---- SDRAM words into the oldest waiting slot
            if (rom_valid && qc != 2'd0) begin
                if (q_m8[0]) begin
                    if (!fwc[0]) abuf[q_slot[0]][fwc[2:1]] <= rom_data;
                    else         bbuf[q_slot[0]][fwc[2:1]] <= rom_data;
                end else begin
                    abuf[q_slot[0]][fwc[1:0]] <= 16'h0000;
                    bbuf[q_slot[0]][fwc[1:0]] <= rom_data;
                end
                if (fwc == (q_m8[0] ? 3'd7 : 3'd3)) begin
                    fwc <= 3'd0;
                    sw[q_slot[0]] <= 1'b0;
                    sv[q_slot[0]] <= 1'b1;
                    q_slot[0] <= q_slot[1]; q_m8[0] <= q_m8[1];
                    qc <= qc - 2'd1 + ((rom_req && rom_ack) ? 2'd1 : 2'd0);
                end else begin
                    fwc <= fwc + 3'd1;
                    if (rom_req && rom_ack) qc <= qc + 2'd1;
                end
            end else if (rom_req && rom_ack) qc <= qc + 2'd1;
            if (rom_req && rom_ack) begin
                rom_req <= 1'b0;
                // (the slot / length of this request were queued when it was raised)
            end

            case (dst)
                D_IDLE: if (!j_empty) begin
                    drow <= jh[11:0];
                    jr <= jr + 5'd1;
                    dst <= D_LD;
                end
                D_LD: begin
                    dc <= d_q;
                    ressy <= d_q.fy ? ({d_q.ys8, 4'd0} - 12'd1 - drow) : drow;
                    dst <= D_MUL;
                end
                D_MUL: begin
                    rowbase <= {dc.adr, 8'd0} + 28'(ressy * {dc.xs8, 4'd0});
                    xcnt    <= dc.c0;
                    ressx   <= dc.fx ? (xsz - 12'd1 - dc.c0) : dc.c0;
                    dx      <= dc.dx0;
                    fleft   <= {1'b0, dc.xs8} - {1'b0, dc.c0[11:4]};
                    stop    <= 1'b0;
                    cslot   <= 1'b0; fslot <= 1'b0;
                    dst <= D_RUN;
                end
                D_RUN: begin
                    // fetch the next chunk into a free slot
                    if (!stop && fleft != 9'd0 && !sv[fslot] && !sw[fslot] && !rom_req) begin
                        if (tz) begin
                            for (int k = 0; k < 4; k++) begin abuf[fslot][k] <= 16'h0; bbuf[fslot][k] <= 16'h0; end
                            bmode[fslot] <= 1'b0;
                            sv[fslot] <= 1'b1;
                        end else begin
                            rom_req  <= 1'b1;
                            rom_addr <= taddr;
                            rom_len  <= (tm == 2'd2) ? 7'd8 : 7'd4;
                            bmode[fslot] <= (tm == 2'd2);
                            sw[fslot] <= 1'b1;
                            q_slot[qc_n] <= fslot; q_m8[qc_n] <= (tm == 2'd2);
                        end
                        fslot <= ~fslot;
                        fleft <= fleft - 9'd1;
                        fca <= dc.fx ? fca - 24'd1 : fca + 24'd1;
                    end
                    // draw one pixel
                    if (sv[cslot]) begin
                        if (pix != 8'd0) begin
                            lb_we   <= 1'b1;
                            lb_addr <= {sb, mx ? 9'd319 - dx[16:8] : dx[16:8]};
                            lb_data <= {dc.pri, dc.col, pix};
                        end
                        dx    <= dx_n[16:0];
                        xcnt  <= xcnt + 12'd1;
                        ressx <= dc.fx ? ressx - 12'd1 : ressx + 12'd1;
                        if (last) begin
                            stop <= 1'b1;
                            dst <= D_DRAIN;
                        end else if (chunk_end) begin
                            sv[cslot] <= 1'b0;
                            cslot <= ~cslot;
                        end
                    end
                end
                D_DRAIN: begin
                    // the requests already made must come back before the slots are reused
                    if (!rom_req && qc == 2'd0) begin
                        sv <= 2'b00; sw <= 2'b00;
                        dst <= D_IDLE;
                    end
                end
                default: dst <= D_IDLE;
            endcase
            // the first chunk address of a job (set with D_MUL's results)
            if (dst == D_MUL) fca <= ({dc.adr, 4'd0} + 24'(ressy * {4'd0, dc.xs8})) + (dc.fx ? 24'(dc.xs8 - 8'd1 - dc.c0[11:4]) : 24'(dc.c0[11:4]));
        end
    end
endmodule

// ceil(n / d) and the distance the position moves past 0: q = ceil(n / d), r_up = q * d - n (0 .. d - 1); also floor(n / d), n mod d.  Restoring division (18 clocks)
// and one clock to round up; busy from the clock after `go` until the results are there.
module ts_cdiv (
    input  wire         clk,
    input  wire         go,
    input  wire  [17:0] n,
    input  wire  [11:0] d,
    output logic [17:0] q,
    output logic [11:0] r_up,
    output logic [17:0] qf,                       // floor(n / d)
    output logic [11:0] rf,                       // n mod d
    output wire         busy
);
    logic [1:0]  ph;                              // 0 idle, 1 dividing, 2 rounding
    logic [4:0]  k;
    logic [17:0] nn;
    logic [11:0] r;
    logic [11:0] dd;
    assign busy = (ph != 2'd0);
    wire  [12:0] r_sh = {r, nn[17]};
    wire  [13:0] r_df = {1'b0, r_sh} - {2'b00, dd};
    always_ff @(posedge clk) begin
        case (ph)
            2'd0: if (go) begin nn <= n; dd <= d; r <= 12'd0; q <= 18'd0; k <= 5'd18; ph <= 2'd1; end
            2'd1: begin
                nn <= {nn[16:0], 1'b0};
                if (!r_df[13]) begin r <= r_df[11:0]; q <= {q[16:0], 1'b1}; end
                else begin r <= r_sh[11:0]; q <= {q[16:0], 1'b0}; end
                k <= k - 5'd1;
                if (k == 5'd1) ph <= 2'd2;
            end
            default: begin
                qf <= q; rf <= r;
                if (r != 12'd0) begin q <= q + 18'd1; r_up <= dd - r; end
                else r_up <= 12'd0;
                ph <= 2'd0;
            end
        endcase
    end
    initial begin ph = 2'd0; r_up = 12'd0; q = 18'd0; end
endmodule
`default_nettype wire
