module x87_exec (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [4:0]  cmd,
    input  wire        cmd_valid,
    input  wire [2:0]  idx,
    input  wire [3:0]  step,

    input  wire [31:0] mem_rdata32,
    input  wire [63:0] mem_rdata64,

    output reg         memstore_valid,
    output reg  [1:0]  memstore_size,
    output reg  [63:0] memstore_data64,

    output reg         busy,
    output reg         done,

    output reg         wb_valid,
    output reg  [2:0]  wb_kind,
    output reg  [15:0] wb_value
);
    // Writeback types
    localparam WB_NONE = 3'd0;
    localparam WB_AX   = 3'd1;

    // Command encodings (must match x87_decode)
    localparam CMD_NOP        = 5'd0;
    localparam CMD_FNSTSW_AX  = 5'd1;
    localparam CMD_FNINIT     = 5'd2;
    localparam CMD_FLDCW      = 5'd3;
    localparam CMD_FNSTCW     = 5'd4;
    localparam CMD_FWAIT      = 5'd5;
    localparam CMD_FLD_M32    = 5'd6;
    localparam CMD_FLD_M64    = 5'd7;
    localparam CMD_FSTP_M32   = 5'd8;
    localparam CMD_FSTP_M64   = 5'd9;

    localparam CMD_FLD_STI    = 5'd10;
    localparam CMD_FXCH_STI   = 5'd11;
    localparam CMD_FSTP_STI   = 5'd12;

    // Phase 2C.3 (operand ordering / pop variants)
    localparam CMD_FSUBP_STI  = 5'd13;
    localparam CMD_FSUBRP_STI = 5'd14;
    localparam CMD_FDIVRP_STI = 5'd15;

    // Phase 3 integer conversions (memory forms; size encoded in idx[0])
    localparam CMD_FILD_MEM   = 5'd16;
    localparam CMD_FIST_MEM   = 5'd17;
    localparam CMD_FISTP_MEM  = 5'd18;
    localparam CMD_FCOMPP     = 5'd16;

    localparam CMD_FADD_STI   = 5'd20;
    localparam CMD_FMUL_STI   = 5'd21;
    localparam CMD_FDIV_STI   = 5'd22;
    localparam CMD_FCOM_STI   = 5'd23;
    localparam CMD_FSUB_STI   = 5'd24;
    localparam CMD_FSUBR_STI  = 5'd25;
    localparam CMD_FCOMP_STI  = 5'd26;
    localparam CMD_FADDP_STI  = 5'd27;
    localparam CMD_FMULP_STI  = 5'd28;
    localparam CMD_FDIVP_STI  = 5'd29;

    localparam CMD_FDIVR_STI  = 5'd30;

    localparam CMD_FPREM      = 5'd19; // Phase 5A: 0=FPREM, 1=FPREM1


        localparam CMD_MISC       = 5'd31; // Phase 4 misc ops
// x87 state
    reg [15:0] fcw;  // control word
    reg [15:0] fsw;  // status word
    reg [15:0] ftw;  // tag word (2 bits/entry)
    reg [2:0]  top;

    // Stack storage (binary64)
    reg [63:0] st[0:7];

    // Helpers
    function [2:0] phys;
        input [2:0] logical;
        begin
            phys = top + logical;
        end
    endfunction

    // float32 -> float64 (minimal: normals + zero; denorm/NaN/Inf treated as zero)
    function [63:0] f32_to_f64;
        input [31:0] f;
        reg s;
        reg [7:0]  e;
        reg [22:0] m;
        reg [10:0] e64;
        begin
            s = f[31];
            e = f[30:23];
            m = f[22:0];
            if (e == 8'd0) begin
                f32_to_f64 = {s, 11'd0, 52'd0};
            end
            else if (e == 8'hFF) begin
                f32_to_f64 = 64'd0;
            end
            else begin
                e64 = {3'd0, e} - 11'd127 + 11'd1023;
                f32_to_f64 = {s, e64, {m, 29'd0}};
            end
        end
    endfunction

    // float64 -> float32 (minimal: truncation; out-of-range/NaN/Inf -> 0)
    function [31:0] f64_to_f32;
        input [63:0] d;
        reg s;
        reg [10:0] e;
        reg [51:0] m;
        reg [7:0] e32;
        begin
            s = d[63];
            e = d[62:52];
            m = d[51:0];
            if (e == 11'd0) begin
                f64_to_f32 = {s, 8'd0, 23'd0};
            end
            else if (e == 11'h7FF) begin
                f64_to_f32 = 32'd0;
            end
            else if (e < 11'd896 || e > 11'd1151) begin
                // outside normal float32 exponent range after bias conversion
                f64_to_f32 = 32'd0;
            end
            else begin
                e32 = e - 11'd1023 + 8'd127;
                f64_to_f32 = {s, e32, m[51:29]};
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helpers for Phase 5A
    // -------------------------------------------------------------------------
    // Round a float64 to an integral-valued float64. Returns {inexact, value}.
    function [64:0] round_int_f64;
        input [63:0] d;
        input [1:0]  rc; // 2'b11=trunc, 2'b00=nearest-even
        reg s;
        reg [10:0] e;
        reg [51:0] f;
        reg signed [12:0] exp_unb;
        reg [52:0] mant;
        reg [53:0] mant_int;
        reg [53:0] add_inc;
        reg [53:0] frac;
        reg [53:0] half;
        reg [53:0] mask;
        reg inex;
        reg [63:0] y;
        integer shift;
        begin
            s = d[63]; e = d[62:52]; f = d[51:0];
            inex = 1'b0; y = d;
            if (e == 11'h7FF) begin
                // NaN/Inf: propagate
                y = d; inex = 1'b0;
            end
            else if (e == 0) begin
                // subnormal/zero: |x| < 1
                if (rc == 2'b00) begin
                    // nearest-even: treat >=0.5 as 1 (ties-to-even => 0.5 -> 0)
                    if (f[51] == 1'b1) begin
                        // >= 0.5
                        y = {s, 11'd1023, 52'd0};
                        inex = 1'b1;
                    end
                    else begin
                        y = {s, 63'd0};
                        inex = (f != 0);
                    end
                end
                else begin
                    // trunc
                    y = {s, 63'd0};
                    inex = (f != 0);
                end
            end
            else begin
                exp_unb = $signed({1'b0,e}) - 13'sd1023;
                if (exp_unb >= 52) begin
                    y = d; inex = 1'b0;
                end
                else if (exp_unb < 0) begin
                    // |x| < 1
                    if (rc == 2'b00) begin
                        // nearest-even: if |x| > 0.5 -> 1, if ==0.5 -> 0
                        if (e > 11'd1022 || (e == 11'd1022 && f != 0)) begin
                            y = {s, 11'd1023, 52'd0};
                            inex = 1'b1;
                        end
                        else begin
                            y = {s, 63'd0};
                            inex = 1'b1;
                        end
                    end
                    else begin
                        y = {s, 63'd0};
                        inex = 1'b1;
                    end
                end
                else begin
                    shift = 52 - exp_unb;
                    mant = {1'b1,f};
                    mask = (shift >= 54) ? 54'h3FFF_FFFF_FFFF_FF : ((54'h1 << shift) - 1);
                    frac = {1'b0,mant} & mask;
                    inex = (frac != 0);
                    mant_int = {1'b0,mant} & ~mask;
                    add_inc = 54'd0;
                    if (inex) begin
                        if (rc == 2'b00) begin
                            // nearest-even
                            half = (shift==0) ? 54'd0 : (54'h1 << (shift-1));
                            if (frac > half) begin
                                add_inc = (54'h1 << shift);
                            end
                            else if (frac == half) begin
                                // tie: add if LSB of integer part is 1
                                if (shift < 54 && mant_int[shift] == 1'b1) add_inc = (54'h1 << shift);
                            end
                        end
                        // trunc: no increment
                    end
                    mant_int = mant_int + add_inc;
                    // Renormalize if carry shifted past hidden bit
                    if (mant_int[53] == 1'b1) begin
                        mant_int = mant_int >> 1;
                        y = {s, e + 11'd1, mant_int[51:0]};
                    end
                    else begin
                        y = {s, e, mant_int[51:0]};
                    end
                end
            end
            round_int_f64 = {inex, y};
        end
    endfunction

    // Truncate float64 to signed 32-bit (used by FSCALE exponent).
    function signed [31:0] f64_to_s32_trunc;
        input [63:0] d;
        reg s;
        reg [10:0] e;
        reg [51:0] f;
        reg signed [12:0] exp_unb;
        reg [52:0] mant;
        reg [63:0] mag;
        begin
            s = d[63]; e = d[62:52]; f = d[51:0];
            if (e == 11'h7FF) begin
                f64_to_s32_trunc = s ? -32'sd2147483648 : 32'sd2147483647;
            end
            else if (e == 0) begin
                f64_to_s32_trunc = 32'sd0;
            end
            else begin
                exp_unb = $signed({1'b0,e}) - 13'sd1023;
                if (exp_unb < 0) begin
                    f64_to_s32_trunc = 32'sd0;
                end
                else if (exp_unb > 31) begin
                    f64_to_s32_trunc = s ? -32'sd2147483648 : 32'sd2147483647;
                end
                else begin
                    mant = {1'b1,f};
                    mag = {11'd0, mant} >> (52-exp_unb);
                    f64_to_s32_trunc = s ? -$signed(mag[31:0]) : $signed(mag[31:0]);
                end
            end
        end
    endfunction



    // Convert signed 32-bit integer to IEEE-754 binary64 (exact for 32-bit range).
    function [63:0] s32_to_f64;
        input signed [31:0] v;
        reg s;
        reg [31:0] a;
        integer p;
        reg [10:0] e;
        reg [52:0] sig;
        begin
            if (v == 0) begin
                s32_to_f64 = 64'd0;
            end
            else begin
                s = v[31];
                a = s ? (~v + 32'd1) : v;
                p = 31;
                while (p > 0 && a[p] == 1'b0) p = p - 1;
                e = 11'd1023 + p[10:0];
                sig = {a, 21'd0} << (52 - p); // place leading 1 at bit52
                s32_to_f64 = {s, e, sig[51:0]};
            end
        end
    endfunction

    // Convert IEEE-754 binary64 to signed 32-bit integer with FCW.RC rounding.
    // Returns {invalid, inexact, value[31:0]}.
    function [33:0] f64_to_s32;
        input [63:0] x;
        input [1:0]  rc; // FCW[11:10]
        reg s;
        reg [10:0] e;
        reg [51:0] m;
        integer exp_unb;
        reg [52:0] sig;
        reg [63:0] int_abs;
        reg [63:0] rem_mask;
        reg [63:0] rem;
        reg inc;
        reg invalid, inexact;
        reg [31:0] res;
        begin
            s = x[63];
            e = x[62:52];
            m = x[51:0];

            invalid = 1'b0;
            inexact = 1'b0;
            inc     = 1'b0;
            res     = 32'd0;

            if (e == 11'h7FF) begin
                // NaN or Inf
                invalid = 1'b1;
                res     = 32'h80000000;
            end
            else begin
                exp_unb = $signed({1'b0,e}) - 1023;

                // Build significand. For subnormals (e==0), implicit leading 0.
                sig = (e == 11'd0) ? {1'b0, m} : {1'b1, m};

                if (exp_unb < 0) begin
                    // |x| < 1.0
                    inexact = (sig != 53'd0);
                    int_abs = 64'd0;

                    // Apply rounding that can produce +/-1
                    if (inexact) begin
                        case (rc)
                            2'b01: inc = s;        // toward -inf: negative -> -1
                            2'b10: inc = ~s;       // toward +inf: positive -> +1
                            2'b00: inc = 1'b0;     // nearest-even: <0.5 always
                            default: inc = 1'b0;   // trunc
                        endcase
                    end

                    if (inc) begin
                        res = s ? 32'hFFFFFFFF : 32'h00000001;
                    end
                    else begin
                        res = 32'd0;
                    end
                end
                else if (exp_unb > 31) begin
                    // overflow for signed 32-bit (even if exact)
                    invalid = 1'b1;
                    res     = 32'h80000000;
                end
                else begin
                    if (exp_unb >= 52) begin
                        int_abs = sig;
                        int_abs = int_abs << (exp_unb - 52);
                        rem     = 64'd0;
                    end
                    else begin
                        // shift right, capture remainder
                        rem_mask = (64'd1 << (52 - exp_unb)) - 1;
                        rem      = {11'd0, sig} & rem_mask;
                        int_abs  = {11'd0, sig} >> (52 - exp_unb);
                    end

                    inexact = (rem != 0);

                    // Determine increment based on rounding mode
                    if (inexact) begin
                        case (rc)
                            2'b11: inc = 1'b0; // trunc
                            2'b10: inc = ~s;   // +inf
                            2'b01: inc = s;    // -inf
                            default: begin
                                // nearest-even
                                // compare rem with half ULP
                                if (exp_unb < 52) begin
                                    // half = 1<<(51-exp_unb)
                                    reg [63:0] half;
                                    half = 64'd1 << (51 - exp_unb);
                                    if (rem > half) inc = 1'b1;
                                    else if (rem == half) inc = int_abs[0]; // tie to even
                                    else inc = 1'b0;
                                end
                                else inc = 1'b0;
                            end
                        endcase
                    end

                    if (inc) int_abs = int_abs + 1;

                    // Apply sign and range check
                    if (!s) begin
                        if (int_abs > 64'h7FFFFFFF) begin
                            invalid = 1'b1;
                            res     = 32'h80000000;
                        end
                        else res = int_abs[31:0];
                    end
                    else begin
                        // allow -2^31
                        if (int_abs > 64'h80000000) begin
                            invalid = 1'b1;
                            res     = 32'h80000000;
                        end
                        else res = (~int_abs[31:0]) + 32'd1;
                    end
                end
            end

            f64_to_s32 = {invalid, inexact, res};
        end
    endfunction

    // FP cores (combinational)
    wire [63:0] add_y, mul_y, div_y, divr_y;
    wire [63:0] sub_y, subr_y;
    wire cmp_lt, cmp_eq, cmp_gt;

    
    // Phase 4 misc
    wire [63:0] sqrt_y;
    wire        sqrt_invalid;
    wire        sqrt_inexact;
fp64_add u_add(.a(st[phys(3'd0)]), .b(st[phys(idx)]), .y(add_y));
    fp64_mul u_mul(.a(st[phys(3'd0)]), .b(st[phys(idx)]), .y(mul_y));
    fp64_div u_div(.a(st[phys(3'd0)]), .b(st[phys(idx)]), .y(div_y));
    // Swapped-operand divide for FDIVR and FDIVP-style encodings
    fp64_div u_divr(.a(st[phys(idx)]), .b(st[phys(3'd0)]), .y(divr_y));

    // Phase 5A dedicated datapath: ST0/ST1 division and remainder
    wire [63:0] st0_val = st[phys(3'd0)];
    wire [63:0] st1_val = st[phys(3'd1)];
    wire [63:0] prem_div_y;
    wire        prem_div_inexact;
    wire [63:0] prem_prod_y;
    wire        prem_prod_inexact;
    wire [63:0] prem_rem_y;
    wire        prem_rem_inexact;
    reg  [63:0] prem_qf;
    reg         prem_q_inexact;

    fp64_div u_prem_div(.a(st0_val), .b(st1_val), .y(prem_div_y), .inexact(prem_div_inexact));
    fp64_mul u_prem_mul(.a(prem_qf), .b(st1_val), .y(prem_prod_y), .inexact(prem_prod_inexact));
    fp64_add u_prem_sub(.a(st0_val), .b({~prem_prod_y[63], prem_prod_y[62:0]}), .y(prem_rem_y), .inexact(prem_rem_inexact));

    // Compute integer quotient (as float64) for FPREM/FPREM1
    always @(*) begin
        prem_qf = 64'd0;
        prem_q_inexact = 1'b0;
        // Default: trunc toward zero
        if (cmd == CMD_FPREM) begin
            if (idx == 3'd1) begin
                // FPREM1: nearest-even
                {prem_q_inexact, prem_qf} = round_int_f64(prem_div_y, 2'b00);
            end
            else begin
                // FPREM: trunc
                {prem_q_inexact, prem_qf} = round_int_f64(prem_div_y, 2'b11);
            end
        end
    end

    fp64_cmp u_cmp(.a(st[phys(3'd0)]), .b(st[phys(idx)]), .lt(cmp_lt), .eq(cmp_eq), .gt(cmp_gt));

    
    fp64_sqrt u_sqrt(.a(st[phys(3'd0)]), .y(sqrt_y), .invalid(sqrt_invalid), .inexact(sqrt_inexact));
fp64_add u_sub (.a(st[phys(3'd0)]), .b({~st[phys(idx)][63], st[phys(idx)][62:0]}), .y(sub_y));
    fp64_add u_subr(.a(st[phys(idx)]), .b({~st[phys(3'd0)][63], st[phys(3'd0)][62:0]}), .y(subr_y));

    // Store latch for 64-bit memory stores (two-step)
    reg [63:0] store_latch;
    reg        store_latch_valid;

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            fcw <= 16'h037F;
            fsw <= 16'h0000;
            ftw <= 16'hFFFF;
            top <= 3'd0;
            for (i=0; i<8; i=i+1) begin
                st[i] <= 64'd0;
            end
            store_latch <= 64'd0;
            store_latch_valid <= 1'b0;

            memstore_valid <= 1'b0;
            memstore_size  <= 2'd0;
            memstore_data64<= 64'd0;
            busy <= 1'b0;
            done <= 1'b0;
            wb_valid <= 1'b0;
            wb_kind  <= WB_NONE;
            wb_value <= 16'd0;
        end
        else begin
            // defaults
            done <= 1'b0;
            wb_valid <= 1'b0;
            wb_kind  <= WB_NONE;
            wb_value <= 16'd0;
            memstore_valid <= 1'b0;
            memstore_size  <= 2'd0;
            memstore_data64<= 64'd0;
            busy <= 1'b0;

            if (start && cmd_valid) begin
                busy <= 1'b1;

                case (cmd)
                    CMD_FNINIT: begin
                        fcw <= 16'h037F;
                        fsw <= 16'h0000;
                        ftw <= 16'hFFFF;
                        top <= 3'd0;
                        store_latch_valid <= 1'b0;
                    end

                    CMD_FWAIT: begin
                        // single-cycle model: already complete
                    end

                    CMD_FNSTSW_AX: begin
                        wb_valid <= 1'b1;
                        wb_kind  <= WB_AX;
                        wb_value <= fsw;
                    end

                    CMD_FLDCW: begin
                        fcw <= mem_rdata32[15:0];
                    end

                    CMD_FNSTCW: begin
                        memstore_valid <= 1'b1;
                        memstore_size  <= 2'd0; // handled by CPU as 16-bit via existing path
                        memstore_data64<= {48'd0, fcw};
                    end

                    // ----------------------
                    // Memory loads/stores
                    // ----------------------
                    CMD_FLD_M32: begin
                        // push converted float32
                        top <= top - 3'd1;
                        st[phys(3'd7)] <= f32_to_f64(mem_rdata32);
                        ftw[phys(3'd7)*2 +: 2] <= 2'b00;
                    end

                    CMD_FLD_M64: begin
                        // start is expected only when full 64-bit operand is available
                        top <= top - 3'd1;
                        st[phys(3'd7)] <= mem_rdata64;
                        ftw[phys(3'd7)*2 +: 2] <= 2'b00;
                    end

                    CMD_FSTP_M32: begin
                        memstore_valid <= 1'b1;
                        memstore_size  <= 2'd1;
                        memstore_data64<= {32'd0, f64_to_f32(st[phys(3'd0)])};
                        // pop
                        ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                        top <= top + 3'd1;
                    end

                    CMD_FSTP_M64: begin
                        // Two-step store using step[0].
                        // step[0]==0: latch ST0 and output lower dword; no pop.
                        // step[0]==1: output upper dword; pop.
                        if (step[0] == 1'b0) begin
                            store_latch <= st[phys(3'd0)];
                            store_latch_valid <= 1'b1;
                            memstore_valid <= 1'b1;
                            memstore_size  <= 2'd2;
                            memstore_data64<= st[phys(3'd0)];
                        end
                        else begin
                            memstore_valid <= store_latch_valid;
                            memstore_size  <= 2'd2;
                            memstore_data64<= store_latch;
                            // pop on second half
                            ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                            top <= top + 3'd1;
                            store_latch_valid <= 1'b0;
                        end
                    end

                    // ----------------------
                    // Stack/register ops
                    // ----------------------
                    CMD_FLD_STI: begin
                        top <= top - 3'd1;
                        st[phys(3'd7)] <= st[phys(idx)];
                        ftw[phys(3'd7)*2 +: 2] <= ftw[phys(idx)*2 +: 2];
                    end

                    CMD_FXCH_STI: begin
                        st[phys(3'd0)] <= st[phys(idx)];
                        st[phys(idx)]  <= st[phys(3'd0)];
                        // tags unchanged
                    end

                    CMD_FSTP_STI: begin
                        st[phys(idx)] <= st[phys(3'd0)];
                        ftw[phys(idx)*2 +: 2] <= ftw[phys(3'd0)*2 +: 2];
                        ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                        top <= top + 3'd1;
                    end

                    // ----------------------
                    // Arithmetic / compare
                    // ----------------------
                    CMD_FADD_STI: begin
                        st[phys(3'd0)] <= add_y;
                    end
                    CMD_FMUL_STI: begin
                        st[phys(3'd0)] <= mul_y;
                    end
                    CMD_FDIV_STI: begin
                        st[phys(3'd0)] <= div_y;
                    end
                    CMD_FDIVR_STI: begin
                        // ST0 = ST(i) / ST0
                        st[phys(3'd0)] <= divr_y;
                    end
                    
                    // ----------------------
                    // Phase 5A: FPREM/FPREM1 (ST0 = ST0 - Q*ST1)
                    // idx=0:FPREM (truncate), idx=1:FPREM1 (nearest-even)
                    // ----------------------
                    CMD_FPREM: begin
                        // basic stack-empty checks
                        if (ftw[phys(3'd0)*2 +: 2] == 2'b11 || ftw[phys(3'd1)*2 +: 2] == 2'b11) begin
                            fsw[0] <= 1'b1; // IE
                            fsw[10]<= 1'b1; // C2
                        end
                        else if (st1_val[62:0] == 63'd0) begin
                            // divide by zero -> Invalid (simplified)
                            fsw[0] <= 1'b1; // IE
                            fsw[10]<= 1'b1; // C2
                        end
                        else begin
                            st[phys(3'd0)] <= prem_rem_y;
                            // C2 = 0 (complete) for single-pass implementation
                            fsw[10] <= 1'b0;
                            // PE if any inexact occurred in quotient rounding or arithmetic
                            fsw[5]  <= prem_q_inexact | prem_div_inexact | prem_prod_inexact | prem_rem_inexact;
                        end
                    end

CMD_MISC: begin
    // Phase 4 misc ops selected by idx:
    // 0=FCHS, 1=FABS, 2=FTST, 3=FXAM, 4=FSQRT, 5=FRNDINT, 6=FSCALE
    // All operate on ST0 and do not change TOP (except none).
    if (ftw[phys(3'd0)*2 +: 2] == 2'b11) begin
        // Empty stack entry -> stack fault (simplified as Invalid)
        fsw[0] <= 1'b1; // IE
        fsw[8] <= 1'b1; // C0
        fsw[10]<= 1'b1; // C2
        fsw[14]<= 1'b1; // C3
    end
    else begin
        case(idx)
            3'd0: begin
                // FCHS: toggle sign
                st[phys(3'd0)] <= {~st[phys(3'd0)][63], st[phys(3'd0)][62:0]};
            end
            3'd1: begin
                // FABS: clear sign
                st[phys(3'd0)] <= {1'b0, st[phys(3'd0)][62:0]};
            end
            3'd2: begin
                // FTST: compare ST0 with +0.0, set C3/C2/C0
                // unordered if NaN
                reg [10:0] e;
                reg [51:0] f;
                reg        s;
                s = st[phys(3'd0)][63];
                e = st[phys(3'd0)][62:52];
                f = st[phys(3'd0)][51:0];
                if (e == 11'h7FF && f != 0) begin
                    // NaN -> unordered
                    fsw[0]  <= 1'b1; // IE
                    fsw[8]  <= 1'b1; // C0
                    fsw[10] <= 1'b1; // C2
                    fsw[14] <= 1'b1; // C3
                end
                else if (e == 0 && f == 0) begin
                    // zero
                    fsw[8]  <= 1'b0;
                    fsw[10] <= 1'b0;
                    fsw[14] <= 1'b1;
                end
                else if (s) begin
                    // negative
                    fsw[8]  <= 1'b1;
                    fsw[10] <= 1'b0;
                    fsw[14] <= 1'b0;
                end
                else begin
                    // positive
                    fsw[8]  <= 1'b0;
                    fsw[10] <= 1'b0;
                    fsw[14] <= 1'b0;
                end
            end
            3'd3: begin
                // FXAM: examine ST0 and set condition codes, C1=sign
                reg [10:0] e;
                reg [51:0] f;
                reg        s;
                s = st[phys(3'd0)][63];
                e = st[phys(3'd0)][62:52];
                f = st[phys(3'd0)][51:0];
                fsw[9] <= s; // C1 = sign
                if (e == 11'h7FF && f != 0) begin
                    // NaN: C3,C2,C0 = 1,1,1
                    fsw[14] <= 1'b1;
                    fsw[10] <= 1'b1;
                    fsw[8]  <= 1'b1;
                end
                else if (e == 11'h7FF) begin
                    // Infinity: 0,1,1
                    fsw[14] <= 1'b0;
                    fsw[10] <= 1'b1;
                    fsw[8]  <= 1'b1;
                end
                else if (e == 0 && f == 0) begin
                    // Zero: 1,0,0
                    fsw[14] <= 1'b1;
                    fsw[10] <= 1'b0;
                    fsw[8]  <= 1'b0;
                end
                else if (e == 0) begin
                    // Denormal: 1,1,0
                    fsw[14] <= 1'b1;
                    fsw[10] <= 1'b1;
                    fsw[8]  <= 1'b0;
                end
                else begin
                    // Normal finite: 0,1,0
                    fsw[14] <= 1'b0;
                    fsw[10] <= 1'b1;
                    fsw[8]  <= 1'b0;
                end
            end
            3'd4: begin
                // FSQRT: ST0 = sqrt(ST0)
                // For negative (excluding -0) -> Invalid, return qNaN
                reg [10:0] e;
                reg [51:0] f;
                reg        s;
                s = st[phys(3'd0)][63];
                e = st[phys(3'd0)][62:52];
                f = st[phys(3'd0)][51:0];
                if (e == 11'h7FF && f != 0) begin
                    // NaN propagates
                    st[phys(3'd0)] <= st[phys(3'd0)];
                end
                else if (s && !(e==0 && f==0)) begin
                    // negative non-zero
                    fsw[0] <= 1'b1; // IE
                    st[phys(3'd0)] <= 64'h7FF8_0000_0000_0000; // qNaN
                end
                else begin
                    st[phys(3'd0)] <= sqrt_y;
                    if (sqrt_invalid) fsw[0] <= 1'b1;
                    if (sqrt_inexact) fsw[5] <= 1'b1; // PE (bit 5)
                end
            end
            3'd6: begin
                // FSCALE: ST0 = ST0 * 2^(trunc(ST1))
                // Simplified: adjust exponent for normal numbers; preserve sign/mantissa.
                if (ftw[phys(3'd1)*2 +: 2] == 2'b11) begin
                    fsw[0] <= 1'b1; // IE
                    fsw[10]<= 1'b1; // C2
                end
                else begin
                    integer k;
                    reg s0;
                    reg [10:0] e0;
                    reg [51:0] m0;
                    reg signed [12:0] e_new;
                    k  = f64_to_s32_trunc(st1_val);
                    s0 = st0_val[63];
                    e0 = st0_val[62:52];
                    m0 = st0_val[51:0];
                    if (e0 == 11'h000) begin
                        // zero/denorm: leave as-is
                        st[phys(3'd0)] <= st0_val;
                    end
                    else if (e0 == 11'h7FF) begin
                        // NaN/Inf propagate
                        st[phys(3'd0)] <= st0_val;
                    end
                    else begin
                        e_new = $signed({1'b0,e0}) + $signed(k);
                        if (e_new >= 13'sd2047) begin
                            // overflow -> Inf (simplified)
                            st[phys(3'd0)] <= {s0, 11'h7FF, 52'd0};
                            fsw[2] <= 1'b1; // OE (approx)
                        end
                        else if (e_new <= 13'sd0) begin
                            // underflow -> 0 (simplified)
                            st[phys(3'd0)] <= {s0, 63'd0};
                            fsw[4] <= 1'b1; // UE (approx)
                        end
                        else begin
                            st[phys(3'd0)] <= {s0, e_new[10:0], m0};
                        end
                    end
                end
            end

            default: begin
                // FRNDINT: round to integral value in ST0 using FCW.RC (simplified)
                reg [63:0] x;
                reg        s;
                reg [10:0] e;
                reg [51:0] f;
                integer    exp_unb;
                reg [52:0] mant;
                reg [52:0] mant_int;
                reg [51:0] frac_mask;
                reg        inexact;
                x = st[phys(3'd0)];
                s = x[63];
                e = x[62:52];
                f = x[51:0];
                if (e == 11'h7FF) begin
                    // NaN/Inf unchanged
                    st[phys(3'd0)] <= x;
                end
                else if (e == 0 && f == 0) begin
                    st[phys(3'd0)] <= x;
                end
                else begin
                    exp_unb = $signed({1'b0,e}) - 1023;
                    if (exp_unb >= 52) begin
                        st[phys(3'd0)] <= x; // already integral
                    end
                    else if (exp_unb < 0) begin
                        // |x| < 1.0 -> result is 0, +1, -1 depending on RC and sign
                        inexact = 1'b1;
                        case(fcw[11:10])
                            2'b01: st[phys(3'd0)] <= s ? 64'hBFF0_0000_0000_0000 : 64'h8000_0000_0000_0000; // -inf
                            2'b10: st[phys(3'd0)] <= s ? 64'h8000_0000_0000_0000 : 64'h3FF0_0000_0000_0000; // +inf
                            2'b11: st[phys(3'd0)] <= {s, 63'd0}; // trunc -> signed zero
                            default: begin
                                // nearest: |x| >= 0.5 -> 1 else 0
                                if (e == 1022) st[phys(3'd0)] <= {s, 11'd1023, 52'd0};
                                else           st[phys(3'd0)] <= {s, 63'd0};
                            end
                        endcase
                        fsw[5] <= 1'b1; // PE
                    end
                    else begin
                        mant = {1'b1,f}; // 53
                        // mask of fractional bits
                        frac_mask = (52-exp_unb >= 52) ? 52'hFFFF_FFFF_FFFF_F : ((52'h1 << (52-exp_unb)) - 1);
                        inexact = (f & frac_mask) != 0;
                        mant_int = mant & ~({1'b0,frac_mask});
                        // rounding increment based on RC
                        if (inexact) begin
                            case(fcw[11:10])
                                2'b11: ; // trunc
                                2'b10: if (!s) mant_int = mant_int + (53'd1 << (52-exp_unb));
                                2'b01: if (s)  mant_int = mant_int + (53'd1 << (52-exp_unb));
                                default: begin
                                    // nearest-even: look at first dropped bit
                                    if ( (mant >> (52-exp_unb-1)) & 1 ) begin
                                        mant_int = mant_int + (53'd1 << (52-exp_unb));
                                    end
                                end
                            endcase
                            fsw[5] <= 1'b1; // PE
                        end
                        // renormalize if carry
                        if (mant_int[52] == 1'b0) begin
                            // should not happen
                            st[phys(3'd0)] <= {s,11'd0,52'd0};
                        end
                        else begin
                            st[phys(3'd0)] <= {s, e, mant_int[51:0]};
                        end
                    end
                end
            end
        endcase
    end
end

CMD_FSUB_STI: begin
                        st[phys(3'd0)] <= sub_y;
                    end
                    CMD_FSUBR_STI: begin
                        st[phys(3'd0)] <= subr_y;
                    end
                    CMD_FCOM_STI: begin
                        // C0=bit8, C2=bit10, C3=bit14
                        fsw[8]  <= cmp_lt;
                        fsw[10] <= 1'b0;
                        fsw[14] <= cmp_eq;
                    end
                    CMD_FCOMPP: begin
                        // Compare ST0 with ST1 (decode sets idx=1), then pop twice.
                        fsw[8]  <= cmp_lt;
                        fsw[10] <= 1'b0;
                        fsw[14] <= cmp_eq;
                        ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                        ftw[phys(3'd1)*2 +: 2] <= 2'b11;
                        top <= top + 3'd2;
                    end
                    CMD_FCOMP_STI: begin
                        fsw[8]  <= cmp_lt;
                        fsw[10] <= 1'b0;
                        fsw[14] <= cmp_eq;
                        ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                        top <= top + 3'd1;
                    end
                    CMD_FADDP_STI: begin
                        // ST(i) = ST(i) + ST0; pop
                        st[phys(idx)] <= add_y;
                        ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                        top <= top + 3'd1;
                    end
                    CMD_FMULP_STI: begin
                        st[phys(idx)] <= mul_y;
                        ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                        top <= top + 3'd1;
                    end
                    CMD_FSUBRP_STI: begin
                        // ST(i) = ST0 - ST(i); pop
                        st[phys(idx)] <= sub_y;
                        ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                        top <= top + 3'd1;
                    end
                    CMD_FSUBP_STI: begin
                        // ST(i) = ST(i) - ST0; pop
                        st[phys(idx)] <= subr_y;
                        ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                        top <= top + 3'd1;
                    end
                    CMD_FDIVRP_STI: begin
                        // ST(i) = ST0 / ST(i); pop
                        st[phys(idx)] <= div_y;
                        ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                        top <= top + 3'd1;
                    end
                    CMD_FDIVP_STI: begin
                        // ST(i) = ST(i) / ST0; pop
                        st[phys(idx)] <= divr_y;
                        ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                        top <= top + 3'd1;
                    end

                    default: begin
                        // Unsupported x87 in this phase: treat as NOP.
                    end
                endcase

                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end
endmodule