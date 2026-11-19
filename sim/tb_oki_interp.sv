// ts_oki_interp against MAME's audio_resampler_lofi formula (sim/check_oki_interp.py): random 14-bit OKI samples every 6,336 clocks,
// an output sample every 2,000; each output is logged with the phase count and the four samples it was made from (oki_interp.txt).
// Build and run (WSL): the command in sim/check_oki_interp.py's docstring.
`default_nettype none
module tb_oki_interp (input wire clk);
    logic               rst = 1'b1, smp = 1'b0, take = 1'b0;
    logic signed [13:0] din = '0;
    wire signed [33:0]  y;
    wire                yv;
    ts_oki_interp dut (.clk(clk), .rst(rst), .smp(smp), .din(din), .take(take), .y(y), .y_valid(yv));

    integer fd, n = 0, ci = 0, co = 0, t = 0;
    logic [12:0] c_q;
    logic signed [13:0] q0, q1, q2, q3;
    initial fd = $fopen("oki_interp.txt", "w");
    always @(posedge clk) begin
        t <= t + 1;
        if (t == 10) rst <= 1'b0;
        // the sample strobe every 6,336 clocks, the new value the clock after (as jt6295's `sum`); an output every 2,000 (17 phases apart)
        smp <= (ci == 0);
        if (ci == 1) din <= 14'($urandom_range(0, 16383));
        ci <= (ci == 6335) ? 0 : ci + 1;
        take <= (co == 0);
        co <= (co == 1999) ? 0 : co + 1;
        if (take) begin c_q <= dut.c; q0 <= dut.s0; q1 <= dut.s1; q2 <= dut.s2; q3 <= dut.s3; end   // what the module takes
        if (yv) begin
            $fdisplay(fd, "%0d %0d %0d %0d %0d %0d", c_q, q0, q1, q2, q3, y);
            n <= n + 1;
            if (n == 20000) begin $fclose(fd); $finish; end
        end
    end
endmodule
`default_nettype wire
