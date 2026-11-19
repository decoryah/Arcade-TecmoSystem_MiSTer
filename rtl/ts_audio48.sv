// The sound board's mix (MAME 0.289 tecmosys.cpp's routes) and its 48 kHz output for the MiSTer framework.
//
// MAME mixes floating-point streams: the YMZ280B's at 0.30 (its 16-bit scale: jchan-mister's ts_ymz280b `out_*` = MAME's sample * 32768), the
// YMF262's four outputs at 0.50 (A + C left, B + D right: ts_opl3 already sums them), the OKI's single output at 0.25 to both sides (MAME:
// each voice's 12-bit sample * volume / 2048, so the voices' sum jt6295 `sound` / 2048 is MAME's value).  In 16-bit units, times a master
// gain M:
//
//   L = M * (0.30 * ymz_l + 0.50 * opl_l + 0.25 * 16 * oki)        (R the same with the right channels)
//
// opl_l is on the chip's own scale (ts_opl3: opl3_fpga, as Nuked OPL3 and MAME's YMF262 before ymfm), the scale the driver's balance was
// made on: MAME 0.224 routed it at 1.00 with the OKI at 0.50 and the YMZ280B at 0.30 (a YMZ280B twice today's); MAME 0.227 halved the
// YMZ280B ("Fix major mixer overdriving") and then the driver's FM and OKI routes to keep the balance ("rebalance sound after ymz280b
// change"), but the YMF262 of 0.225-0.230 wrote its A output to all four outputs (these games pan to A and B, so left = A + "C" = 2 A), and
// ymfm (0.231 on) is twice the old scale: MAME has played the FM 6 dB too loud against the samples ever since (docs/status.md, MAME flaw
// 11).  Here the FM is at the old scale, so the three gains are the balance 0.227 meant.  M = 1.5 keeps the loudness of the test builds before
// the release, which mixed MAME 0.289's balance (the FM doubled) with M = 1 (simulation, Angel Eyes' fight: RMS 0.1 dB apart, the peaks the same, no
// clipping); M = 2 would be MAME 0.224's level.  As gains in 1/256: 115, 192, 1536 (the test builds: 77, 2 * 128, 1024).
//
// To 48 kHz (96 MHz / 48 kHz = 2000 clocks per output sample):
//   * the YMZ280B (88.2 kHz) and the YMF262 (49.7 kHz): their held outputs are mixed every clock and averaged over each 48 kHz period (an
//     exact box filter, as the owner's jchan_audio48: zeros at 48 kHz and its multiples);
//   * the OKI (15.15 kHz): MAME 0.289's default resampler ("lofi", emu/resampler.cpp) for a stream slower than the output, a 4-point
//     interpolation evaluated at each output sample (ts_oki_interp below).  Held and box-averaged, as in the test builds, its output
//     kept the images of a 15 kHz staircase: 15 - 28 dB more than MAME between 10 and 22 kHz on Deroon's coin sound (hiss on every voice).
// The sum is saturated to 16 bits.
`default_nettype none
module ts_audio48 #(
    parameter CLK_HZ = 96_000_000,
    parameter G_YMZ  = 115,
    parameter G_OPL  = 192,
    parameter G_OKI  = 1536
) (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [15:0] ymz_l,
    input  wire signed [15:0] ymz_r,
    input  wire signed [15:0] opl_l,
    input  wire signed [15:0] opl_r,
    input  wire signed [13:0] oki,
    input  wire               oki_smp,        // jt6295 `sample` (SAMPLE = 1): `oki` takes its next value at the following clock
    output reg                out_valid,      // one clock per 48 kHz sample
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r
);
    localparam integer PERIOD = CLK_HZ / 48000;
    localparam integer SHIFT  = 30;
    localparam longint RECIP  = ((64'd1 << SHIFT) + PERIOD / 2) / PERIOD;

    // the box-filtered part of the mix, in 1/256 of a 16-bit unit (registered twice: the products, then their sum)
    logic signed [26:0] py_l, py_r, po_l, po_r;
    logic signed [28:0] mix_l, mix_r;
    always_ff @(posedge clk) begin
        py_l <= ymz_l * $signed(27'(G_YMZ));
        py_r <= ymz_r * $signed(27'(G_YMZ));
        po_l <= opl_l * $signed(27'(G_OPL));
        po_r <= opl_r * $signed(27'(G_OPL));
        mix_l <= 29'(py_l) + 29'(po_l);
        mix_r <= 29'(py_r) + 29'(po_r);
    end

    // the OKI at each output sample (taken at the end of the period, with the period's sums)
    logic [15:0]        cnt;
    wire                take = (cnt == PERIOD - 1);
    wire signed [33:0]  oki_y;                // Q16, the OKI's own scale
    wire                oki_v;
    ts_oki_interp u_oki (.clk(clk), .rst(rst), .smp(oki_smp), .din(oki), .take(take), .y(oki_y), .y_valid(oki_v));

    // the period's sums (2000 x 29 bits: 40 bits), then * RECIP >> SHIFT, plus the OKI, then >> 8 (the gains' scale), saturated
    logic signed [40:0] acc_l, acc_r, fin_l, fin_r;
    logic prd_v, rnd_v;
    logic signed [72:0] prd_l, prd_r, prd_k, rnd_l, rnd_r;
    wire  signed [36:0] avg_l = 37'(rnd_l >>> (SHIFT + 8));
    wire  signed [36:0] avg_r = 37'(rnd_r >>> (SHIFT + 8));
    function automatic signed [15:0] sat(input signed [36:0] v);
        sat = (v > 37'sd32767) ? 16'sh7fff : (v < -37'sd32768) ? 16'sh8000 : v[15:0];
    endfunction
    always_ff @(posedge clk) begin
        out_valid <= 1'b0;
        if (rst) begin
            acc_l <= '0; acc_r <= '0; cnt <= 16'd0;
        end else begin
            if (take) begin
                cnt <= 16'd0;
                fin_l <= acc_l + 41'(mix_l);
                fin_r <= acc_r + 41'(mix_r);
                acc_l <= '0;
                acc_r <= '0;
            end else begin
                cnt <= cnt + 16'd1;
                acc_l <= acc_l + 41'(mix_l);
                acc_r <= acc_r + 41'(mix_r);
            end
        end
        // the products in one clock, their sum in the next (once per period: the two together missed 96 MHz by 0.013 ns)
        prd_v <= oki_v;
        if (oki_v) begin                          // (fin_l / fin_r hold for the whole next period)
            prd_l <= fin_l * $signed(32'(RECIP));
            prd_r <= fin_r * $signed(32'(RECIP));
            prd_k <= oki_y * $signed(32'(G_OKI)); // (73-bit context: OKI Q16 * G_OKI << 14 is the OKI in the scale of fin * RECIP)
        end
        if (prd_v) begin
            rnd_l <= prd_l + (prd_k <<< (SHIFT - 16)) + (73'sd1 <<< (SHIFT + 7));
            rnd_r <= prd_r + (prd_k <<< (SHIFT - 16)) + (73'sd1 <<< (SHIFT + 7));
        end
        rnd_v <= prd_v;
        if (rnd_v) begin
            out_l <= sat(avg_l);
            out_r <= sat(avg_r);
            out_valid <= 1'b1;
        end
    end
endmodule

// ---------------------------------------------------------------------------------------------------------------------------------------
// The OKI's output resampled as MAME 0.289's audio_resampler_lofi resamples a stream slower than the output: from the last four input
// samples s0..s3 (s3 the newest), the value between s1 and s2 at the phase p of the output time,
//
//   y = - s0 * f0(1 - p) + s1 * f1(1 - p) + s2 * f1(p) - s3 * f0(p),     f0(t) = (t - t^3) / 6,   f1(t) = t + (t^2 - t^3) / 2
//
// ("a nice 4-point formula used in yamaha devices from around 2000"; the weights sum to 1).  Here the output time runs two input samples
// behind: p = clocks since s3 came / the input period (6,336 clocks: 96 MHz / 48 / 132), in Q16; the weights in Q16 (MAME's table: 4,096
// phases in float).  `take` one clock -> `y` (Q16, the input's scale) with `y_valid` seven clocks later.
module ts_oki_interp #(
    parameter integer PER = 6336,                  // clocks per input sample
    parameter integer PMUL = 42367                 // round(65536 * 4096 / PER): p = c * PMUL >> 12
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               smp,                 // the input changes at the next clock
    input  wire signed [13:0] din,
    input  wire               take,
    output logic signed [33:0] y,
    output logic              y_valid
);
    logic               smp_d;
    logic signed [13:0] s0, s1, s2, s3;
    logic [12:0]        c;
    always_ff @(posedge clk) begin
        smp_d <= smp;
        if (rst) begin
            s0 <= '0; s1 <= '0; s2 <= '0; s3 <= '0; c <= '0;
        end else if (smp_d) begin
            s0 <= s1; s1 <= s2; s2 <= s3; s3 <= din; c <= '0;
        end else if (c != 13'(PER - 1)) c <= c + 13'd1;
    end

    // the pipeline: phase, squares, cubes, weights, products, sum
    logic [6:0]         v;
    logic signed [13:0] a0, a1, a2, a3;
    logic [17:0]        tp, tq, p2, q2, p3, q3, w0, w1, w2, w3;
    logic [29:0]        cm;
    logic signed [32:0] m0, m1, m2, m3;
    always_ff @(posedge clk) begin
        v <= {v[5:0], take & ~rst};
        // 1: the phase (c < 6336: c * 42367 < 2^29, p < 65536)
        if (take) begin cm <= c * 30'(PMUL); a0 <= s0; a1 <= s1; a2 <= s2; a3 <= s3; end
        // 2: p and 1 - p in Q16
        if (v[0]) begin tp <= 18'(cm >> 12); tq <= 18'd65536 - 18'(cm >> 12); end
        // 3: squares
        if (v[1]) begin p2 <= 18'((36'(tp) * 36'(tp)) >> 16); q2 <= 18'((36'(tq) * 36'(tq)) >> 16); end
        // 4: cubes
        if (v[2]) begin p3 <= 18'((36'(p2) * 36'(tp)) >> 16); q3 <= 18'((36'(q2) * 36'(tq)) >> 16); end
        // 5: the weights: w0 = f0(1 - p), w1 = f1(1 - p), w2 = f1(p), w3 = f0(p)  (1/6 as 10923 / 65536)
        if (v[3]) begin
            w0 <= 18'((36'(tq - q3) * 36'd10923) >> 16);
            w1 <= tq + ((q2 - q3) >> 1);
            w2 <= tp + ((p2 - p3) >> 1);
            w3 <= 18'((36'(tp - p3) * 36'd10923) >> 16);
        end
        // 6: products
        if (v[4]) begin
            m0 <= a0 * $signed({1'b0, w0});
            m1 <= a1 * $signed({1'b0, w1});
            m2 <= a2 * $signed({1'b0, w2});
            m3 <= a3 * $signed({1'b0, w3});
        end
        // 7: the sum
        if (v[5]) y <= 34'(m1) + 34'(m2) - 34'(m0) - 34'(m3);
        y_valid <= v[5];
    end
endmodule
`default_nettype wire
