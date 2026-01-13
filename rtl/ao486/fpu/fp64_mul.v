
module fp64_mul(
    input  wire [63:0] a,
    input  wire [63:0] b,
    output wire [63:0] y,
    output wire        inexact,
    output wire        overflow,
    output wire        underflow
);
    localparam [10:0] BIAS = 11'd1023;

    wire sa = a[63];
    wire sb = b[63];
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

    wire a_zero = (eA == 11'd0) && (fA == 52'd0);
    wire b_zero = (eB == 11'd0) && (fB == 52'd0);

    wire [52:0] mA = (eA == 11'd0) ? 53'd0 : {1'b1, fA};
    wire [52:0] mB = (eB == 11'd0) ? 53'd0 : {1'b1, fB};

    wire sR = sA ^ sB;

    wire [12:0] exp_sum = {2'b00,eA} + {2'b00,eB} - {2'b00,BIAS};
    wire [105:0] prod = mA * mB;

    wire prod_ge_2 = prod[105];
    wire [105:0] prod_n = prod_ge_2 ? (prod >> 1) : prod;
    wire [12:0]  exp_n  = prod_ge_2 ? (exp_sum + 13'd1) : exp_sum;

    wire [52:0] mant = prod_n[104:52];

    wire out_zero = a_zero || b_zero;

    // -----------------------------------------------------------
    // Phase 8A: rounding (RN-even) + overflow/underflow/inexact
    // Notes:
    // - Rounding control is not provided on this module interface; default is RN-even.
    // - Denorm/NaN/Inf inputs are already treated as zero by the 'use_a/use_b' gating above.
    // - Underflow handling is flush-to-zero (no subnormal output).
    // -----------------------------------------------------------

    // Discarded product bits for rounding
    wire [51:0] discard = prod_n[51:0];
    wire guard_bit  = discard[51];
    wire round_bit  = discard[50];
    wire sticky_bit = |discard[49:0];
    wire lsb_bit    = mant[0];

    wire discard_nz = guard_bit | round_bit | sticky_bit;

    // Round-to-nearest, ties-to-even
    wire round_inc = guard_bit & (round_bit | sticky_bit | lsb_bit);

    wire [53:0] mant_ext = {1'b0, mant} + {53'd0, round_inc};
    wire mant_carry = mant_ext[53];
    wire [52:0] mant_r = mant_carry ? mant_ext[53:1] : mant_ext[52:0];

    // Signed exponent tracking (prevents wrap-around on underflow)
    wire signed [13:0] exp_sum_s = $signed({3'b000, eA}) + $signed({3'b000, eB}) - 14'sd1023;
    wire signed [13:0] exp_n_s   = prod_ge_2 ? (exp_sum_s + 14'sd1) : exp_sum_s;
    wire signed [13:0] exp_r_s   = mant_carry ? (exp_n_s + 14'sd1) : exp_n_s;

    // Determine final classification
    wire exp_over = (exp_r_s >= 14'sd2047);
    wire exp_under = (exp_r_s <= 14'sd0);

    wire [10:0] e_out = exp_r_s[10:0];
    wire [51:0] f_out = mant_r[51:0];

    // Outputs
    assign y = out_zero ? 64'd0 : (exp_over ? {sR, 11'h7FF, 52'd0} : (exp_under ? 64'd0 : {sR, e_out, f_out}));

    assign overflow  = out_zero ? 1'b0 : exp_over;
    assign underflow = out_zero ? 1'b0 : exp_under;
    assign inexact   = out_zero ? 1'b0 : (discard_nz | overflow | underflow);

endmodule
