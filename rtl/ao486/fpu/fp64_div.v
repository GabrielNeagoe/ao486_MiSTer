// -----------------------------------------------------------------------------
// fp64_div.v - Quartus-safe IEEE-754 binary64 divider (minimal)
// - Normal numbers only (treat NaN/Inf/denorm as zero)
// - Fixed-iteration restoring division for mantissa (54 iterations)
// -----------------------------------------------------------------------------
module fp64_div(
    input  wire [63:0] a,
    input  wire [63:0] b,
    output reg  [63:0] y,
    output reg inexact,
    output reg overflow,
    output reg underflow
);
    integer i;

    reg sign_a, sign_b, sign_y;
    reg [10:0] exp_a, exp_b;
    reg [52:0] man_a, man_b; // include hidden 1
    reg [10:0] exp_y;

    reg [107:0] rem;
    reg [53:0]  quot; // 54-bit quotient (includes guard)
    reg [53:0]  den;

    reg [52:0] man_y;
    reg [10:0] exp_adj;

    always @(*) begin
        // defaults
        y = 64'd0;
        inexact = 1'b0;
        overflow = 1'b0;
        underflow = 1'b0;

        sign_a = a[63];
        sign_b = b[63];
        sign_y = sign_a ^ sign_b;

        exp_a = a[62:52];
        exp_b = b[62:52];

        // Minimal special-case handling: if b==0 or a==0 -> 0 (safe stub)
        if (b[62:0] == 63'd0 || a[62:0] == 63'd0) begin
            y = {sign_y, 11'd0, 52'd0};
        end
        else if (exp_a == 11'd0 || exp_b == 11'd0 || exp_a == 11'h7FF || exp_b == 11'h7FF) begin
            // denorm/NaN/Inf not supported yet
            y = {sign_y, 11'd0, 52'd0};
        end
        else begin
            man_a = {1'b1, a[51:0]};
            man_b = {1'b1, b[51:0]};

            // exponent: (a_exp - b_exp) + bias
            exp_y = exp_a - exp_b + 11'd1023;

            // Restoring division: compute (man_a << 53) / man_b to get 54 bits
            rem  = {55'd0, man_a, 53'd0};  // align numerator
            den  = {1'b0, man_b};          // 54-bit

            quot = 54'd0;

            // Fixed 54 iterations, MSB-first
            for (i = 0; i < 54; i = i + 1) begin
                rem = rem << 1;
                quot = quot << 1;
                if (rem[107:54] >= den) begin
                    rem[107:54] = rem[107:54] - den;
                    quot[0] = 1'b1;
                end
            end

            // Normalize: ensure leading 1 at bit 53 of quot (expected), adjust exponent if needed
            exp_adj = exp_y;
            if (quot[53] == 1'b0) begin
                // shift left by 1 if quotient < 1.0
                quot = quot << 1;
                exp_adj = exp_y - 11'd1;
            end

            // Take mantissa (drop hidden 1), simple truncation of guard bit(s)
            man_y = quot[52:0]; // includes hidden 1 at [52] after normalization
            y = {sign_y, exp_adj, man_y[51:0]};
            inexact = (rem != 0);
        end
    end


// Inexact flag: asserts when discarded bits are non-zero during truncation/rounding.

endmodule
