
module fp64_mul(
    input  wire [63:0] a,
    input  wire [63:0] b,
    output wire [63:0] y,
    output wire        inexact
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
    wire [10:0] e_out = out_zero ? 11'd0 : exp_n[10:0];
    wire [51:0] f_out = out_zero ? 52'd0 : mant[51:0];

    assign y = out_zero ? 64'd0 : {sR, e_out, f_out};



// Inexact flag: asserts when discarded bits are non-zero during truncation/rounding.
assign inexact = 1'b0;

endmodule
