// -----------------------------------------------------------------------------
// x87_decode.v - ao486 x87 opcode decoder (Phase 0..3)
// Decodes primary opcode byte (op1) and optional second byte (op2 = ModR/M or
// escape byte) into an internal command + index.
//
// Notes:
// - For memory forms using ModR/M, op2 is the ModR/M byte.
// - For integer conversion memory forms (Phase 3):
//     DF /0  = FILD m16int
//     DB /0  = FILD m32int
//     DF /2  = FIST m16int
//     DB /2  = FIST m32int
//     DF /3  = FISTP m16int
//     DB /3  = FISTP m32int
//   We encode operand size via idx[0] (0=16-bit, 1=32-bit).
// -----------------------------------------------------------------------------
module x87_decode(
    input  wire [7:0] op1,
    input  wire [7:0] op2,
    input  wire       op2_valid,
    output reg  [4:0]   cmd,
    output reg        cmd_valid,
    output reg  [2:0] idx
);

    // Command encoding must match x87_exec.v
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

    localparam CMD_FSUBP_STI  = 5'd13;
    localparam CMD_FSUBRP_STI = 5'd14;
    localparam CMD_FDIVRP_STI = 5'd15;

    // Phase 3 integer conversions (encoded via idx[0] size)
    localparam CMD_FILD_MEM   = 5'd16;
    localparam CMD_FIST_MEM   = 5'd17;
    localparam CMD_FISTP_MEM  = 5'd18;

    /* Packed BCD group (DF /4 and DF /6). Implemented as a single command with idx sub-ops. */
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

        localparam CMD_MISC      = 5'd31;  // Phase 4 misc ops via idx

wire [1:0] modrm_mod = op2[7:6];
    wire [2:0] modrm_reg = op2[5:3];
    wire [2:0] modrm_rm  = op2[2:0];

    always @* begin
        cmd       = CMD_NOP;
        cmd_valid = 1'b0;
        idx       = 3'd0;

        // Require op2 for most x87 forms except implicit 2-byte forms
        // (FNSTSW AX, FNINIT, FWAIT).
        if (op1 == 8'h9B) begin
            cmd       = CMD_FWAIT;
            cmd_valid = 1'b1;
        end
        else if (op1 == 8'hDF && op2_valid && op2 == 8'hE0) begin
            cmd       = CMD_FNSTSW_AX;
            cmd_valid = 1'b1;
        end
        else if ((op1 == 8'hDB || op1 == 8'hD9) && op2_valid && op2 == 8'hE3) begin
            // Some software uses D9 E3 (FNINIT), official is DB E3.
            cmd       = CMD_FNINIT;
            cmd_valid = 1'b1;
        end
        else if (op2_valid) begin
            // Integer conversions (Phase 3) - memory only
            // Use idx[0] = 0 for 16-bit (DF), 1 for 32-bit (DB)
            if ((op1 == 8'hDF || op1 == 8'hDB) && modrm_mod != 2'b11) begin
                if (modrm_reg == 3'b000) begin
                    cmd       = CMD_FILD_MEM;
                    cmd_valid = 1'b1;
                    idx       = {2'b00, (op1 == 8'hDB)};
                end
                else if (modrm_reg == 3'b010) begin
                    cmd       = CMD_FIST_MEM;
                    cmd_valid = 1'b1;
                    idx       = {2'b00, (op1 == 8'hDB)};
                end
                else if (modrm_reg == 3'b011) begin
                    cmd       = CMD_FISTP_MEM;
                    cmd_valid = 1'b1;
                    idx       = {2'b00, (op1 == 8'hDB)};
            end
                end

            // Control word
            if (!cmd_valid && op1 == 8'hD9 && modrm_mod != 2'b11) begin
                if (modrm_reg == 3'b101) begin
                    cmd       = CMD_FLDCW;
                    cmd_valid = 1'b1;
            end
                else if (modrm_reg == 3'b111) begin
                    cmd       = CMD_FNSTCW;
                cmd_valid = 1'b1;
                end
            end

            // FLD/FSTP memory real
            if (!cmd_valid && op1 == 8'hD9 && modrm_mod != 2'b11) begin
                if (modrm_reg == 3'b000) begin cmd = CMD_FLD_M32;  cmd_valid = 1'b1; end
                else if (modrm_reg == 3'b011) begin cmd = CMD_FSTP_M32; cmd_valid = 1'b1; end
            end
            if (!cmd_valid && op1 == 8'hDD && modrm_mod != 2'b11) begin
                if (modrm_reg == 3'b000) begin cmd = CMD_FLD_M64;  cmd_valid = 1'b1; end
                else if (modrm_reg == 3'b011) begin cmd = CMD_FSTP_M64; cmd_valid = 1'b1; end
            end

            // Packed BCD memory
            // DF /4: FBLD  m80bcd
            // DF /6: FBSTP m80bcd
            if (!cmd_valid && op1 == 8'hDF && modrm_mod != 2'b11) begin
                if (modrm_reg == 3'b100) begin
                    cmd       = CMD_BCD_MEM;
                    idx       = IDX_BCD_FBLD;
                    cmd_valid = 1'b1;
                end
                else if (modrm_reg == 3'b110) begin
                    cmd       = CMD_BCD_MEM;
                    idx       = IDX_BCD_FBSTP;
                    cmd_valid = 1'b1;
            end
            end

            // Register stack ops via ESC opcodes (modrm_mod==11)
            if (!cmd_valid && op1 == 8'hD9 && modrm_mod == 2'b11) begin
                // D9 C0+i: FLD ST(i)
                if (op2[7:3] == 5'b11000) begin
                    cmd       = CMD_FLD_STI;
                    cmd_valid = 1'b1;
                    idx       = modrm_rm;
            end
                // D9 C8+i: FXCH ST(i)
                else if (op2[7:3] == 5'b11001) begin
                    cmd       = CMD_FXCH_STI;
                    cmd_valid = 1'b1;
                    idx       = modrm_rm;
            end
                end
            if (!cmd_valid && op1 == 8'hDD && modrm_mod == 2'b11) begin
                // DD D8+i: FSTP ST(i)
                if (op2[7:3] == 5'b11011) begin
                    cmd       = CMD_FSTP_STI;
                    cmd_valid = 1'b1;
                    idx       = modrm_rm;
                end
                end

            // Arithmetic / compare (register forms)
            if (!cmd_valid && op1 == 8'hD8 && modrm_mod == 2'b11) begin
                case (modrm_reg)
                    3'b000: begin cmd = CMD_FADD_STI; cmd_valid = 1'b1; idx = modrm_rm; end
                    3'b001: begin cmd = CMD_FMUL_STI; cmd_valid = 1'b1; idx = modrm_rm; end
                    3'b110: begin cmd = CMD_FDIV_STI; cmd_valid = 1'b1; idx = modrm_rm; end
                    3'b111: begin cmd = CMD_FDIVR_STI; cmd_valid = 1'b1; idx = modrm_rm; end
                    3'b100: begin cmd = CMD_FSUB_STI; cmd_valid = 1'b1; idx = modrm_rm; end
                    3'b101: begin cmd = CMD_FSUBR_STI; cmd_valid = 1'b1; idx = modrm_rm; end
                    default: begin end
                endcase
                end
            if (!cmd_valid && op1 == 8'hD8 && modrm_mod == 2'b11) begin
                if (modrm_reg == 3'b010) begin cmd = CMD_FCOM_STI;  cmd_valid = 1'b1; idx = modrm_rm; end
                if (modrm_reg == 3'b011) begin cmd = CMD_FCOMP_STI; cmd_valid = 1'b1; idx = modrm_rm; end
            end

            // Pop variants (DE)
            if (!cmd_valid && op1 == 8'hDE && modrm_mod == 2'b11) begin
                case (modrm_reg)
                    3'b000: begin cmd = CMD_FADDP_STI;  cmd_valid = 1'b1; idx = modrm_rm; end
                    3'b001: begin cmd = CMD_FMULP_STI;  cmd_valid = 1'b1; idx = modrm_rm; end
                    3'b100: begin cmd = CMD_FSUBP_STI;  cmd_valid = 1'b1; idx = modrm_rm; end
                    3'b101: begin cmd = CMD_FSUBRP_STI; cmd_valid = 1'b1; idx = modrm_rm; end
                    3'b110: begin cmd = CMD_FDIVP_STI;  cmd_valid = 1'b1; idx = modrm_rm; end
                    3'b111: begin cmd = CMD_FDIVRP_STI; cmd_valid = 1'b1; idx = modrm_rm; end
                    default: begin end
                endcase
            end
        end
    end
endmodule
