// Tilemap line renderer of the Tecmo System video (MAME 0.289 tecmosys_v.cpp: get_tile_info, the scroll / flip set-up of screen_update, and
// tilemap_copy_to_compose).  It draws one line of the four tilemaps, in MAME's order, into the compose line buffer:
//
//   tilemap 1 (300000, "layer1" tiles, scroll c80000, X + 104, Y + 16)   compose priority 0   (every pixel written: a pen 0 writes 0, so this
//   tilemap 2 (400000, "layer2" tiles, scroll a80000, X + 106, Y + 17)   compose priority 1    layer also clears the line)
//   tilemap 3 (500000, "layer3" tiles, scroll b00000, X + 106, Y + 17)   compose priority 2   (pens 1-15 only, over what is there)
//   tilemap 0 (700000, "layer0" text tiles, no scroll, flip c00004)      compose priority 3
//
// Tilemaps 1-3 are 32 x 32 tiles of 16 x 16 (512 x 512), tilemap 0 is 64 x 64 tiles of 8 x 8.  A tile is two words in its RAM: the attribute
// (bits 5-0 colour, 6 flip X, 7 flip Y) then the code.  Compose entry = {pri[1:0], palette index[10:0]}: BG layers colour * 16 + pen
// (tilemap palette 000-3ff), the text layer 400 + colour * 16 + pen (MAME's gfx bases 0x4000 / 0x4400 masked with 0x7ff).
//
// MAME FLAW 1 FIXED (docs/status.md): the screen flip.  A BG tilemap's screen pixel (x, y) shows the logical tilemap pixel (x + scroll_x +
// offset, y + scroll_y + offset) normally and (287 - x + scroll_x + offset, -39 - y + scroll_y + offset) with its flip bits set (scroll
// word 2: bit 0 X, bit 1 Y), each tile mirrored too; the text layer shows (x, y), flipped (319 - x, 239 - y).  The games' inverted screen
// (tkdensho 0x2e5e) adds 0x20 / 0x116 to every scroll and sets the flips: these origins (319 - 0x20, 239 - 0x116) turn the picture exactly
// 180 degrees (tools/flip_study.py: 0 pixels against MAME's normal picture turned around, 4 fight frames).  MAME uses 511 for all.
// The text layer's scroll registers are ignored as MAME does: the games write 018e / 01ee (tkdensho) and 018e / 01ef (deroon), which a
// real scroll with offsets 114 / 18 would make one line apart -- the flip test cannot tell the two apart (docs/status.md).
//
// Tile graphics come from the SDRAM (ts_mem's tile port, word reads of a whole tile row): text tiles at TX_BASE (32 bytes, a row = 2 words),
// BG tiles at BG_BASE + layer * 1 MB (128 bytes; the loader stores a 16 x 16 tile's rows contiguously: row r at byte r * 8, 4 words, see
// TecmoSys.sv).  Packed MSB: the first pixel is the high nibble of the even byte (SDRAM word bits 15-12).
//
// One line takes ~ 21 x 3 + 40 tile reads; the fetcher keeps up to two tiles in flight, the writer draws one pixel a clock.
`default_nettype none
module ts_tiles #(
    parameter [24:0] TX_BASE_W = 25'h100000,      // byte 0x200000
    parameter [24:0] BG_BASE_W = 25'h180000       // byte 0x300000: layer 1; layer 2 +0x80000 words, layer 3 +0x100000
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,                    // one clock: draw line `line` into bank `bank`
    input  wire [7:0]   line,
    input  wire         bank,
    output wire         busy,

    input  wire [191:0] scroll,                   // ts_main: {scroll_3, scroll_2, scroll_1, scroll_0}, each {flip, Y, X}

    // tile RAMs (one-clock reads)
    output logic [12:0] tx_addr,
    input  wire  [15:0] tx_data,
    output logic [10:0] bg1_addr,
    input  wire  [15:0] bg1_data,
    output logic [10:0] bg2_addr,
    input  wire  [15:0] bg2_data,
    output logic [10:0] bg3_addr,
    input  wire  [15:0] bg3_data,

    // tile ROM (ts_mem: req held until ack, then len words in order with rvalid)
    output logic        rom_req,
    output logic [24:0] rom_addr,
    output logic [6:0]  rom_len,
    input  wire         rom_ack,
    input  wire         rom_valid,
    input  wire  [15:0] rom_data,

    // compose line buffer (two banks of 512)
    output logic        lb_we,
    output logic [9:0]  lb_addr,
    output logic [15:0] lb_data
);
    // ---------------------------------------------------------------- per-layer set-up (sampled at the start of the line)
    function automatic [15:0] sreg(input [191:0] s, input integer n, input integer w);
        sreg = s[16 * (3 * n + w) +: 16];
    endfunction

    // the layer being fetched: 0..2 = tilemaps 1..3, 3 = tilemap 0 (text)
    logic [1:0]  fl;                // fetch layer
    logic [5:0]  fk;                // tile number in the line (0..20 BG, 0..39 text)
    logic [7:0]  ln;
    logic        bk;
    logic [8:0]  lx0;               // logical X of screen x = 0
    logic [8:0]  ly;                // logical Y of the line
    logic        fx;                // the layer's screen flip X (flip Y is in ly: the logical row; a tile's own flip Y picks its ROM row)

    // sample the layer's registers: scroll X / Y with MAME's offsets, flip
    function automatic [8:0] l_x0(input [191:0] s, input [1:0] l);
        logic [15:0] x, f;
        begin
            case (l)
                2'd0:    begin x = sreg(s, 1, 0) + 16'd104; f = sreg(s, 1, 2); end
                2'd1:    begin x = sreg(s, 2, 0) + 16'd106; f = sreg(s, 2, 2); end
                2'd2:    begin x = sreg(s, 3, 0) + 16'd106; f = sreg(s, 3, 2); end
                default: begin x = 16'd32;                  f = sreg(s, 0, 2); end     // (287 + 32 = 319: the text layer's origin)
            endcase
            l_x0 = f[0] ? (9'd287 + x[8:0]) : ((l == 2'd3) ? 9'd0 : x[8:0]);
        end
    endfunction
    function automatic [8:0] l_y(input [191:0] s, input [1:0] l, input [7:0] y);
        logic [15:0] v, f;
        begin
            case (l)
                2'd0:    begin v = sreg(s, 1, 1) + 16'd16; f = sreg(s, 1, 2); end
                2'd1:    begin v = sreg(s, 2, 1) + 16'd17; f = sreg(s, 2, 2); end
                2'd2:    begin v = sreg(s, 3, 1) + 16'd17; f = sreg(s, 3, 2); end
                default: begin v = 16'd278;                f = sreg(s, 0, 2); end     // (473 + 278 = 239: the text layer's origin)
            endcase
            l_y = f[1] ? (9'd473 - {1'b0, y} + v[8:0]) : ({1'b0, y} + ((l == 2'd3) ? 9'd0 : v[8:0]));     // 473 = -39 mod 512
        end
    endfunction
    function automatic fl_x(input [191:0] s, input [1:0] l);
        fl_x = (l == 2'd3) ? s[32] : s[16 * (3 * (l + 1) + 2)];
    endfunction
    function automatic fl_y(input [191:0] s, input [1:0] l);
        fl_y = (l == 2'd3) ? s[33] : s[16 * (3 * (l + 1) + 2) + 1];
    endfunction

    // ---------------------------------------------------------------- descriptor FIFO (fetcher -> writer), two entries
    // {layer[1:0], xs[9:0] (screen x of logical pixel 0 of the tile, signed), colour[5:0], tile flip X, screen flip X}
    typedef struct packed {
        logic [1:0] l;
        logic [9:0] xs;
        logic [5:0] col;
        logic       tfx;
        logic       sfx;
    } desc_t;
    desc_t      dq [0:1];
    logic [1:0] dw, dr;             // pointers (bit 1 = wrap)
    wire        d_full  = (dw[0] == dr[0]) && (dw[1] != dr[1]);
    wire        d_empty = (dw == dr);

    // word FIFO (SDRAM -> writer): 8 words
    logic [15:0] wq [0:7];
    logic [3:0]  ww, wr;
    wire  [3:0]  wcount = ww - wr;

    // ---------------------------------------------------------------- fetcher
    typedef enum logic [2:0] { F_IDLE, F_SETUP, F_A0, F_A1, F_A2, F_REQ, F_DONE } fst_e;
    fst_e        fst;
    logic [15:0] attr, code;
    wire  [5:0]  nk = (fl == 2'd3) ? 6'd40 : 6'd21;
    // the tile's logical column and the screen x of its logical pixel 0
    wire  [5:0]  tcol_tx = fx ? (lx0[8:3] - fk) : (lx0[8:3] + fk);
    wire  [4:0]  tcol_bg = fx ? (lx0[8:4] - fk[4:0]) : (lx0[8:4] + fk[4:0]);
    wire  [9:0]  xs_tx   = fx ? (10'(fk) * 10'd8  + 10'(lx0[2:0])) : (10'(fk) * 10'd8  - 10'(lx0[2:0]));
    wire  [9:0]  xs_bg   = fx ? (10'(fk) * 10'd16 + 10'(lx0[3:0])) : (10'(fk) * 10'd16 - 10'(lx0[3:0]));
    wire  [12:0] tx_a0   = {ly[8:3], tcol_tx, 1'b0};
    wire  [10:0] bg_a0   = {ly[8:4], tcol_bg, 1'b0};
    logic        f_busy;

    wire [15:0] bg_q = (fl == 2'd0) ? bg1_data : (fl == 2'd1) ? bg2_data : bg3_data;
    wire [15:0] t_q  = (fl == 2'd3) ? tx_data : bg_q;

    always_comb begin
        tx_addr  = tx_a0 | {12'd0, (fst == F_A1)};
        bg1_addr = bg_a0 | {10'd0, (fst == F_A1)};
        bg2_addr = bg1_addr;
        bg3_addr = bg1_addr;
    end

    // ---------------------------------------------------------------- writer
    typedef enum logic [1:0] { W_IDLE, W_LOAD, W_PIX } wst_e;
    wst_e        wst;
    desc_t       cd;
    logic [63:0] pix;               // the row's pens, first pixel in the top nibble
    logic [3:0]  wi;                // pixel of the row
    logic        w_busy;
    wire  [3:0]  wn = (cd.l == 2'd3) ? 4'd7 : 4'd15;
    wire  [2:0]  wlen = (dq[dr[0]].l == 2'd3) ? 3'd2 : 3'd4;
    // logical pixel wi of the tile (after the tile's own flip) and its screen x
    wire  [3:0]  rp  = cd.tfx ? (wn - wi) : wi;
    wire  [3:0]  pen = (cd.l == 2'd3) ? pix[63 - 4 * rp[2:0] -: 4] : pix[63 - 4 * rp -: 4];
    wire  [9:0]  sx  = cd.sfx ? (cd.xs - 10'(wi)) : (cd.xs + 10'(wi));
    wire         on  = !sx[9] && (sx < 10'd320);

    assign busy = f_busy || w_busy || !d_empty;

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        if (rst) begin
            fst <= F_IDLE; f_busy <= 1'b0; rom_req <= 1'b0;
            dw <= 2'd0; dr <= 2'd0; ww <= 4'd0; wr <= 4'd0;
            wst <= W_IDLE; w_busy <= 1'b0;
        end else begin
            // words in
            if (rom_valid) begin wq[ww[2:0]] <= rom_data; ww <= ww + 4'd1; end

            // ---------------- fetcher
            case (fst)
                F_IDLE: if (start) begin
                    ln <= line; bk <= bank; fl <= 2'd0; f_busy <= 1'b1; fst <= F_SETUP;
                end
                F_SETUP: begin
                    lx0 <= l_x0(scroll, fl);
                    ly  <= l_y(scroll, fl, ln);
                    fx  <= fl_x(scroll, fl);
                    fk  <= 6'd0;
                    fst <= F_A0;
                end
                F_A0: fst <= F_A1;                        // attribute address out
                F_A1: begin attr <= t_q; fst <= F_A2; end // attribute in, code address out
                F_A2: begin code <= t_q; fst <= F_REQ; end
                F_REQ: begin
                    if (!rom_req && !d_full) begin       // (a descriptor per request: at most two tiles in flight, 8 words)
                        rom_req <= 1'b1;
                        if (fl == 2'd3) begin
                            rom_addr <= TX_BASE_W + {6'd0, code[14:0], 4'd0} + {21'd0, attr[7] ? ~ly[2:0] : ly[2:0], 1'b0};
                            rom_len  <= 7'd2;
                        end else begin
                            rom_addr <= BG_BASE_W + {4'd0, fl, 19'd0} + {6'd0, code[12:0], 6'd0} + {19'd0, attr[7] ? ~ly[3:0] : ly[3:0], 2'b00};
                            rom_len  <= 7'd4;
                        end
                        dq[dw[0]] <= '{l: fl, xs: (fl == 2'd3) ? xs_tx : xs_bg, col: attr[5:0], tfx: attr[6], sfx: fx};
                        dw <= dw + 2'd1;
                    end
                    if (rom_req && rom_ack) begin
                        rom_req <= 1'b0;
                        if (fk == nk - 6'd1) begin
                            if (fl == 2'd3) fst <= F_DONE;
                            else begin fl <= fl + 2'd1; fst <= F_SETUP; end
                        end else begin
                            fk <= fk + 6'd1; fst <= F_A0;
                        end
                    end
                end
                F_DONE: if (d_empty && !w_busy) begin f_busy <= 1'b0; fst <= F_IDLE; end
                default: fst <= F_IDLE;
            endcase

            // ---------------- writer
            case (wst)
                W_IDLE: if (!d_empty && wcount >= 4'(wlen)) begin
                    cd <= dq[dr[0]];
                    dr <= dr + 2'd1;
                    if (wlen == 3'd2) begin
                        pix <= {wq[wr[2:0]], wq[wr[2:0] + 3'd1], 32'd0};
                        wr  <= wr + 4'd2;
                    end else begin
                        pix <= {wq[wr[2:0]], wq[wr[2:0] + 3'd1], wq[wr[2:0] + 3'd2], wq[wr[2:0] + 3'd3]};
                        wr  <= wr + 4'd4;
                    end
                    wi <= 4'd0;
                    w_busy <= 1'b1;
                    wst <= W_PIX;
                end
                W_PIX: begin
                    if (on && (cd.l == 2'd0 || pen != 4'd0)) begin
                        lb_we   <= 1'b1;
                        lb_addr <= {bk, sx[8:0]};
                        lb_data <= (pen == 4'd0) ? 16'h0000 :
                                   (cd.l == 2'd3) ? {3'd0, 2'd3, 1'b1, cd.col, pen} : {3'd0, cd.l, 1'b0, cd.col, pen};
                    end
                    if (wi == wn) begin wst <= W_IDLE; w_busy <= 1'b0; end
                    else wi <= wi + 4'd1;
                end
                default: wst <= W_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
