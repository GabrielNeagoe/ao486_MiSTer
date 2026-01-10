`include "defines.v"
module fp64_sincos (
    input  wire [63:0] a,
    output wire [63:0] sin_y,
    output wire [63:0] cos_y,
    output wire        invalid,
    output wire        inexact
);
    wire [10:0] exp;
    assign exp = a[62:52];
    wire [51:0] frac;
    assign frac = a[51:0];
    wire is_inf;
    assign is_inf = (exp == 11'h7FF) && (frac == 0);
    wire is_nan;
    assign is_nan = (exp == 11'h7FF) && (frac != 0);

    assign invalid = is_inf;
    assign inexact = 1'b1;

    localparam [63:0] INV_PIO2 = 64'h3FE45F306DC9C883;
    localparam [63:0] PIO2     = 64'h3FF921FB54442D18;
    localparam [63:0] HALF     = 64'h3FE0000000000000;
    localparam [63:0] NEG_HALF = 64'hBFE0000000000000;
    localparam [63:0] ONE      = 64'h3FF0000000000000;
    localparam [63:0] QNAN     = 64'h7FF8_0000_0000_0000;

    wire [63:0] t;
    fp64_mul u_t(.a(a), .b(INV_PIO2), .y(t));

    wire [63:0] t_bias;
    assign t_bias = t[63] ? NEG_HALF : HALF;
    wire [63:0] t_round;
    fp64_add u_tr(.a(t), .b(t_bias), .y(t_round));

    function signed [31:0] fp64_to_int32_trunc;
        input [63:0] dv;
        reg s2;
        reg [10:0] ex2;
        reg [51:0] fr2;
        reg [52:0] mant;
        integer sh;
        reg [63:0] val;
        begin
            s2 = dv[63];
            ex2 = dv[62:52];
            fr2 = dv[51:0];
            if (ex2 == 0) begin
                fp64_to_int32_trunc = 32'sd0;
            end
            else if (ex2 >= 11'd1023 + 31) begin
                fp64_to_int32_trunc = s2 ? -32'sd2147483648 : 32'sd2147483647;
            end
            else begin
                mant = {1'b1, fr2};
                sh = ex2 - 11'd1023;
                if (sh < 0) val = 0;
                else if (sh > 52) val = mant << (sh-52);
                else val = mant >> (52-sh);
                fp64_to_int32_trunc = s2 ? -$signed(val[31:0]) : $signed(val[31:0]);
            end
        end
    endfunction

    wire signed [31:0] n = fp64_to_int32_trunc(t_round);
    wire [1:0] q;
    assign q = n[1:0];

    function [63:0] int32_to_fp64;
        input signed [31:0] iv;
        reg s3;
        reg [31:0] mag;
        integer msb;
        integer k;
        reg [10:0] e3;
        reg [52:0] mant53;
        begin
            if (iv == 0) begin
                int32_to_fp64 = 64'h0;
            end
            else begin
                s3 = iv[31];
                mag = s3 ? -iv : iv;
                msb = 0;
                for (k = 31; k>=0; k=k-1) begin
                    if (mag[k]) begin msb = k; k = -1; end
                end
                e3 = 11'd1023 + msb;
                mant53 = {1'b0, mag} << (52-msb);
                int32_to_fp64 = {s3, e3, mant53[51:0]};
            end
        end
    endfunction

    wire [63:0] n_fp;
    assign n_fp = int32_to_fp64(n);
    wire [63:0] np;
    fp64_mul u_np(.a(n_fp), .b(PIO2), .y(np));

    wire [63:0] r;
    fp64_add u_r(.a(a), .b(np ^ 64'h8000000000000000), .y(r));

    localparam [63:0] C_S3 = 64'hBFC5555555555555;
    localparam [63:0] C_S5 = 64'h3F81111111111111;
    localparam [63:0] C_S7 = 64'hBF2A01A01A01A01A;
    localparam [63:0] C_C2 = 64'hBFE0000000000000;
    localparam [63:0] C_C4 = 64'h3FA5555555555555;
    localparam [63:0] C_C6 = 64'hBF56C16C16C16C17;

    wire [63:0] r2,r3,r4,r5,r6,r7;
    fp64_mul u_r2(.a(r),  .b(r),  .y(r2));
    fp64_mul u_r3(.a(r2), .b(r),  .y(r3));
    fp64_mul u_r4(.a(r2), .b(r2), .y(r4));
    fp64_mul u_r5(.a(r4), .b(r),  .y(r5));
    fp64_mul u_r6(.a(r3), .b(r3), .y(r6));
    fp64_mul u_r7(.a(r6), .b(r),  .y(r7));

    wire [63:0] s3,s5,s7;
    fp64_mul u_s3(.a(C_S3), .b(r3), .y(s3));
    fp64_mul u_s5(.a(C_S5), .b(r5), .y(s5));
    fp64_mul u_s7(.a(C_S7), .b(r7), .y(s7));
    wire [63:0] sin_tmp1,sin_tmp2,sin_r;
    fp64_add u_sin1(.a(r),        .b(s3), .y(sin_tmp1));
    fp64_add u_sin2(.a(sin_tmp1), .b(s5), .y(sin_tmp2));
    fp64_add u_sin3(.a(sin_tmp2), .b(s7), .y(sin_r));

    wire [63:0] c2,c4,c6;
    fp64_mul u_c2(.a(C_C2), .b(r2), .y(c2));
    fp64_mul u_c4(.a(C_C4), .b(r4), .y(c4));
    fp64_mul u_c6(.a(C_C6), .b(r6), .y(c6));
    wire [63:0] cos_tmp1,cos_tmp2,cos_r;
    fp64_add u_cos1(.a(ONE),      .b(c2), .y(cos_tmp1));
    fp64_add u_cos2(.a(cos_tmp1), .b(c4), .y(cos_tmp2));
    fp64_add u_cos3(.a(cos_tmp2), .b(c6), .y(cos_r));

    function [63:0] neg;
        input [63:0] v;
        begin
            neg = v ^ 64'h8000000000000000;
        end
    endfunction

    reg [63:0] sin_sel, cos_sel;
    always @* begin
        case(q)
            2'd0: begin sin_sel = sin_r;       cos_sel = cos_r;       end
            2'd1: begin sin_sel = cos_r;       cos_sel = neg(sin_r);  end
            2'd2: begin sin_sel = neg(sin_r);  cos_sel = neg(cos_r);  end
            2'd3: begin sin_sel = neg(cos_r);  cos_sel = sin_r;       end
        endcase
    end

    assign sin_y = is_nan ? {1'b0,11'h7FF,1'b1,frac[50:0]} :
                   invalid ? QNAN :
                   sin_sel;
    assign cos_y = is_nan ? {1'b0,11'h7FF,1'b1,frac[50:0]} :
                   invalid ? QNAN :
                   cos_sel;
endmodule