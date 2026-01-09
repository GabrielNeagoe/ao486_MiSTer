// -----------------------------------------------------------------------------
// fp64_sqrt.v - synthesizable binary64 sqrt (Phase 4)
// - Fixed-iteration digit-by-digit (restoring) sqrt on normalized mantissa.
// - IEEE-754 special cases: NaN/Inf/zero/negative.
// - Subnormals: normalized with bounded loop (no while).
// - Rounding: truncation of guard bit; inexact asserted when remainder != 0.
// -----------------------------------------------------------------------------
module fp64_sqrt(
    input  wire [63:0] a,
    output reg  [63:0] y,
    output reg         invalid,
    output reg         inexact
);
    integer i;

    // Decomposed fields
    reg        s;
    reg [10:0] ea;
    reg [51:0] fa;

    // Working
    reg [63:0] nan_q;

    // Normalized mantissa (53-bit including implicit 1) and unbiased exponent
    reg [52:0] mant;
    reg [52:0] mant_adj;
    integer    exp_unb;      // unbiased exponent (signed)
    integer    exp_unb_even; // adjusted to even for sqrt
    integer    shift_cnt;
    reg        found_one;

    // Digit-by-digit sqrt state
    reg [107:0] rad;
    reg [109:0] rem;
    reg [53:0]  root;      // 54 bits: 53 mantissa bits + guard
    reg [55:0]  trial;
    reg [109:0] trial_ext;

    reg [10:0] e_out;

    always @* begin
        // Defaults to avoid latches
        invalid   = 1'b0;
        inexact   = 1'b0;
        y         = 64'd0;

        nan_q     = 64'h7FF8_0000_0000_0000;

        s  = a[63];
        ea = a[62:52];
        fa = a[51:0];

        mant       = 53'd0;
        mant_adj   = 53'd0;
        exp_unb    = 0;
        exp_unb_even = 0;
        shift_cnt  = 0;
        found_one  = 1'b0;

        rad        = 108'd0;
        rem        = 110'd0;
        root       = 54'd0;
        trial      = 56'd0;
        trial_ext  = 110'd0;
        e_out      = 11'd0;

        // NaN
        if (ea == 11'h7FF && fa != 0) begin
            y = a | 64'h0008_0000_0000_0000; // quiet it
        end
        // Inf
        else if (ea == 11'h7FF) begin
            if (s) begin
                invalid = 1'b1;
                y       = nan_q;
            end
            else begin
                y = a;
            end
        end
        // Zero
        else if (ea == 11'd0 && fa == 52'd0) begin
            y = a; // preserve signed zero
        end
        // Negative (non-zero)
        else if (s) begin
            invalid = 1'b1;
            y       = nan_q;
        end
        else begin
            // Build mantissa and unbiased exponent
            if (ea == 11'd0) begin
                // Subnormal: normalize mantissa with bounded loop.
                mant = {1'b0, fa};
                exp_unb = (1 - 1023); // unbiased exponent for subnormal before normalization

                found_one = 1'b0;
                shift_cnt = 0;
                for (i = 0; i < 53; i = i + 1) begin
                    if (!found_one) begin
                        if (mant[52] == 1'b1) begin
                            found_one = 1'b0; // stop shifting after this iteration
                            // Use an explicit latch-free stop by setting shift_cnt max and keeping mant.
                            // (We cannot 'break' in Verilog-2001 reliably for Quartus.)
                            shift_cnt = shift_cnt;
                        end
                        else begin
                            mant      = mant << 1;
                            shift_cnt = shift_cnt + 1;
                        end
                        if (mant[52] == 1'b1) begin
                            found_one = 1'b1;
                        end
                    end
                end
                // Adjust exponent by number of shifts.
                exp_unb = exp_unb - shift_cnt;
                // If mantissa became zero (shouldn't for non-zero subnormal), return +0.
                if (mant == 53'd0) begin
                    y = 64'd0;
                end
            end
            else begin
                mant    = {1'b1, fa};
                exp_unb = $signed({1'b0, ea}) - 1023;
            end

            // If we got here from subnormal non-zero, mant[52] should be 1 now.
            // Ensure exponent is even for sqrt; if odd, shift mantissa left and decrement exponent.
            exp_unb_even = exp_unb;
            if ((exp_unb_even & 1) != 0) begin
                mant_adj    = mant << 1;
                exp_unb_even = exp_unb_even - 1;
            end
            else begin
                mant_adj = mant;
            end

            // Construct radicand: mantissa (53 bits) followed by zeros to supply 2 bits/iter.
            // 54 iterations => consume 108 bits (2*54)
            rad  = {mant_adj, 55'd0};

            // Digit-by-digit restoring sqrt
            rem  = 110'd0;
            root = 54'd0;

            for (i = 0; i < 54; i = i + 1) begin
                rem = (rem << 2) | rad[107 - (2*i) -: 2];

                // trial = (root<<2) + 1 in the digit-by-digit algorithm representation:
                // Here we use {root,2'b01} which equals (root<<2) + 1.
                trial = {root, 2'b01};
                trial_ext = { { (110-56){1'b0} }, trial };

                if (rem >= trial_ext) begin
                    rem  = rem - trial_ext;
                    root = (root << 1) | 1'b1;
                end
                else begin
                    root = (root << 1);
                end
            end

            inexact = (rem != 0);

            // root[53:1] holds 53-bit mantissa; root[0] is guard (truncated)
            // Compute output exponent: (exp_unb_even/2) + bias
            // exp_unb_even is even by construction.
            e_out = ( (exp_unb_even >>> 1) + 1023 );

            // Handle exponent under/overflow conservatively:
            if (e_out[10] === 1'bx) begin
                // Should not happen; safe zero.
                y = 64'd0;
            end
            else if (e_out >= 11'h7FF) begin
                // Overflow to +Inf
                y = {1'b0, 11'h7FF, 52'd0};
                inexact = 1'b1;
            end
            else if (e_out == 11'd0) begin
                // Underflow to subnormal/zero: crude handling (shift mantissa right).
                // For Phase 4 functional coverage, emit zero and flag inexact.
                y = 64'd0;
                inexact = 1'b1;
            end
            else begin
                y = {1'b0, e_out, root[52:1]};
            end
        end
    end
endmodule
