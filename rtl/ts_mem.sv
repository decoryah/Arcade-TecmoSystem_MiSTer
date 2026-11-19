// The Tecmo System core's memory system: ts_sdram (the owner's jchan-mister controller, 64 MB module) + one client adapter per port, and the
// download loader.  ts_rcache and ts_loader are jchan-mister's jchan_rcache / jchan_loader, renamed; ts_byterd is jchan_ymzrd without its fold.
//
// SDRAM image (byte addresses; tools/ts_rom.py builds the same image, tools/make_mra.py the MRA stream that the loader writes into it):
//   0x0000000  68000 program 1 MB (big-endian words)         0x0200000  text tiles ("layer0") 1 MB (512 KB sets: loaded twice)
//   0x0100000  Z80 program 256 KB (128 KB sets: twice)       0x0300000  BG tiles "layer1", "layer2", "layer3": 1 MB each, every 16 x 16 tile's
//   0x0140000  OKI samples 512 KB                                        rows stored contiguously (TecmoSys.sv's loader remap)
//   0x01C0000  (unused 256 KB)                                0x0600000  YMZ280B samples 4 MB (2 MB sets: loaded twice; MAME mirrors)
//   0x1000000  sprite slots (ts_sprites: 8 M pixel slots, placed by the header's table), up to 48 MB
//
// Clients (port 0 = highest priority):
//   0 loader           ioctl bytes paired into words, single word writes (the machine is in reset then)
//   1 OKI samples      byte reads, one word cached: jt6295 takes the ADPCM byte 384 clocks after it puts the address out, whether it has
//                      come or not
//   2 YMZ280B samples  byte reads, one word cached: up to 32 a sample, the sample due every 1,088 clocks
//   3 tile rows        ts_tiles' bursts of 2 / 4 words: its line has a hard deadline and a small bandwidth
//   4 68000 program    word reads through a direct-mapped 2 KB line cache (8-word lines, next-line prefetch)
//   5 Z80 program      byte reads through the same kind of cache (wait states on a miss)
//   6 sprite chunks    ts_sprites' bursts of 4 / 8 words (the bulk of the bandwidth; its line has a deadline too)
// The two sample ports come first (in the test builds before the release they were 4 and 5): below the tile rows and the CPUs' line fills they waited
// up to 382 clocks, and in simulation 0.07 - 0.23 % of the OKI's ADPCM bytes were taken before they came (each one a wrong nibble pair that
// throws the decoder's signal off for the rest of the phrase: DC steps and clicks) and the YMZ280B finished 175 - 685 samples late.  Their
// reads are single words, so the others wait at most one of them each.
// A byte of the image: even byte address = word[15:8], odd = word[7:0].
`default_nettype none

// ---------------------------------------------------------------------------------------------------------------------------------------
// CPU program ROM: direct-mapped line cache.  req (held) / addr (word address, stable one clock before req) -> ack (level, with data).
module ts_rcache #(
    parameter AW = 20,
    parameter [24:0] BASE_W = 25'd0,
    parameter IB = 7,                  // log2(number of 8-word lines)
    parameter PREFETCH = 1
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          req,
    input  wire [AW-1:0] addr,
    output wire          ack,
    output wire [15:0]   data,

    output logic         creq,
    output logic [24:0]  caddr,
    output wire  [6:0]   clen,
    input  wire          cack,
    input  wire          rvalid,
    input  wire          rlast,
    input  wire [15:0]   rdata
);
    localparam TW = AW - IB - 3;
    logic [TW-1:0]            tag_ram [0:(1<<IB)-1];
    logic [15:0]              dat_ram [0:(1<<(IB+3))-1];
    logic [(1<<IB)-1:0]       valid;
    logic [AW-1:0]            addr_q;
    logic [TW-1:0]            tag_q;
    logic                     v_q;
    logic [15:0]              dat_q;

    typedef enum logic [1:0] { F_IDLE, F_REQ, F_DATA } fst_e;
    fst_e         fst;
    logic [AW-4:0] f_line;
    logic          f_pf;
    logic [2:0]    wc;
    logic          pf_pend;
    logic [AW-4:0] pf_line;
    wire  [IB-1:0] f_idx = f_line[IB-1:0];
    wire  [TW-1:0] f_tag = f_line[AW-4:IB];

    always_ff @(posedge clk) begin
        addr_q <= addr;
        tag_q  <= tag_ram[addr[IB+2:3]];
        v_q    <= valid[addr[IB+2:3]];
        dat_q  <= dat_ram[addr[IB+2:0]];
    end
    wire stable = (addr == addr_q);
    wire hit    = stable && v_q && (tag_q == addr_q[AW-1:IB+3]);
    assign ack  = req && hit;
    assign data = dat_q;
    wire miss   = req && stable && !hit;
    assign clen = 7'd8;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid <= '0;
            fst <= F_IDLE;
            creq <= 1'b0;
            pf_pend <= 1'b0;
        end else begin
            case (fst)
                F_IDLE: begin
                    if (miss) begin
                        f_line <= addr[AW-1:3]; f_pf <= 1'b0;
                        valid[addr[IB+2:3]] <= 1'b0;
                        creq <= 1'b1; caddr <= BASE_W | {1'b0, addr[AW-1:3], 3'b000};
                        fst <= F_REQ;
                    end else if (pf_pend) begin
                        f_line <= pf_line; f_pf <= 1'b1; pf_pend <= 1'b0;
                        valid[pf_line[IB-1:0]] <= 1'b0;
                        creq <= 1'b1; caddr <= BASE_W | {1'b0, pf_line, 3'b000};
                        fst <= F_REQ;
                    end
                end
                F_REQ: if (cack) begin creq <= 1'b0; wc <= 3'd0; fst <= F_DATA; end
                F_DATA: if (rvalid) begin
                    dat_ram[{f_idx, wc}] <= rdata;
                    wc <= wc + 3'd1;
                    if (rlast) begin
                        tag_ram[f_idx] <= f_tag;
                        valid[f_idx] <= 1'b1;
                        fst <= F_IDLE;
                        if (PREFETCH != 0 && !f_pf && (f_line != {(AW-3){1'b1}})) begin pf_pend <= 1'b1; pf_line <= f_line + 1'b1; end
                    end
                end
                default: fst <= F_IDLE;
            endcase
        end
    end
endmodule

// ---------------------------------------------------------------------------------------------------------------------------------------
// Download loader: ioctl-style byte writes (any order within a word pair, normally sequential) -> word writes.  dl_busy asks the source to wait.
module ts_loader (
    input  wire          clk,
    input  wire          rst,
    input  wire          dl_wr,
    input  wire [25:0]   dl_addr,
    input  wire [7:0]    dl_data,
    output wire          dl_busy,

    output wire          creq,
    output wire [24:0]   caddr,
    output wire [6:0]    clen,
    input  wire          wpop,
    output wire          wavail,
    output wire [15:0]   wdata
);
    logic [7:0]  even_b;
    logic [40:0] fifo [0:15];
    logic [3:0]  fw, fr;
    logic [4:0]  fc;
    wire         push = dl_wr && dl_addr[0] && (fc != 5'd16);
    always_ff @(posedge clk) begin
        if (rst) begin fw <= '0; fr <= '0; fc <= '0; end
        else begin
            if (dl_wr && !dl_addr[0]) even_b <= dl_data;
            if (push) begin fifo[fw] <= {dl_addr[25:1], even_b, dl_data}; fw <= fw + 4'd1; end
            if (wpop) fr <= fr + 4'd1;
            fc <= fc + {4'd0, push} - {4'd0, wpop};
        end
    end
    assign dl_busy = (fc >= 5'd10);
    assign creq   = (fc != 5'd0);
    assign caddr  = fifo[fr][40:16];
    assign clen   = 7'd1;
    assign wavail = (fc != 5'd0);
    assign wdata  = fifo[fr][15:0];
endmodule

// ---------------------------------------------------------------------------------------------------------------------------------------
// Sample bytes: rom_req held until the one-clock rom_ack (data valid with it); AW bits of byte address; one word cached.
module ts_byterd #(
    parameter [24:0] BASE_W = 25'h300000,
    parameter AW = 22
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          rom_req,
    input  wire [AW-1:0] rom_addr,
    output logic         rom_ack,
    output logic [7:0]   rom_data,

    output logic         creq,
    output logic [24:0]  caddr,
    output wire  [6:0]   clen,
    input  wire          cack,
    input  wire          rvalid,
    input  wire          rlast,
    input  wire [15:0]   rdata
);
    assign clen = 7'd1;
    wire  [AW-2:0] wa = rom_addr[AW-1:1];
    logic [AW-1:0] ra_q;
    always_ff @(posedge clk) ra_q <= rom_addr;
    wire           stab = (ra_q == rom_addr);
    logic          cw_v;
    logic [AW-2:0] cw_a;
    logic [15:0]   cw_d;
    logic          waitd;
    logic          b_q;
    always_ff @(posedge clk) begin
        rom_ack <= 1'b0;
        if (rst) begin cw_v <= 1'b0; creq <= 1'b0; waitd <= 1'b0; end
        else begin
            if (!waitd && !creq && rom_req && stab && !rom_ack) begin
                if (cw_v && cw_a == wa) begin
                    rom_ack <= 1'b1;
                    rom_data <= rom_addr[0] ? cw_d[7:0] : cw_d[15:8];
                end else begin
                    creq <= 1'b1; caddr <= BASE_W + 25'(wa); b_q <= rom_addr[0];
                    cw_a <= wa; cw_v <= 1'b0;
                end
            end
            if (creq && cack) begin creq <= 1'b0; waitd <= 1'b1; end
            if (waitd && rvalid) begin
                waitd <= 1'b0;
                cw_d <= rdata; cw_v <= 1'b1;
                rom_ack <= 1'b1;
                rom_data <= b_q ? rdata[7:0] : rdata[15:8];
            end
        end
    end
endmodule

// ---------------------------------------------------------------------------------------------------------------------------------------
// Z80 program bytes through a word line cache: req level, ack level (with the byte) while the address hits.
module ts_zcache #(
    parameter [24:0] BASE_W = 25'h080000
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          req,
    input  wire [17:0]   addr,
    output wire          ack,
    output wire [7:0]    data,
    output wire          creq,
    output wire [24:0]   caddr,
    output wire [6:0]    clen,
    input  wire          cack,
    input  wire          rvalid,
    input  wire          rlast,
    input  wire [15:0]   rdata
);
    wire [15:0] w;
    logic       b0;
    always_ff @(posedge clk) b0 <= addr[0];
    ts_rcache #(.AW(17), .BASE_W(BASE_W), .IB(7)) u_c (.clk(clk), .rst(rst), .req(req), .addr(addr[17:1]), .ack(ack), .data(w),
        .creq(creq), .caddr(caddr), .clen(clen), .cack(cack), .rvalid(rvalid), .rlast(rlast), .rdata(rdata));
    assign data = b0 ? w[7:0] : w[15:8];
endmodule

// ---------------------------------------------------------------------------------------------------------------------------------------
module ts_mem #(
    parameter SHORT_INIT = 0
) (
    input  wire          clk,
    input  wire          rst,
    output wire          ready,
    input  wire          i_rd_late,

    input  wire          mrom_req,
    input  wire [19:1]   mrom_addr,
    output wire          mrom_ack,
    output wire [15:0]   mrom_data,

    input  wire          zrom_req,
    input  wire [17:0]   zrom_addr,
    output wire          zrom_ack,
    output wire [7:0]    zrom_data,

    input  wire          ymz_req,
    input  wire [23:0]   ymz_addr,
    output wire          ymz_ack,
    output wire [7:0]    ymz_data,

    input  wire          oki_req,
    input  wire [18:0]   oki_addr,
    output wire          oki_ack,
    output wire [7:0]    oki_data,

    input  wire          trom_req,
    input  wire [24:0]   trom_addr,
    input  wire [6:0]    trom_len,
    output wire          trom_ack,
    output wire          trom_valid,
    output wire [15:0]   trom_data,

    input  wire          srom_req,
    input  wire [24:0]   srom_addr,
    input  wire [6:0]    srom_len,
    output wire          srom_ack,
    output wire          srom_valid,
    output wire [15:0]   srom_data,

    input  wire          dl_wr,
    input  wire [25:0]   dl_addr,
    input  wire [7:0]    dl_data,
    output wire          dl_busy,

    output wire [12:0]   SDRAM_A,
    output wire [1:0]    SDRAM_BA,
    inout  wire [15:0]   SDRAM_DQ,
    output wire          SDRAM_DQML,
    output wire          SDRAM_DQMH,
    output wire          SDRAM_nCS,
    output wire          SDRAM_nRAS,
    output wire          SDRAM_nCAS,
    output wire          SDRAM_nWE,
    output wire          SDRAM_CKE,

    output wire [31:0]   stat_busy,
    output wire [31:0]   stat_words
);
    localparam NP = 7;
    wire [NP-1:0]    req, ack, rvalid, rlast, wavail, wpop;
    wire [NP*25-1:0] addr;
    wire [NP*7-1:0]  len;
    wire [NP*16-1:0] wdata;
    wire [15:0]      rdata;

    ts_sdram #(.NP(NP), .IS_WR(7'b0000001), .SHORT_INIT(SHORT_INIT)) u_sdram (
        .clk(clk), .rst(rst), .ready(ready), .i_rd_late(i_rd_late),
        .req(req), .addr(addr), .len(len), .ack(ack), .rvalid(rvalid), .rlast(rlast), .rdata(rdata),
        .wavail(wavail), .wdata(wdata), .wpop(wpop),
        .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
        .stat_busy(stat_busy), .stat_words(stat_words));

    // 0: loader
    ts_loader u_ld (.clk(clk), .rst(rst), .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data), .dl_busy(dl_busy),
        .creq(req[0]), .caddr(addr[0 +: 25]), .clen(len[0 +: 7]), .wpop(wpop[0]), .wavail(wavail[0]), .wdata(wdata[0 +: 16]));
    // 1: OKI (512 KB at 0x140000)
    ts_byterd #(.BASE_W(25'h0A0000), .AW(19)) u_oki (.clk(clk), .rst(rst), .rom_req(oki_req), .rom_addr(oki_addr), .rom_ack(oki_ack), .rom_data(oki_data),
        .creq(req[1]), .caddr(addr[25 +: 25]), .clen(len[7 +: 7]), .cack(ack[1]), .rvalid(rvalid[1]), .rlast(rlast[1]), .rdata(rdata));
    // 2: YMZ280B (4 MB at 0x600000: the chip's 16 MB space mirrors it)
    ts_byterd #(.BASE_W(25'h300000), .AW(22)) u_ymz (.clk(clk), .rst(rst), .rom_req(ymz_req), .rom_addr(ymz_addr[21:0]), .rom_ack(ymz_ack), .rom_data(ymz_data),
        .creq(req[2]), .caddr(addr[50 +: 25]), .clen(len[14 +: 7]), .cack(ack[2]), .rvalid(rvalid[2]), .rlast(rlast[2]), .rdata(rdata));
    // 3: tile rows (direct)
    assign req[3] = trom_req;  assign addr[75 +: 25] = trom_addr;  assign len[21 +: 7] = trom_len;
    assign trom_ack = ack[3];  assign trom_valid = rvalid[3];      assign trom_data = rdata;
    // 4: 68000 program (1 MB at 0)
    ts_rcache #(.AW(19), .BASE_W(25'h000000)) u_mc (.clk(clk), .rst(rst), .req(mrom_req), .addr(mrom_addr), .ack(mrom_ack), .data(mrom_data),
        .creq(req[4]), .caddr(addr[100 +: 25]), .clen(len[28 +: 7]), .cack(ack[4]), .rvalid(rvalid[4]), .rlast(rlast[4]), .rdata(rdata));
    // 5: Z80 program (256 KB at 0x100000)
    ts_zcache #(.BASE_W(25'h080000)) u_zc (.clk(clk), .rst(rst), .req(zrom_req), .addr(zrom_addr), .ack(zrom_ack), .data(zrom_data),
        .creq(req[5]), .caddr(addr[125 +: 25]), .clen(len[35 +: 7]), .cack(ack[5]), .rvalid(rvalid[5]), .rlast(rlast[5]), .rdata(rdata));
    // 6: sprite chunks (direct)
    assign req[6] = srom_req;  assign addr[150 +: 25] = srom_addr; assign len[42 +: 7] = srom_len;
    assign srom_ack = ack[6];  assign srom_valid = rvalid[6];      assign srom_data = rdata;

    assign wavail[6:1] = '0;
    assign wdata[111:16] = '0;
endmodule
`default_nettype wire
