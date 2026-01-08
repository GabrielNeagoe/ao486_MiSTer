module x87_exec (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [4:0]  cmd,
    input  wire        cmd_valid,
    input  wire [2:0]  idx,

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

    // Existing register ops retained (Phase 2C.2)
    localparam CMD_FADD_STI   = 5'd10;
    localparam CMD_FMUL_STI   = 5'd11;
    localparam CMD_FDIV_STI   = 5'd12;
    localparam CMD_FADDP_STI  = 5'd20;
    localparam CMD_FMULP_STI  = 5'd21;
    localparam CMD_FDIVP_STI  = 5'd22;
    localparam CMD_FSUB_STI   = 5'd23;
    localparam CMD_FSUBR_STI  = 5'd24;
    localparam CMD_FSUBP_STI  = 5'd25;
    localparam CMD_FSUBRP_STI = 5'd26;
    localparam CMD_FCOM_STI   = 5'd27;
    localparam CMD_FCOMP_STI  = 5'd28;
    localparam CMD_FXCH_STI   = 5'd29;
    localparam CMD_FPOP       = 5'd31;

    // State regs
    reg [15:0] fcw;
    reg [15:0] fsw;
    reg [2:0]  top;

    // Stack
    reg soft_reset;
    reg do_push, do_pop, do_fxch, do_write;
    reg [2:0] read_idx, write_idx, fxch_idx;
    reg [63:0] push_value, write_value;
    wire [63:0] st0_value, sti_value;
    wire [2:0]  stack_top;
    wire [15:0] stack_tags;

    x87_stack u_stack(
        .clk(clk), .rst(rst), .soft_reset(soft_reset),
        .do_push(do_push), .do_pop(do_pop), .do_fxch(do_fxch), .do_write(do_write),
        .read_idx(read_idx), .write_idx(write_idx), .fxch_idx(fxch_idx),
        .push_value(push_value), .write_value(write_value),
        .st0_value(st0_value), .sti_value(sti_value),
        .top(stack_top), .tag_word(stack_tags)
    );

    // Basic conversions
    function [63:0] f32_to_f64;
        input [31:0] a;
        reg sign;
        reg [7:0] exp;
        reg [22:0] frac;
        reg [10:0] exp64;
        reg [51:0] frac64;
        begin
            sign = a[31];
            exp  = a[30:23];
            frac = a[22:0];
            if (exp == 8'd0) begin
                f32_to_f64 = {sign, 11'd0, 52'd0};
            end else begin
                exp64  = {3'd0, exp} - 11'd127 + 11'd1023;
                frac64 = {frac, 29'd0};
                f32_to_f64 = {sign, exp64, frac64};
            end
        end
    endfunction

    function [31:0] f64_to_f32;
        input [63:0] a;
        reg sign;
        reg [10:0] exp;
        reg [51:0] frac;
        reg [7:0] exp32;
        reg [22:0] frac32;
        reg signed [11:0] e_unbias;
        begin
            sign = a[63];
            exp  = a[62:52];
            frac = a[51:0];
            if (exp == 11'd0) begin
                f64_to_f32 = {sign, 8'd0, 23'd0};
            end else begin
                e_unbias = $signed({1'b0,exp}) - 12'd1023 + 12'd127;
                if (e_unbias <= 0) begin
                    exp32 = 8'd0;
                    frac32 = 23'd0;
                end else if (e_unbias >= 255) begin
                    exp32 = 8'hFF;
                    frac32 = 23'd0;
                end else begin
                    exp32 = e_unbias[7:0];
                    frac32 = frac[51:29];
                end
                f64_to_f32 = {sign, exp32, frac32};
            end
        end
    endfunction

    // FP64 cores (combinational, synthesizable)
    wire [63:0] add_out, mul_out, div_out;
    wire [63:0] sub_out;
    wire [63:0] subr_out;
    wire cmp_lt, cmp_eq, cmp_gt;

    fp64_add u_add(.a(st0_value), .b(sti_value), .y(add_out));
    fp64_mul u_mul(.a(st0_value), .b(sti_value), .y(mul_out));
    fp64_div u_div(.a(st0_value), .b(sti_value), .y(div_out));
    fp64_add u_sub(.a(st0_value), .b({~sti_value[63], sti_value[62:0]}), .y(sub_out));
    fp64_add u_subr(.a(sti_value), .b({~st0_value[63], st0_value[62:0]}), .y(subr_out));
    fp64_cmp u_cmp(.a(st0_value), .b(sti_value), .lt(cmp_lt), .eq(cmp_eq), .gt(cmp_gt));

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;

            wb_valid <= 1'b0;
            wb_kind  <= 3'd0;
            wb_value <= 16'd0;

            memstore_valid <= 1'b0;
            memstore_size  <= 2'd0;
            memstore_data64<= 64'd0;

            fcw <= 16'h037F;
            fsw <= 16'h0000;
            top <= 3'd0;

            soft_reset <= 1'b1;
        end else begin
            done <= 1'b0;
            wb_valid <= 1'b0;
            memstore_valid <= 1'b0;
            soft_reset <= 1'b0;

            do_push <= 1'b0;
            do_pop  <= 1'b0;
            do_fxch <= 1'b0;
            do_write<= 1'b0;

            read_idx  <= idx;
            write_idx <= idx;
            fxch_idx  <= idx;

            push_value <= 64'd0;
            write_value<= 64'd0;

            top <= stack_top;

            if (start && cmd_valid && !busy) begin
                busy <= 1'b1;

                case (cmd)
                    CMD_FNINIT: begin
                        fcw <= 16'h037F;
                        fsw <= 16'h0000;
                        soft_reset <= 1'b1;
                    end

                    CMD_FNSTSW_AX: begin
                        wb_valid <= 1'b1;
                        wb_kind  <= 3'd1; // AX
                        wb_value <= {fsw[15:14], top, fsw[10:0]};
                    end

                    CMD_FLDCW: begin
                        fcw <= mem_rdata32[15:0];
                    end

                    CMD_FNSTCW: begin
                        memstore_valid <= 1'b1;
                        memstore_size  <= 2'd0; // 16-bit
                        memstore_data64<= {48'd0, fcw};
                    end

                    CMD_FLD_M32: begin
                        do_push <= 1'b1;
                        push_value <= f32_to_f64(mem_rdata32);
                    end

                    CMD_FLD_M64: begin
                        do_push <= 1'b1;
                        push_value <= mem_rdata64;
                    end

                    CMD_FSTP_M32: begin
                        memstore_valid <= 1'b1;
                        memstore_size  <= 2'd1;
                        memstore_data64<= {32'd0, f64_to_f32(st0_value)};
                        do_pop <= 1'b1;
                    end

                    CMD_FSTP_M64: begin
                        memstore_valid <= 1'b1;
                        memstore_size  <= 2'd2;
                        memstore_data64<= st0_value;
                        do_pop <= 1'b1;
                    end

                    // Register arithmetic (Phase 2C.2)
                    CMD_FADD_STI: begin
                        do_write <= 1'b1;
                        write_idx <= 3'd0;
                        write_value <= add_out;
                    end
                    CMD_FMUL_STI: begin
                        do_write <= 1'b1;
                        write_idx <= 3'd0;
                        write_value <= mul_out;
                    end
                    CMD_FDIV_STI: begin
                        do_write <= 1'b1;
                        write_idx <= 3'd0;
                        write_value <= div_out;
                    end
                    CMD_FSUB_STI: begin
                        do_write <= 1'b1;
                        write_idx <= 3'd0;
                        write_value <= sub_out;
                    end
                    CMD_FSUBR_STI: begin
                        do_write <= 1'b1;
                        write_idx <= 3'd0;
                        write_value <= subr_out;
                    end
                    CMD_FXCH_STI: begin
                        do_fxch <= 1'b1;
                        fxch_idx <= idx;
                    end
                    CMD_FPOP: begin
                        do_pop <= 1'b1;
                    end
                    CMD_FCOM_STI: begin
                        fsw[10:8] <= {1'b0, 1'b0, cmp_lt};
                        fsw[14]   <= cmp_eq;
                    end
                    CMD_FCOMP_STI: begin
                        fsw[10:8] <= {1'b0, 1'b0, cmp_lt};
                        fsw[14]   <= cmp_eq;
                        do_pop <= 1'b1;
                    end
                    CMD_FADDP_STI: begin
                        do_write <= 1'b1;
                        write_idx <= idx;
                        write_value <= add_out;
                        do_pop <= 1'b1;
                    end
                    CMD_FMULP_STI: begin
                        do_write <= 1'b1;
                        write_idx <= idx;
                        write_value <= mul_out;
                        do_pop <= 1'b1;
                    end
                    CMD_FDIVP_STI: begin
                        do_write <= 1'b1;
                        write_idx <= idx;
                        write_value <= div_out;
                        do_pop <= 1'b1;
                    end
                    CMD_FSUBP_STI: begin
                        do_write <= 1'b1;
                        write_idx <= idx;
                        write_value <= sub_out;
                        do_pop <= 1'b1;
                    end
                    CMD_FSUBRP_STI: begin
                        do_write <= 1'b1;
                        write_idx <= idx;
                        write_value <= subr_out;
                        do_pop <= 1'b1;
                    end

                    default: begin end
                endcase

                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end
endmodule
