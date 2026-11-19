// The Tecmo System protection device (a 68HC11A8 on the game board, not dumped), as MAME 0.289 simulates it (tecmo/tecmosys_m.cpp, protection
// simulation by nuapete): a password, the upload of a short code, four checksum ranges and their four checksums are exchanged byte by byte
// through two ports; after that the vblank code keeps writing (0xff, then a byte it reads back) and ignores the answers.
//
//   b80000 (r)  status: a word / high-byte read returns 0, a low-byte read 0xc0 (bit 7 = ready to write, bit 6 = ready to read: always ready)
//   b80000 (w)  status write: ignored
//   e80000 (w)  data in: the high byte of the word (MAME's data >> 8)
//   f80000 (r)  data out: the answer to the last write in the high byte; the read itself sets the answer to 0xff (read side effect)
//
// The tables are those of MAME's deroon_data / tkdensho_data / tkdensha_data, selected by `game` (0 deroon, 1 tkdensho, 2 tkdenshoa: the
// ROM image's header byte, tools/make_mra.py).  MAME resets the state on a machine reset (prot_reset): so does `rst` here.
`default_nettype none
module ts_prot (
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0]  game,
    input  wire        wr,              // one clock per write to e80000
    input  wire [7:0]  wdata,           // the high byte of the written word
    input  wire        rd,              // one clock per read of f80000 (the side effect)
    output wire [7:0]  value            // what a read of f80000 returns (in the high byte)
);
    localparam [2:0] DS_IDLE = 3'd0, DS_LOGIN = 3'd1, DS_SEND_CODE = 3'd2, DS_SEND_ADRS = 3'd3, DS_SEND_CHKSUMS = 3'd4, DS_DONE = 3'd5;

    // ---------------------------------------------------------------- MAME's tables
    function automatic [7:0] passwd(input [1:0] g, input [4:0] i);
        // deroon "LUNA\0", tkdensho "AGEPROTECT START\0"
        if (g == 2'd0) begin
            case (i)
                5'd0: passwd = "L"; 5'd1: passwd = "U"; 5'd2: passwd = "N"; 5'd3: passwd = "A";
                default: passwd = 8'h00;
            endcase
        end else begin
            case (i)
                5'd0: passwd = "A";  5'd1: passwd = "G";  5'd2: passwd = "E";  5'd3: passwd = "P";
                5'd4: passwd = "R";  5'd5: passwd = "O";  5'd6: passwd = "T";  5'd7: passwd = "E";
                5'd8: passwd = "C";  5'd9: passwd = "T";  5'd10: passwd = " "; 5'd11: passwd = "S";
                5'd12: passwd = "T"; 5'd13: passwd = "A"; 5'd14: passwd = "R"; 5'd15: passwd = "T";
                default: passwd = 8'h00;
            endcase
        end
    endfunction
    function automatic [7:0] passwd_len(input [1:0] g);
        passwd_len = (g == 2'd0) ? 8'd5 : 8'h11;
    endfunction
    function automatic [7:0] code(input [1:0] g, input [4:0] i);
        // code length, the code, a 0x00 trailer
        if (g == 2'd0) begin
            case (i)
                5'd0: code = 8'h02; 5'd1: code = 8'h4e; 5'd2: code = 8'h75;
                default: code = 8'h00;
            endcase
        end else begin
            case (i)
                5'd0: code = 8'h06; 5'd1: code = 8'h4e; 5'd2: code = 8'hf9; 5'd3: code = 8'h00;
                5'd4: code = 8'h00; 5'd5: code = 8'h22; 5'd6: code = 8'hc4;
                default: code = 8'h00;
            endcase
        end
    endfunction
    function automatic [7:0] range_b(input [4:0] i);
        // the same in all three: 10-13, 24-27, 38-3b, 4c-4f, trailer 00
        case (i)
            5'd0: range_b = 8'h10;  5'd1: range_b = 8'h11;  5'd2: range_b = 8'h12;  5'd3: range_b = 8'h13;
            5'd4: range_b = 8'h24;  5'd5: range_b = 8'h25;  5'd6: range_b = 8'h26;  5'd7: range_b = 8'h27;
            5'd8: range_b = 8'h38;  5'd9: range_b = 8'h39;  5'd10: range_b = 8'h3a; 5'd11: range_b = 8'h3b;
            5'd12: range_b = 8'h4c; 5'd13: range_b = 8'h4d; 5'd14: range_b = 8'h4e; 5'd15: range_b = 8'h4f;
            default: range_b = 8'h00;
        endcase
    endfunction
    function automatic [7:0] chksum(input [1:0] g, input [4:0] i);
        case (g)
            2'd0:    case (i[1:0]) 2'd0: chksum = 8'ha6; 2'd1: chksum = 8'h29; 2'd2: chksum = 8'h4b; default: chksum = 8'h3f; endcase
            2'd1:    case (i[1:0]) 2'd0: chksum = 8'hbf; 2'd1: chksum = 8'hfa; 2'd2: chksum = 8'hda; default: chksum = 8'hda; endcase
            default: case (i[1:0]) 2'd0: chksum = 8'hbf; 2'd1: chksum = 8'hfa; 2'd2: chksum = 8'h21; default: chksum = 8'h5d; endcase
        endcase
    endfunction

    // ---------------------------------------------------------------- the device (prot_data_w / prot_data_r)
    logic [2:0] status;
    logic [7:0] ptr;
    logic [7:0] val;
    assign value = val;

    wire [7:0] code_len = code(game, 5'd0);
    always_ff @(posedge clk) begin
        if (rst) begin
            status <= DS_IDLE; ptr <= 8'd0; val <= 8'hff;
        end else if (wr) begin
            case (status)
                DS_IDLE: if (wdata == 8'h13) begin
                    status <= DS_LOGIN; val <= passwd_len(game); ptr <= 8'd0;
                end
                DS_LOGIN: begin
                    if (ptr >= passwd_len(game)) begin
                        status <= DS_SEND_CODE; val <= code(game, 5'd0); ptr <= 8'd1;
                    end else begin
                        val <= (passwd(game, ptr[4:0]) == wdata) ? 8'h00 : 8'hff;
                        ptr <= ptr + 8'd1;
                    end
                end
                DS_SEND_CODE: begin
                    if (ptr >= code_len + 8'd2) begin
                        status <= DS_SEND_ADRS; val <= range_b(5'd0); ptr <= 8'd1;
                    end else if (wdata == code(game, 5'(ptr - 8'd1))) begin
                        val <= code(game, ptr[4:0]); ptr <= ptr + 8'd1;
                    end else val <= 8'hff;
                end
                DS_SEND_ADRS: begin
                    if (ptr >= 8'd17) begin
                        status <= DS_SEND_CHKSUMS; val <= 8'h00; ptr <= 8'd0;
                    end else if (wdata == range_b(5'(ptr - 8'd1))) begin
                        val <= range_b(ptr[4:0]); ptr <= ptr + 8'd1;
                    end else val <= 8'hff;
                end
                DS_SEND_CHKSUMS: begin
                    if (ptr >= 8'd4) begin
                        status <= DS_DONE; val <= 8'h00;
                    end else if (wdata == chksum(game, ptr[4:0])) begin
                        val <= chksum(game, ptr[4:0]); ptr <= ptr + 8'd1;
                    end else val <= 8'hff;
                end
                default: ;                      // DS_DONE: the vblank's writes are ignored
            endcase
        end else if (rd) begin
            val <= 8'hff;                       // "read-ready for two consecutive reads but returns 0xff for subsequent reads"
        end
    end
endmodule
`default_nettype wire
