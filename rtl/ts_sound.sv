// The Tecmo System sound section (MAME 0.289 tecmosys.cpp: sound_map, io_map): a Z80 at 8 MHz, its 256 KB program (32 KB fixed + a 16 KB
// window on one of 16 banks) read from the SDRAM through a line cache (wait states on a miss), 6 KB of RAM, the sound latch from the 68000 and
// its NMI, a YMF262 (ts_opl3), an OKI M6295 (jt6295, 2 MHz, pin 7 high) with two 128 KB bank registers, and a YMZ280B (ts_ymz280b).
//
//   memory   0000-7fff ROM (region 0000-7fff)    8000-bfff ROM bank (region bank * 4000)    e000-f7ff RAM    (the rest reads 0)
//   I/O      00-03 YMF262 (r/w)   10 OKI (r/w)   20 OKI banks (w: bits 1-0 for 00000-1ffff, bits 5-4 for 20000-3ffff)   30 Z80 bank (w)
//            40 sound latch (r)   50 NMI disable (w: 0 enables, anything else disables)   60-61 YMZ280B (r/w)    (the rest reads 0)
//
// Interrupts: INT = the YMF262's IRQ (level; the acknowledge reads 0xff: RST 38h); NMI = the latch's "data pending" AND the NMI enable (MAME's
// INPUT_MERGER_ALL_HIGH: both start high, so the NMI is enabled after a reset until the Z80 writes ff to port 50).  The Z80 takes the NMI on
// the rising edge of that AND (tv80 detects the falling edge of nmi_n).  The latch is cleared ("not pending") by the Z80's read of port 40.
//
// The OKI's 256 KB space (oki_map): 00000-1ffff = 128 KB page bank0 of the 512 KB sample ROM, 20000-3ffff = page bank1.
`default_nettype none
module ts_sound (
    input  wire         clk,
    input  wire         rst,
    input  wire         clk_opl,
    input  wire         cen_z80,
    input  wire         cen_oki,

    input  wire [7:0]   latch,
    input  wire         latch_wr,
    output logic        pending,

    // Z80 program (byte reads, level request, level ack with the data: ts_mem's cache)
    output wire         zrom_req,
    output wire [17:0]  zrom_addr,
    input  wire         zrom_ack,
    input  wire [7:0]   zrom_data,

    // OKI samples (byte reads, request held until the one-clock ack)
    output logic        oki_req,
    output logic [18:0] oki_addr,
    input  wire         oki_ack,
    input  wire [7:0]   oki_data,

    // YMZ280B samples
    output wire         ymz_req,
    output wire [23:0]  ymz_addr,
    input  wire         ymz_ack,
    input  wire [7:0]   ymz_data,

    // the chips' outputs (held between their samples)
    output wire signed [13:0] oki_out,
    output wire         oki_smp,                // one clock per OKI sample: oki_out changes at the next clock
    output wire signed [15:0] opl_l,
    output wire signed [15:0] opl_r,
    output wire signed [15:0] ymz_l,
    output wire signed [15:0] ymz_r,

    output wire [15:0]  dbg_pc
);
    // ------------------------------------------------------------------ Z80
    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
    wire [15:0] A;
    logic [7:0] cpu_di;
    wire  [7:0] cpu_do;
    logic       nmi_en;
    wire        opl_irq_n;
    wire        wait_n;

    tv80s_cen u_cpu (
        .reset_n(~rst), .clk(clk), .cen(cen_z80), .wait_n(wait_n),
        .int_n(opl_irq_n), .nmi_n(~(pending & nmi_en)), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .rfsh_n(rfsh_n), .halt_n(), .busak_n(), .A(A), .di(cpu_di), .dout(cpu_do)
    );
    assign dbg_pc = A;

    // ------------------------------------------------------------------ memory decode
    logic [3:0] zbank;
    wire mem_cyc = !mreq_n && rfsh_n;
    wire mem_rd  = mem_cyc && !rd_n;
    wire mem_wr  = mem_cyc && !wr_n;
    wire sel_rom = !A[15] || (A[15:14] == 2'b10);           // 0000-bfff
    wire sel_ram = (A[15:13] == 3'b111) && (A[12:11] != 2'b11);   // e000-f7ff
    assign zrom_req  = mem_rd && sel_rom;
    assign zrom_addr = A[15] ? {zbank, A[13:0]} : {3'b000, A[14:0]};
    assign wait_n    = !(zrom_req && !zrom_ack);

    wire [7:0] ram_q;
    ts_spram8 #(.AW(13)) u_ram (.clk(clk), .we(mem_wr && sel_ram), .addr(A[12:0]), .wdata(cpu_do), .rdata(ram_q));

    // ------------------------------------------------------------------ I/O (one pulse per cycle)
    wire io_cyc = !iorq_n && m1_n;
    wire io_rd  = io_cyc && !rd_n;
    wire io_wr  = io_cyc && !wr_n;
    logic io_rd_d, io_wr_d;
    always_ff @(posedge clk) begin io_rd_d <= io_rd; io_wr_d <= io_wr; end
    wire io_rd_p = io_rd && !io_rd_d;
    wire io_wr_p = io_wr && !io_wr_d;
    wire [7:0] port = A[7:0];
    wire p_opl = port[7:2] == 6'b000000;       // 00-03
    wire p_oki = port == 8'h10;
    wire p_okb = port == 8'h20;
    wire p_bnk = port == 8'h30;
    wire p_lat = port == 8'h40;
    wire p_nmi = port == 8'h50;
    wire p_ymz = port[7:1] == 7'b0110000;      // 60-61

    logic [1:0] okb0, okb1;
    logic       oki_wr, ymz_wr, opl_wr;
    logic [7:0] wdat;
    always_ff @(posedge clk) begin
        oki_wr <= 1'b0; ymz_wr <= 1'b0; opl_wr <= 1'b0;
        if (rst) begin
            pending <= 1'b0; nmi_en <= 1'b1; zbank <= 4'd0; okb0 <= 2'd0; okb1 <= 2'd0;
        end else begin
            if (latch_wr)                       pending <= 1'b1;
            else if (io_rd_p && p_lat)          pending <= 1'b0;
            if (io_wr_p) begin
                wdat <= cpu_do;
                if (p_opl) opl_wr <= 1'b1;
                if (p_oki) oki_wr <= 1'b1;
                if (p_ymz) ymz_wr <= 1'b1;
                if (p_okb) begin okb0 <= cpu_do[1:0]; okb1 <= cpu_do[5:4]; end
                if (p_bnk) zbank <= cpu_do[3:0];
                if (p_nmi) nmi_en <= (cpu_do == 8'h00);
            end
        end
    end
    logic [1:0] wa;
    always_ff @(posedge clk) if (io_wr_p) wa <= port[1:0];

    // ------------------------------------------------------------------ YMF262
    wire [7:0] opl_dout;
    ts_opl3 u_opl (
        .clk(clk), .rst(rst), .clk_opl(clk_opl),
        .wr(opl_wr), .a(opl_wr ? wa : port[1:0]), .din(wdat), .dout(opl_dout), .irq_n(opl_irq_n),
        .out_l(opl_l), .out_r(opl_r), .out_valid());

    // ------------------------------------------------------------------ OKI M6295
    wire [7:0]  oki_dout;
    wire [17:0] oki_a;
    logic [7:0] oki_rd;
    wire        oki_ok;
    jt6295 #(.INTERPOL(0), .SAMPLE(1)) u_oki (
        .rst(rst), .clk(clk), .cen(cen_oki), .ss(1'b1),
        .wrn(~oki_wr), .din(wdat), .dout(oki_dout),
        .rom_addr(oki_a), .rom_data(oki_rd), .rom_ok(oki_ok),
        .sound(oki_out), .sample(oki_smp)
    );
    wire [18:0] oki_pa = {oki_a[17] ? okb1 : okb0, oki_a[16:0]};
    // the sample byte is read from the SDRAM whenever the chip's address changes, and held (supduck-mister's sd_sound)
    logic [18:0] srv_a;
    logic        have;
    always_ff @(posedge clk) begin
        if (rst) begin
            have <= 1'b0; oki_req <= 1'b0; oki_rd <= 8'h00; srv_a <= 19'd0;
        end else begin
            if (oki_ack) begin
                oki_rd <= oki_data; srv_a <= oki_addr; have <= 1'b1; oki_req <= 1'b0;
            end else if (!oki_req && !(have && srv_a == oki_pa)) begin
                oki_addr <= oki_pa; oki_req <= 1'b1;
            end
        end
    end
    assign oki_ok = have && (srv_a == oki_pa);

    // ------------------------------------------------------------------ YMZ280B
    wire [7:0] ymz_dout;
    logic [7:0] ymz_q;
    ts_ymz280b u_ymz (
        .clk(clk), .rst(rst), .wr(ymz_wr), .a0(ymz_wr ? wa[0] : port[0]), .din(wdat),
        .rd(io_rd_p && p_ymz), .dout(ymz_dout),
        .rom_req(ymz_req), .rom_addr(ymz_addr), .rom_ack(ymz_ack), .rom_data(ymz_data),
        .out_valid(), .out_l(ymz_l), .out_r(ymz_r), .dbg_l(), .dbg_r(), .overrun(), .dbg_tick());
    // the read's byte is taken in the read's first clock (the status is cleared by it the clock after)
    wire [7:0] ymz_rd_now;
    assign ymz_rd_now = ymz_dout;
    always_ff @(posedge clk) if (io_rd_p && p_ymz) ymz_q <= ymz_rd_now;

    // ------------------------------------------------------------------ the CPU's data input
    // memory and port reads are taken many clocks after the address settles (one cen_z80 period is 12 clocks)
    always_comb begin
        cpu_di = 8'h00;
        if (!m1_n && !iorq_n)       cpu_di = 8'hFF;               // interrupt acknowledge: the bus floats high
        else if (!mreq_n) begin
            if (sel_rom)            cpu_di = zrom_data;
            else if (sel_ram)       cpu_di = ram_q;
        end else if (!iorq_n) begin
            if (p_opl)              cpu_di = opl_dout;
            else if (p_oki)         cpu_di = oki_dout;
            else if (p_lat)         cpu_di = latch;
            else if (p_ymz)         cpu_di = io_rd_d ? ymz_q : ymz_rd_now;
        end
    end
endmodule
`default_nettype wire
