
// -----------------------------------------------------------------------------
// fp64_add.v - Minimal IEEE-754 binary64 adder (Phase 2C)
//  - Supports normal numbers and zero.
//  - Denormals treated as zero.
//  - NaN/Inf not supported (treated as zero).
//  - Rounding: truncation (toward zero).
// Synthesis note: fully combinational; resource-heavy but compiles on Quartus.
// -----------------------------------------------------------------------------
module fp64_add(
    input  wire [63:0] a,
    input  wire [63:0] b,
    output wire [63:0] y
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

    wire [10:0] e_max = (eA >= eB) ? eA : eB;
    wire [10:0] e_min = (eA >= eB) ? eB : eA;
    wire [10:0] e_diff = e_max - e_min;

    wire [52:0] mA_s = (eA >= eB) ? mA : (mA >> e_diff);
    wire [52:0] mB_s = (eA >= eB) ? (mB >> e_diff) : mB;
    wire sR_A = (eA >= eB) ? sA : sB;
    wire sR_B = (eA >= eB) ? sB : sA;

    wire do_sub = (sR_A ^ sR_B);
    wire [53:0] sum_add = {1'b0,mA_s} + {1'b0,mB_s};
    wire [53:0] sum_sub = (mA_s >= mB_s) ? ({1'b0,mA_s} - {1'b0,mB_s}) : ({1'b0,mB_s} - {1'b0,mA_s});
    wire res_sign = do_sub ? ((mA_s >= mB_s) ? sR_A : sR_B) : sR_A;

    wire [53:0] mant_pre = do_sub ? sum_sub : sum_add;
    wire [10:0] exp_pre  = e_max;

    reg [53:0] mant_norm;
    reg [10:0] exp_norm;
    reg        norm_done;
    integer i;

    always @(*) begin
        mant_norm = mant_pre;
        exp_norm  = exp_pre;
        norm_done = 1'b1;

        if (mant_pre == 54'd0) begin
            mant_norm = 54'd0;
            exp_norm  = 11'd0;
        end
        else if (!do_sub && mant_pre[53]) begin
            mant_norm = mant_pre >> 1;
            exp_norm  = exp_pre + 11'd1;
        end
        else begin
            norm_done = 1'b0;

            /* Normalize left until leading 1 reaches bit[52] or exponent underflows.
             * Bounded loop for Quartus (constant maximum iterations).
             */
            for (i = 0; i < 54; i = i + 1) begin
                if (!norm_done) begin
                    if (mant_norm[52] == 1'b1) begin
                        norm_done = 1'b1;
                    end
                    else if (exp_norm != 11'd0) begin
                        mant_norm = mant_norm << 1;
                        exp_norm  = exp_norm - 11'd1;
                    end
                    else begin
                        // exponent underflow -> treat as zero (no denorm support in this minimal core)
                        mant_norm = 54'd0;
                        exp_norm  = 11'd0;
                        norm_done = 1'b1;
                    end
                end
            end
        end
    end

    wire out_is_zero = (exp_norm == 11'd0) || (mant_norm[52:0] == 53'd0);
    wire [51:0] frac_out = out_is_zero ? 52'd0 : mant_norm[51:0];

    assign y = out_is_zero ? 64'd0 : {res_sign, exp_norm, frac_out};

endmodule
