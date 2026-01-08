
module x87_decode (
    input  wire [7:0] op1,
    input  wire [7:0] op2,
    input  wire       op2_valid,
    output reg  [4:0] cmd,
    output reg        cmd_valid,
    output reg  [2:0] idx
);
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


    // Stack/register ops
    localparam CMD_FLD_STI    = 5'd10;
    localparam CMD_FXCH_STI   = 5'd11;
    localparam CMD_FSTP_STI   = 5'd12;

    // Core arithmetic / compare (register forms)
    localparam CMD_FADD_STI   = 5'd20;
    localparam CMD_FMUL_STI   = 5'd21;
    localparam CMD_FDIV_STI   = 5'd22;
    localparam CMD_FCOM_STI   = 5'd23;

    // Phase 2C.2 additions
    localparam CMD_FSUB_STI   = 5'd24;
    localparam CMD_FSUBR_STI  = 5'd25;
    localparam CMD_FCOMP_STI  = 5'd26;

    localparam CMD_FADDP_STI  = 5'd27;
    localparam CMD_FMULP_STI  = 5'd28;
    localparam CMD_FDIVP_STI  = 5'd29;

    localparam CMD_OTHER_X87  = 5'd31;

    always @(*) begin
        cmd       = CMD_NOP;
        cmd_valid = 1'b0;
        idx       = 3'd0;

        // FWAIT (9B) is standalone
        if (op1 == 8'h9B) begin
            cmd       = CMD_FWAIT;
            cmd_valid = 1'b1;
        end
        else if (op1 >= 8'hD8 && op1 <= 8'hDF) begin
            cmd_valid = 1'b1;

            // FNSTSW AX: DF E0
            if (op1 == 8'hDF && op2_valid && op2 == 8'hE0) begin
                cmd = CMD_FNSTSW_AX;
            end
            // FNINIT: DB E3
            else if (op1 == 8'hDB && op2_valid && op2 == 8'hE3) begin
                cmd = CMD_FNINIT;
            end
            // FLDCW m16: D9 /5
            else if (op1 == 8'hD9 && op2_valid && op2[5:3] == 3'b101) begin
                cmd = CMD_FLDCW;
            end
            // FNSTCW m16: D9 /7
            else if (op1 == 8'hD9 && op2_valid && op2[5:3] == 3'b111) begin
                cmd = CMD_FNSTCW;
            end
// FLD m32real: D9 /0 (memory form: mod != 11)
else if (op1 == 8'hD9 && op2_valid && op2[7:6] != 2'b11 && op2[5:3] == 3'b000) begin
    cmd = CMD_FLD_M32;
end
// FLD m64real: DD /0
else if (op1 == 8'hDD && op2_valid && op2[7:6] != 2'b11 && op2[5:3] == 3'b000) begin
    cmd = CMD_FLD_M64;
end
// FSTP m32real: D9 /3
else if (op1 == 8'hD9 && op2_valid && op2[7:6] != 2'b11 && op2[5:3] == 3'b011) begin
    cmd = CMD_FSTP_M32;
end
// FSTP m64real: DD /3
else if (op1 == 8'hDD && op2_valid && op2[7:6] != 2'b11 && op2[5:3] == 3'b011) begin
    cmd = CMD_FSTP_M64;
end

            // Register-form opcodes
            else if (op2_valid) begin
                idx = op2[2:0];

                // FLD ST(i): D9 C0+i
                if (op1 == 8'hD9 && op2[7:3] == 5'b11000) begin
                    cmd = CMD_FLD_STI;
                end
                // FXCH ST(i): D9 C8+i
                else if (op1 == 8'hD9 && op2[7:3] == 5'b11001) begin
                    cmd = CMD_FXCH_STI;
                end
                // FSTP ST(i): DD D8+i
                else if (op1 == 8'hDD && op2[7:3] == 5'b11011) begin
                    cmd = CMD_FSTP_STI;
                end

                // FADD ST0, ST(i): D8 C0+i
                else if (op1 == 8'hD8 && op2[7:3] == 5'b11000) begin
                    cmd = CMD_FADD_STI;
                end
                // FMUL ST0, ST(i): D8 C8+i
                else if (op1 == 8'hD8 && op2[7:3] == 5'b11001) begin
                    cmd = CMD_FMUL_STI;
                end
                // FCOM ST(i): D8 D0+i
                else if (op1 == 8'hD8 && op2[7:3] == 5'b11010) begin
                    cmd = CMD_FCOM_STI;
                end
                // FCOMP ST(i): D8 D8+i
                else if (op1 == 8'hD8 && op2[7:3] == 5'b11011) begin
                    cmd = CMD_FCOMP_STI;
                end
                // FSUB ST0, ST(i): D8 E0+i
                else if (op1 == 8'hD8 && op2[7:3] == 5'b11100) begin
                    cmd = CMD_FSUB_STI;
                end
                // FSUBR ST0, ST(i): D8 E8+i
                else if (op1 == 8'hD8 && op2[7:3] == 5'b11101) begin
                    cmd = CMD_FSUBR_STI;
                end
                // FDIV ST0, ST(i): D8 F0+i
                else if (op1 == 8'hD8 && op2[7:3] == 5'b11110) begin
                    cmd = CMD_FDIV_STI;
                end

                // Pop variants live on DE
                else if (op1 == 8'hDE && op2[7:3] == 5'b11000) begin
                    cmd = CMD_FADDP_STI;
                end
                else if (op1 == 8'hDE && op2[7:3] == 5'b11001) begin
                    cmd = CMD_FMULP_STI;
                end
                else if (op1 == 8'hDE && op2[7:3] == 5'b11111) begin
                    cmd = CMD_FDIVP_STI;
                end
                else begin
                    cmd = CMD_OTHER_X87;
                end
            end
            else begin
                cmd = CMD_OTHER_X87;
            end
        end
    end
endmodule
