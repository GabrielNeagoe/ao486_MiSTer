// fp64_add.v - binary64 adder (Phase 8A)
// Verilog-2001; no tasks/functions; constant-bounded loops only.
// Inputs: normals+zero. Denorm/NaN/Inf treated as zero (legacy).
// Rounding: round-to-nearest, ties-to-even.
// Subnormal results flushed to zero.

module fp64_add(
    input  wire [63:0] a,
    input  wire [63:0] b,
    output wire [63:0] y,
    output wire        inexact,
    output wire        overflow,
    output wire        underflow
);
    wire [10:0] ea = a[62:52];
    wire [10:0] eb = b[62:52];
    wire [51:0] fa = a[51:0];
    wire [51:0] fb = b[51:0];

    wire a_is_zero = (ea == 11'd0) && (fa == 52'd0);
    wire b_is_zero = (eb == 11'd0) && (fb == 52'd0);
    wire a_is_norm = (ea != 11'd0) && (ea != 11'h7FF);
    wire b_is_norm = (eb != 11'd0) && (eb != 11'h7FF);

    wire use_a = a_is_zero || a_is_norm;
    wire use_b = b_is_zero || b_is_norm;

    wire [63:0] a0 = use_a ? a : 64'd0;
    wire [63:0] b0 = use_b ? b : 64'd0;

    wire sA = a0[63];
    wire sB = b0[63];
    wire [10:0] eA = a0[62:52];
    wire [10:0] eB = b0[62:52];
    wire [51:0] fA = a0[51:0];
    wire [51:0] fB = b0[51:0];

    wire [52:0] mA = (eA == 11'd0) ? 53'd0 : {1'b1, fA};
    wire [52:0] mB = (eB == 11'd0) ? 53'd0 : {1'b1, fB};

    // Extend mantissas with GRS bits in [2:0]
    wire [55:0] mA_ext = {mA, 3'b000};
    wire [55:0] mB_ext = {mB, 3'b000};

    wire a_ge_b_exp = (eA >= eB);
    wire [10:0] e_max  = a_ge_b_exp ? eA : eB;
    wire [10:0] e_diff = a_ge_b_exp ? (eA - eB) : (eB - eA);

    wire s_big   = a_ge_b_exp ? sA : sB;
    wire s_small = a_ge_b_exp ? sB : sA;
    wire [55:0] m_big_in   = a_ge_b_exp ? mA_ext : mB_ext;
    wire [55:0] m_small_in = a_ge_b_exp ? mB_ext : mA_ext;

    reg [55:0] m_small_aligned;
    reg        align_sticky;
    integer k;

    always @(*) begin
        m_small_aligned = m_small_in;
        align_sticky    = 1'b0;

        // Shift right by e_diff, accumulating sticky in bit[0]
        for (k = 0; k < 56; k = k + 1) begin
            if (k < e_diff) begin
                align_sticky    = align_sticky | m_small_aligned[0];
                m_small_aligned = {1'b0, m_small_aligned[55:1]};
                m_small_aligned[0] = align_sticky;
            end
        end
    end

    wire [55:0] m_big_aligned = m_big_in;
    wire align_inexact = align_sticky;

    wire do_sub = (s_big ^ s_small);

    wire [56:0] add_sum = {1'b0, m_big_aligned} + {1'b0, m_small_aligned};

    wire big_ge_small_mag = (m_big_aligned >= m_small_aligned);
    wire [56:0] sub_sum = big_ge_small_mag ?
                          ({1'b0, m_big_aligned} - {1'b0, m_small_aligned}) :
                          ({1'b0, m_small_aligned} - {1'b0, m_big_aligned});

    wire res_sign_pre = do_sub ? (big_ge_small_mag ? s_big : s_small) : s_big;
    wire [56:0] mant_pre = do_sub ? sub_sum : add_sum;
    wire [10:0] exp_pre  = e_max;

    reg [56:0] mant_norm;
    reg [10:0] exp_norm;
    reg        flush_to_zero;
    integer i;

    always @(*) begin
        mant_norm = mant_pre;
        exp_norm  = exp_pre;
        flush_to_zero = 1'b0;

        if (mant_pre == 57'd0) begin
            mant_norm = 57'd0;
            exp_norm  = 11'd0;
        end
        else if (!do_sub && mant_pre[56]) begin
            // Carry out (addition): shift right and increment exponent.
            mant_norm = mant_pre >> 1;
            mant_norm[0] = mant_norm[0] | mant_pre[0];
            exp_norm  = exp_pre + 11'd1;
        end
        else begin
            // Normalize left until leading 1 reaches bit[55]
            for (i = 0; i < 57; i = i + 1) begin
                if (mant_norm != 57'd0 && mant_norm[55] == 1'b0) begin
                    if (exp_norm != 11'd0) begin
                        mant_norm = mant_norm << 1;
                        exp_norm  = exp_norm - 11'd1;
                    end
                    else begin
                        // Underflow: no denormal support -> flush to zero
                        flush_to_zero = 1'b1;
                        mant_norm = 57'd0;
                        exp_norm  = 11'd0;
                    end
                end
            end
        end
    end

    // Guard / Round / Sticky for RN-even rounding
    wire g_bit   = mant_norm[2];
    wire r_bit   = mant_norm[1];
    wire s_bit   = mant_norm[0];
    wire lsb_bit = mant_norm[3];

    wire rnd_inc = g_bit && (r_bit || s_bit || lsb_bit);
    wire [56:0] mant_rnd_pre = mant_norm + (rnd_inc ? 57'd8 : 57'd0); // +1 @ bit[3]

    reg  [56:0] mant_postrnd;
    reg  [10:0] exp_postrnd;
    always @(*) begin
        mant_postrnd = mant_rnd_pre;
        exp_postrnd  = exp_norm;
        if (!do_sub && mant_rnd_pre[56]) begin
            // Rounding carry: shift right and increment exponent.
            mant_postrnd = mant_rnd_pre >> 1;
            // Preserve sticky: old bit[1] or old bit[0]
            mant_postrnd[0] = mant_rnd_pre[1] | mant_rnd_pre[0];
            exp_postrnd  = exp_norm + 11'd1;
        end
    end

    wire exp_overflow = (exp_postrnd >= 11'h7FF);
    wire mag_nonzero_pre = (mant_pre != 57'd0);
    wire exp_underflow = flush_to_zero && mag_nonzero_pre;

    wire out_is_zero = (!exp_overflow) && ((exp_postrnd == 11'd0) || (mant_postrnd[55:3] == 53'd0));

    wire [51:0] frac_out = out_is_zero ? 52'd0 : mant_postrnd[54:3];
    wire [10:0] exp_out  = out_is_zero ? 11'd0 : exp_postrnd;

    assign overflow  = exp_overflow;
    assign underflow = exp_underflow;
    assign inexact   = exp_overflow || align_inexact || g_bit || r_bit || s_bit;

    assign y = exp_overflow ? {res_sign_pre, 11'h7FF, 52'd0} :
               (out_is_zero ? 64'd0 : {res_sign_pre, exp_out, frac_out});

endmodule
