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
    localparam CMD_FCOMPP     = 5'd16;

    /* Packed BCD group (DF /4 and DF /6) */
    localparam CMD_BCD_MEM    = 5'd19;
    localparam IDX_BCD_FBLD   = 3'd0;
    localparam IDX_BCD_FBSTP  = 3'd1;

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

    // Unsigned 64-bit integer -> float64 (exact for all integers <= 2^53)
    function [63:0] u64_to_fp64;
        input [63:0] v;
        integer i;
        integer msb;
        reg [10:0] e;
        reg [52:0] m;
        begin : u64_to_fp64_f
            if (v == 64'd0) begin
                u64_to_fp64 = 64'd0;
                    end
                    else begin
                msb = 0;
                begin : msb_find
                    for (i = 63; i >= 0; i = i - 1) begin
                        if (v[i]) begin
                            msb = i;
                            disable msb_find;
                end
                end
            end

                e = 11'd1023 + msb[10:0];
                if (msb > 52) begin
                    m = v >> (msb - 52);
                        end
                        else begin
                    m = v << (52 - msb);
                    end
                u64_to_fp64 = {1'b0, e, m[51:0]};
                    end
        end
    endfunction

    // Packed BCD (10 bytes) -> float64
    function [63:0] bcd80_to_fp64;
        input [79:0] b;
        integer i;
        reg sign;
        reg [63:0] val;
        reg [63:0] p10;
        reg [3:0] digit;
        begin
            sign    = b[79];
            val  = 64'd0;
            p10  = 64'd1;
            for (i = 0; i < 18; i = i + 1) begin
                digit = (b >> (i*4)) & 4'hF;
                if (digit > 4'd9) digit = 4'd0;
                val = val + (p10 * digit);
                p10 = p10 * 64'd10;
            end
            bcd80_to_fp64 = u64_to_fp64(val);
            bcd80_to_fp64[63] = sign;
        end
    endfunction

    // float64 -> packed BCD (10 bytes). Truncates toward zero.
    function [81:0] fp64_to_bcd80_ext;
        input [63:0] d;
        input [1:0]  rc;
        integer i;
        reg sign;
        reg [10:0] e;
        integer expi;
        reg [52:0] m;
        reg [63:0] int_val;
        reg [63:0] tmp;
        reg [3:0] digit;
        reg [79:0] b;
        reg invalid;
        reg inexact;
        reg inc;
        integer shift;
        reg [63:0] rem;
        reg [63:0] half;
        begin
            sign = d[63];
            e    = d[62:52];

            invalid  = 1'b0;
            inexact  = 1'b0;
            inc      = 1'b0;
            int_val  = 64'd0;
            rem      = 64'd0;
            shift    = 0;
            half     = 64'd0;

            /* Handle NaN/Inf as invalid for FBSTP conversion. */
            if (e == 11'h7FF) begin
                invalid = 1'b1;
            end
            else if (e == 11'd0) begin
                /* Treat denorm/zero as 0; keep sign for -0. */
                int_val = 64'd0;
                rem     = (d[51:0] != 52'd0) ? 64'd1 : 64'd0;
            end
            else begin
                expi = e - 11'd1023;
                m    = {1'b1, d[51:0]}; /* 53-bit significand */

                if (expi < 0) begin
                    /* |d| < 1.0 -> integer part is 0, remainder exists if mantissa non-zero. */
                    int_val = 64'd0;
                    rem     = 64'd1;
                end
                else if (expi > 63) begin
                    /* Too large for 64-bit integer staging -> invalid (will become BCD indefinite). */
                    invalid = 1'b1;
                end
                else begin
                if (expi >= 52) begin
                        shift   = expi - 52;
                        int_val = (shift >= 12'd64) ? 64'd0 : (m << shift);
                        rem     = 64'd0;
        end
                    else begin
                        shift   = 52 - expi;
                        int_val = m >> shift;

                        /* Capture remainder bits for rounding/inexact. */
                        if (shift >= 12'd64) begin
                            rem = 64'd1;
            end
            else begin
                            rem = m & ((64'd1 << shift) - 64'd1);
                        end
                    end
                    end
                    end

            /* Range check for 18 digits (|value| >= 1e18 is invalid for FBSTP). */
            if (!invalid) begin
                if (int_val >= 64'd1000000000000000000) begin
                    invalid = 1'b1;
                end
            end

            /* Rounding decision (only if not invalid). */
            if (!invalid) begin
                if (rem != 64'd0) begin
                    inexact = 1'b1;
                end

                inc = 1'b0;
                case (rc)
                    2'b00: begin
                        /* Round to nearest even */
                        if (shift > 0) begin
                            half = (64'd1 << (shift-1));
                            if (rem > half) inc = 1'b1;
                            else if (rem == half) begin
                                if ((int_val[0] == 1'b1) || ((rem & (half-1)) != 0)) inc = 1'b1;
                            end
                        end
                    end
                    2'b11: begin
                        /* Round toward zero: no increment */
                        inc = 1'b0;
                    end
                    2'b10: begin
                        /* Round toward +inf */
                        if (!sign && (rem != 0)) inc = 1'b1;
                    end
                    2'b01: begin
                        /* Round toward -inf */
                        if (sign && (rem != 0)) inc = 1'b1;
                    end
                endcase

                if (inc) begin
                    int_val = int_val + 64'd1;
                    /* If rounding pushes to 1e18, it becomes invalid for FBSTP. */
                    if (int_val >= 64'd1000000000000000000) begin
                        invalid = 1'b1;
                    end
                end
            end

            /* If invalid, return packed BCD indefinite. Otherwise pack digits. */
            if (invalid) begin
                b = 80'hFFFFC000000000000000;
                end
                else begin
                tmp = int_val;
            b = 80'd0;
            for (i = 0; i < 18; i = i + 1) begin
                digit = tmp % 10;
                tmp   = tmp / 10;
                b = b | ({76'd0, digit} << (i*4));
                                end
                /* Sign bit is bit79; other sign-byte bits are 0. */
                    b[79] = sign;
            end

            fp64_to_bcd80_ext = {invalid, inexact, b};
        end
    endfunction
    // FP cores (combinational)
    wire [63:0] add_y, mul_y, div_y, divr_y;
    wire [63:0] sub_y, subr_y;
    wire cmp_lt, cmp_eq, cmp_gt;

fp64_add u_add(.a(st[phys(3'd0)]), .b(st[phys(idx)]), .y(add_y));
    fp64_mul u_mul(.a(st[phys(3'd0)]), .b(st[phys(idx)]), .y(mul_y));
    fp64_div u_div(.a(st[phys(3'd0)]), .b(st[phys(idx)]), .y(div_y));
    // Swapped-operand divide for FDIVR and FDIVP-style encodings
    fp64_div u_divr(.a(st[phys(idx)]), .b(st[phys(3'd0)]), .y(divr_y));
    fp64_cmp u_cmp(.a(st[phys(3'd0)]), .b(st[phys(idx)]), .lt(cmp_lt), .eq(cmp_eq), .gt(cmp_gt));

fp64_add u_sub (.a(st[phys(3'd0)]), .b({~st[phys(idx)][63], st[phys(idx)][62:0]}), .y(sub_y));
    fp64_add u_subr(.a(st[phys(idx)]), .b({~st[phys(3'd0)][63], st[phys(3'd0)][62:0]}), .y(subr_y));

    // Store latch for 64-bit memory stores (two-step)
    reg [63:0] store_latch;
    reg        store_latch_valid;

    // Packed BCD (80-bit) latches for FBLD/FBSTP (two-step)
    reg [63:0] bcd_latch_lo64;
    wire [81:0] fb_conv_w = fp64_to_bcd80_ext(st[phys(3'd0)], fcw[11:10]);
    wire        fb_invalid_w = fb_conv_w[81];
    wire        fb_inexact_w = fb_conv_w[80];
    wire [79:0] fb_bcd80_w   = fb_conv_w[79:0];
    reg [15:0] bcd_latch_hi16;
    reg        bcd_latch_valid;

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

            bcd_latch_lo64 <= 64'd0;
            bcd_latch_hi16 <= 16'd0;
            bcd_latch_valid <= 1'b0;

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
                        bcd_latch_valid <= 1'b0;
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

                    // ----------------------
                    // Packed BCD memory ops (two-step)
                    // ----------------------
                    CMD_BCD_MEM: begin
                        if (idx == IDX_BCD_FBLD) begin
                            // FBLD m80bcd
                            if (step[0] == 1'b0) begin
                                bcd_latch_lo64 <= mem_rdata64;
                                bcd_latch_valid <= 1'b1;
                            end
                            else begin
                                bcd_latch_hi16 <= mem_rdata32[15:0];
                                // Push result
                                top <= top - 3'd1;
                                st[phys(3'd7)] <= bcd80_to_fp64({mem_rdata32[15:0], bcd_latch_lo64});
                                ftw[phys(3'd7)*2 +: 2] <= 2'b00;
                                bcd_latch_valid <= 1'b0;
                            end
                        end
                        else if (idx == IDX_BCD_FBSTP) begin
                            // FBSTP m80bcd
                            if (step[0] == 1'b0) begin
                                // Compute BCD once and latch.
                                {bcd_latch_hi16, bcd_latch_lo64} <= {fb_bcd80_w[79:64], fb_bcd80_w[63:0]};
                                bcd_latch_valid <= 1'b1;

                                memstore_valid <= 1'b1;
                                memstore_size  <= 2'd2; // 64-bit
                memstore_data64 <= fb_bcd80_w[63:0];
                                fsw[0] <= fsw[0] | fb_invalid_w;
                                fsw[5] <= fsw[5] | fb_inexact_w;
                            end
                            else begin
                                memstore_valid <= 1'b1;
                                memstore_size  <= 2'd0; // 16-bit
                                memstore_data64 <= {48'd0, bcd_latch_hi16};

                                // Pop after completing the store.
                                ftw[phys(3'd0)*2 +: 2] <= 2'b11;
                                top <= top + 3'd1;
                                bcd_latch_valid <= 1'b0;
                            end
                        end
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
