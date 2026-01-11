`include "defines.v"
module fp64_exp2 (
    input  wire [63:0] a,
    output wire [63:0] y,
    output wire        overflow,
    output wire        underflow,
    output wire        inexact
);

function [63:0] int_to_fp64;
        input signed [12:0] iv;
        reg s2;
        reg [12:0] mag;
        integer msb;
        integer i;
        reg found;
        reg [10:0] e2;
        reg [52:0] mant53;
        begin
            if (iv == 0) begin
                int_to_fp64 = 64'h0;
            end
            else begin
                s2 = iv[12];
                mag = s2 ? -iv : iv;
                msb = 0;
                found = 1'b0;
                for (i = 12; i >= 0; i = i - 1) begin
                    if (!found && mag[i]) begin
                        msb = i;
                        found = 1'b1;
                    end
                end
                e2 = 11'd1023 + msb;
                mant53 = {40'd0, mag} << (52-msb);
                int_to_fp64 = {s2, e2, mant53[51:0]};
            end
        end
    endfunction

    wire sign;
    assign sign = a[63];
    wire [10:0] exp;
    assign exp = a[62:52];
    wire [51:0] frac;
    assign frac = a[51:0];

    wire is_zero;
    assign is_zero = (exp == 11'd0) && (frac == 52'd0);
    wire is_inf;
    assign is_inf = (exp == 11'h7FF) && (frac == 52'd0);
    wire is_nan;
    assign is_nan = (exp == 11'h7FF) && (frac != 52'd0);

    assign inexact = 1'b1;

    function signed [12:0] fp64_to_int_trunc;
        input [63:0] dv;
        reg s;
        reg [10:0] ex;
        reg [51:0] fr;
        reg [52:0] mant;
        integer sh;
        reg [63:0] val;
        begin
            s  = dv[63];
            ex = dv[62:52];
            fr = dv[51:0];
            if (ex == 0) begin
                fp64_to_int_trunc = 13'sd0;
            end
            else if (ex >= 11'd1023 + 13) begin
                fp64_to_int_trunc = s ? -13'sd1024 : 13'sd1024;
            end
            else begin
                mant = {1'b1, fr};
                sh = ex - 11'd1023;
                if (sh < 0) val = 0;
                else if (sh > 52) val = mant << (sh-52);
                else val = mant >> (52-sh);
                fp64_to_int_trunc = s ? -$signed(val[12:0]) : $signed(val[12:0]);
            end
        end
    endfunction

    wire signed [12:0] n = fp64_to_int_trunc(a);

    

    wire [63:0] n_fp;
    assign n_fp = int_to_fp64(n);
    wire [63:0] n_fp_neg;
    assign n_fp_neg = n_fp ^ 64'h8000000000000000;
    wire [63:0] f;
    fp64_add u_f(.a(a), .b(n_fp_neg), .y(f));

    localparam [63:0] C0 = 64'h3FF0000000000000;
    localparam [63:0] C1 = 64'h3FE62E42FEFA39EF;
    localparam [63:0] C2 = 64'h3FCEBFBDFF82C58E;
    localparam [63:0] C3 = 64'h3FAC6B08D704A0BF;
    localparam [63:0] C4 = 64'h3F83B2AB6FBA4E77;
    localparam [63:0] C5 = 64'h3F55D87FE78A6730;
    localparam [63:0] C6 = 64'h3F2430912F86C786;

    wire [63:0] f2,f3,f4,f5,f6;
    fp64_mul u_f2(.a(f),  .b(f),  .y(f2));
    fp64_mul u_f3(.a(f2), .b(f),  .y(f3));
    fp64_mul u_f4(.a(f2), .b(f2), .y(f4));
    fp64_mul u_f5(.a(f4), .b(f),  .y(f5));
    fp64_mul u_f6(.a(f3), .b(f3), .y(f6));

    wire [63:0] t1,t2,t3,t4,t5,t6;
    fp64_mul u_t1(.a(C1), .b(f),  .y(t1));
    fp64_mul u_t2(.a(C2), .b(f2), .y(t2));
    fp64_mul u_t3(.a(C3), .b(f3), .y(t3));
    fp64_mul u_t4(.a(C4), .b(f4), .y(t4));
    fp64_mul u_t5(.a(C5), .b(f5), .y(t5));
    fp64_mul u_t6(.a(C6), .b(f6), .y(t6));

    wire [63:0] s01,s012,s0123,s01234,s012345, base;
    fp64_add u_s01    (.a(C0), .b(t1), .y(s01));
    fp64_add u_s012   (.a(s01),.b(t2), .y(s012));
    fp64_add u_s0123  (.a(s012),.b(t3), .y(s0123));
    fp64_add u_s01234 (.a(s0123),.b(t4), .y(s01234));
    fp64_add u_s012345(.a(s01234),.b(t5), .y(s012345));
    fp64_add u_base   (.a(s012345),.b(t6), .y(base));

    wire [10:0] base_exp;
    assign base_exp = base[62:52];
    wire signed [12:0] exp_adj = $signed({2'b00,base_exp}) + n;
    assign overflow  = (!is_nan) && (exp_adj >= 13'sd2047);
    assign underflow = (!is_nan) && (exp_adj <= 13'sd0);

    wire [63:0] scaled = (base_exp == 0) ? base :
                         overflow ? 64'h7FF0000000000000 :
                         underflow ? 64'h0 :
                         {base[63], exp_adj[10:0], base[51:0]};

    assign y = is_nan ? {1'b0,11'h7FF,1'b1,frac[50:0]} :
               is_inf ? (sign ? 64'h0 : 64'h7FF0000000000000) :
               is_zero ? 64'h3FF0000000000000 :
               scaled;
endmodule