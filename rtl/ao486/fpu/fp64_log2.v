`include "defines.v"
module fp64_log2 (
    input  wire [63:0] a,
    output wire [63:0] y,
    output wire        invalid,
    output wire        inexact
);
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

    assign invalid = (sign && !is_zero) || is_zero;
    assign inexact = 1'b1;

    wire [63:0] m;
    assign m = {1'b0, 11'd1023, frac};
    wire [63:0] t;
    fp64_add u_t(.a(m), .b(64'hBFF0000000000000), .y(t));

    wire [63:0] t2, t3, t4, t5, t6;
    fp64_mul u_t2(.a(t),  .b(t),  .y(t2));
    fp64_mul u_t3(.a(t2), .b(t),  .y(t3));
    fp64_mul u_t4(.a(t2), .b(t2), .y(t4));
    fp64_mul u_t5(.a(t4), .b(t),  .y(t5));
    fp64_mul u_t6(.a(t3), .b(t3), .y(t6));

    localparam [63:0] C1 = 64'h3FF71547652B82FE;
    localparam [63:0] C2 = 64'hBFE71547652B82FE;
    localparam [63:0] C3 = 64'h3FDEC709DC3A03FD;
    localparam [63:0] C4 = 64'hBFD71547652B82FE;
    localparam [63:0] C5 = 64'h3FD2776C50EF9BFF;
    localparam [63:0] C6 = 64'hBFCEC709DC3A03FD;

    wire [63:0] p1,p2,p3,p4,p5,p6;
    fp64_mul u_p1(.a(C1), .b(t),  .y(p1));
    fp64_mul u_p2(.a(C2), .b(t2), .y(p2));
    fp64_mul u_p3(.a(C3), .b(t3), .y(p3));
    fp64_mul u_p4(.a(C4), .b(t4), .y(p4));
    fp64_mul u_p5(.a(C5), .b(t5), .y(p5));
    fp64_mul u_p6(.a(C6), .b(t6), .y(p6));

    wire [63:0] s12,s123,s1234,s12345, logm;
    fp64_add u_s12    (.a(p1),      .b(p2), .y(s12));
    fp64_add u_s123   (.a(s12),     .b(p3), .y(s123));
    fp64_add u_s1234  (.a(s123),    .b(p4), .y(s1234));
    fp64_add u_s12345 (.a(s1234),   .b(p5), .y(s12345));
    fp64_add u_logm   (.a(s12345),  .b(p6), .y(logm));

    /*
     * Quartus-safe helper: convert a small signed integer to IEEE-754 fp64.
     * Intended for values within a few thousand (e.g. unbiased exponent).
     */
    function [63:0] int_to_fp64;
        input signed [12:0] i;
        reg s;
        reg [12:0] a;
        reg [4:0] msb;
        reg [52:0] mant;
        integer k;
        begin
            if(i == 13'sd0) begin
                int_to_fp64 = 64'd0;
            end
            else begin
                s = i[12];
                a = s ? (~i + 13'd1) : i;
                msb = 5'd0;
                for (k = 12; k>=0; k=k-1) begin
                    if(a[k]) msb = k[4:0];
                end

                /* Normalize |a| so the leading 1 lands at mant[52]. */
                mant = {a, 40'd0};
                if(msb < 5'd52) mant = mant << (52 - msb);
                else            mant = mant >> (msb - 52);

                int_to_fp64 = {s, (11'd1023 + msb), mant[51:0]};
            end
        end
    endfunction

    wire signed [12:0] e_unb = $signed({2'b00,exp}) - 13'sd1023;

    

    wire [63:0] e_fp;
    assign e_fp = int_to_fp64(e_unb);
    wire [63:0] y_raw;
    fp64_add u_y(.a(e_fp), .b(logm), .y(y_raw));

    assign y = (is_nan) ? {1'b0,11'h7FF,1'b1,frac[50:0]} :
               (is_inf && !sign) ? a :
               (invalid) ? 64'h7FF8_0000_0000_0000 :
               y_raw;
endmodule