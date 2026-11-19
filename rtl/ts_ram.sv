// Block RAM building blocks of the Tecmo System core (inferred block RAM, synchronous read).  ts_spram / ts_tdpram are the owner's
// jchan-mister jchan_spram / jchan_tdpram (byte enables on 16-bit words), renamed; ts_sdpram_w / ts_tdpram_w / ts_spram8 are new: plain
// words of any width without byte enables.
//
//   ts_spram     one port, 16-bit words with byte enables (the 68000's work RAM, the line RAMs)
//   ts_tdpram    two independent read / write ports, 16-bit words with byte enables (video RAMs, palettes, sprite RAM: port A = 68000,
//                port B = the video side)
//   ts_sdpram_w  one write port, one read port, any width (the sprite engine's state tables)
//   ts_tdpram_w  two read / write ports, any width (the sprite engine's copy of the list: written and scanned on A, read by the drawer on B)
//   ts_spram8    one port, bytes (the Z80's RAM)
//
// Reads return the data one clock after the address (read-first: a read in the clock of a write to the same address sees the old word).
// The arrays are named `mem` (or mem_h / mem_l) so a testbench can dump them by hierarchical reference.
`default_nettype none
module ts_spram #(
    parameter AW = 15
) (
    input  wire          clk,
    input  wire          we,
    input  wire [1:0]    be,
    input  wire [AW-1:0] addr,
    input  wire [15:0]   wdata,
    output logic [15:0]  rdata
);
`ifdef ALTERA_RESERVED_QIS
    // two byte arrays: Quartus does not infer a byte-enabled RAM from partial writes to a 16-bit word array
    logic [7:0] mem_h [0:(1 << AW) - 1];
    logic [7:0] mem_l [0:(1 << AW) - 1];
    always_ff @(posedge clk) begin
        if (we && be[1]) mem_h[addr] <= wdata[15:8];
        if (we && be[0]) mem_l[addr] <= wdata[7:0];
        rdata <= {mem_h[addr], mem_l[addr]};
    end
`else
    logic [15:0] mem [0:(1 << AW) - 1];
    always_ff @(posedge clk) begin
        if (we) begin
            if (be[1]) mem[addr][15:8] <= wdata[15:8];
            if (be[0]) mem[addr][7:0]  <= wdata[7:0];
        end
        rdata <= mem[addr];
    end
`endif
endmodule

module ts_tdpram #(
    parameter AW = 13,
    parameter DEPTH = (1 << AW)
) (
    input  wire          clk,
    input  wire          a_we,
    input  wire [1:0]    a_be,
    input  wire [AW-1:0] a_addr,
    input  wire [15:0]   a_wdata,
    output logic [15:0]  a_rdata,
    input  wire          b_we,
    input  wire [1:0]    b_be,
    input  wire [AW-1:0] b_addr,
    input  wire [15:0]   b_wdata,
    output logic [15:0]  b_rdata
);
`ifdef ALTERA_RESERVED_QIS
    // the explicit megafunction (Quartus does not infer this read-first true dual-port RAM from the behavioural form; jchan-mister)
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"),
        .width_a(16), .widthad_a(AW), .numwords_a(DEPTH),
        .width_b(16), .widthad_b(AW), .numwords_b(DEPTH),
        .width_byteena_a(2), .width_byteena_b(2), .byte_size(8),
        .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
        .address_reg_b("CLOCK0"), .indata_reg_b("CLOCK0"), .wrcontrol_wraddress_reg_b("CLOCK0"), .byteena_reg_b("CLOCK0"),
        .read_during_write_mode_port_a("DONT_CARE"), .read_during_write_mode_port_b("DONT_CARE"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),
        .intended_device_family("Cyclone V"), .ram_block_type("M10K"), .power_up_uninitialized("FALSE"), .lpm_type("altsyncram")
    ) u_ram (
        .clock0(clk), .clock1(1'b1),
        .address_a(a_addr), .data_a(a_wdata), .wren_a(a_we), .byteena_a(a_be), .q_a(a_rdata),
        .address_b(b_addr), .data_b(b_wdata), .wren_b(b_we), .byteena_b(b_be), .q_b(b_rdata),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1), .rden_a(1'b1), .rden_b(1'b1), .eccstatus());
`else
    logic [15:0] mem [0:DEPTH - 1];
    always_ff @(posedge clk) begin
        if (a_we) begin
            if (a_be[1]) mem[a_addr][15:8] <= a_wdata[15:8];
            if (a_be[0]) mem[a_addr][7:0]  <= a_wdata[7:0];
        end
        a_rdata <= mem[a_addr];
        if (b_we) begin
            if (b_be[1]) mem[b_addr][15:8] <= b_wdata[15:8];
            if (b_be[0]) mem[b_addr][7:0]  <= b_wdata[7:0];
        end
        b_rdata <= mem[b_addr];
    end
`endif
endmodule

// one write port, one read port (old data when both address the same word in one clock)
module ts_sdpram_w #(
    parameter AW = 10,
    parameter DW = 32
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire [AW-1:0] raddr,
    output logic [DW-1:0] rdata
);
    logic [DW-1:0] mem [0:(1 << AW) - 1];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule

// two read / write ports of any width
module ts_tdpram_w #(
    parameter AW = 10,
    parameter DW = 64
) (
    input  wire          clk,
    input  wire          a_we,
    input  wire [AW-1:0] a_addr,
    input  wire [DW-1:0] a_wdata,
    output logic [DW-1:0] a_rdata,
    input  wire          b_we,
    input  wire [AW-1:0] b_addr,
    input  wire [DW-1:0] b_wdata,
    output logic [DW-1:0] b_rdata
);
`ifdef ALTERA_RESERVED_QIS
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"),
        .width_a(DW), .widthad_a(AW), .numwords_a(1 << AW),
        .width_b(DW), .widthad_b(AW), .numwords_b(1 << AW),
        .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
        .address_reg_b("CLOCK0"), .indata_reg_b("CLOCK0"), .wrcontrol_wraddress_reg_b("CLOCK0"),
        .read_during_write_mode_port_a("DONT_CARE"), .read_during_write_mode_port_b("DONT_CARE"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),
        .intended_device_family("Cyclone V"), .ram_block_type("M10K"), .power_up_uninitialized("FALSE"), .lpm_type("altsyncram")
    ) u_ram (
        .clock0(clk), .clock1(1'b1),
        .address_a(a_addr), .data_a(a_wdata), .wren_a(a_we), .q_a(a_rdata),
        .address_b(b_addr), .data_b(b_wdata), .wren_b(b_we), .q_b(b_rdata),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1), .rden_a(1'b1), .rden_b(1'b1), .eccstatus());
`else
    logic [DW-1:0] mem [0:(1 << AW) - 1];
    always_ff @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_wdata;
        a_rdata <= mem[a_addr];
        if (b_we) mem[b_addr] <= b_wdata;
        b_rdata <= mem[b_addr];
    end
`endif
endmodule

module ts_spram8 #(
    parameter AW = 13
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] addr,
    input  wire [7:0]    wdata,
    output logic [7:0]   rdata
);
    logic [7:0] mem [0:(1 << AW) - 1];
    always_ff @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        rdata <= mem[addr];
    end
endmodule
`default_nettype wire
