
module fp64_cmp(
    input  wire [63:0] a,
    input  wire [63:0] b,
    output wire        lt,
    output wire        eq,
    output wire        gt
);
    wire [10:0] ea = a[62:52];
    wire [51:0] fa = a[51:0];
    wire [10:0] eb = b[62:52];
    wire [51:0] fb = b[51:0];

    wire a_ok = (ea == 0 && fa == 0) || (ea != 0 && ea != 11'h7FF);
    wire b_ok = (eb == 0 && fb == 0) || (eb != 0 && eb != 11'h7FF);

    wire [63:0] a0 = a_ok ? a : 64'd0;
    wire [63:0] b0 = b_ok ? b : 64'd0;

    wire sa = a0[63];
    wire sb = b0[63];

    wire a_zero = (a0[62:0] == 63'd0);
    wire b_zero = (b0[62:0] == 63'd0);

    wire both_zero = a_zero && b_zero;

    assign eq = both_zero ? 1'b1 : (a0 == b0);

    wire sign_diff = sa ^ sb;

    wire pos_lt = (a0[62:0] < b0[62:0]);
    wire pos_gt = (a0[62:0] > b0[62:0]);
    wire neg_lt = (a0[62:0] > b0[62:0]);
    wire neg_gt = (a0[62:0] < b0[62:0]);

    assign lt = eq ? 1'b0 :
                (sign_diff ? (sa && !sb) :
                 (sa ? neg_lt : pos_lt));

    assign gt = eq ? 1'b0 :
                (sign_diff ? (!sa && sb) :
                 (sa ? neg_gt : pos_gt));

endmodule
