// -------------------------------------------------------------------------
// ao486 x87 decoder (Quartus-safe Verilog-2001)
// -------------------------------------------------------------------------
//
// This decoder maps the (op1, op2) bytes coming from the instruction stream
// into the compact {cmd,idx} interface consumed by x87_exec.v.
//
// Conventions
// - op1 is the primary opcode byte (typically D8..DF for x87 ESC).
// - op2 is the ModRM byte (or for certain x87 "group" opcodes, the second
//   byte which is encoded as a ModRM with mod=3).
// - idx is used for "ST(i)" selection (rm field) and for sub-op selection on
//   CMD_MISC / CMD_FPREM.
//
// This file is intentionally conservative: it decodes only the instructions
// that are implemented in the current x87_exec.v drop-in (Phases 0-6C).
// Unsupported opcodes decode to CMD_NOP.

module x87_decode(
    input       [7:0]   fpu_op1,
    input       [7:0]   fpu_op2,
    input               fpu_op2_valid,
    output reg        cmd_valid,
    output reg  [4:0]   cmd,
    output reg  [2:0] idx
);

    // Keep cmd encoding aligned with x87_exec.v localparams.
    localparam [4:0] CMD_NOP        = 5'd0;
    localparam [4:0] CMD_FLD_M32     = 5'd1;
    localparam [4:0] CMD_FLD_M64     = 5'd2;
    localparam [4:0] CMD_FST_M32     = 5'd3;
    localparam [4:0] CMD_FST_M64     = 5'd4;
    localparam [4:0] CMD_FSTP_M32    = 5'd5;
    localparam [4:0] CMD_FSTP_M64    = 5'd6;
    localparam [4:0] CMD_FLDCW       = 5'd27;
    localparam [4:0] CMD_FNSTCW      = 5'd28;
    localparam [4:0] CMD_FNINIT      = 5'd29;
    localparam [4:0] CMD_FNSTSW_AX   = 5'd30;
    localparam [4:0] CMD_MISC        = 5'd31;
    localparam [4:0] CMD_FPREM       = 5'd19;
    localparam [4:0] CMD_FXTRACT     = 5'd21; // present in x87_exec, but also mirrored in CMD_MISC idx=7
    localparam [4:0] CMD_FABS        = 5'd22; // present in x87_exec, but also mirrored in CMD_MISC idx=1
    localparam [4:0] CMD_FSCALE      = 5'd23;

    // Helpers
    wire [1:0] mod  = fpu_op2[7:6];
    wire [2:0] regf = fpu_op2[5:3];
    wire [2:0] rmf  = fpu_op2[2:0];
    wire       modrm_is_reg = (mod == 2'b11);

    always @(*) begin
        cmd_valid = 1'b0;
        cmd       = CMD_NOP;
        idx       = 3'd0;

        if (fpu_op2_valid) begin
            // Default: treat any recognized pattern as valid.
            // For all other patterns, cmd_valid stays low.

            // -------------------------------------------------
            // Phase 0: control / status
            // -------------------------------------------------
            // FNINIT/FINIT
            if (fpu_op1 == 8'hDB && fpu_op2 == 8'hE3) begin
            cmd_valid = 1'b1;
                cmd       = CMD_FNINIT;
        end
            // FNSTSW AX
            else if (fpu_op1 == 8'hDF && fpu_op2 == 8'hE0) begin
                cmd_valid = 1'b1;
            cmd       = CMD_FNSTSW_AX;
            end

            // -------------------------------------------------
            // Phase 0: FLDCW / FNSTCW (m16)
            // -------------------------------------------------
            else if (fpu_op1 == 8'hD9 && (modrm_is_reg == 1'b0) && regf == 3'd5) begin
            cmd_valid = 1'b1;
                cmd       = CMD_FLDCW;
        end
            else if (fpu_op1 == 8'hD9 && (modrm_is_reg == 1'b0) && regf == 3'd7) begin
            cmd_valid = 1'b1;
                cmd       = CMD_FNSTCW;
        end

            // -------------------------------------------------
            // Basic loads/stores (m32/m64 real)
            // -------------------------------------------------
            else if (fpu_op1 == 8'hD9 && (modrm_is_reg == 1'b0) && regf == 3'd0) begin
                    cmd_valid = 1'b1;
                cmd       = CMD_FLD_M32;
                end
            else if (fpu_op1 == 8'hDD && (modrm_is_reg == 1'b0) && regf == 3'd0) begin
                    cmd_valid = 1'b1;
                cmd       = CMD_FLD_M64;
                end
            else if (fpu_op1 == 8'hD9 && (modrm_is_reg == 1'b0) && regf == 3'd2) begin
                    cmd_valid = 1'b1;
                cmd       = CMD_FST_M32;
            end
            else if (fpu_op1 == 8'hDD && (modrm_is_reg == 1'b0) && regf == 3'd2) begin
                    cmd_valid = 1'b1;
                cmd       = CMD_FST_M64;
                end
            else if (fpu_op1 == 8'hD9 && (modrm_is_reg == 1'b0) && regf == 3'd3) begin
                    cmd_valid = 1'b1;
                cmd       = CMD_FSTP_M32;
            end
            else if (fpu_op1 == 8'hDD && (modrm_is_reg == 1'b0) && regf == 3'd3) begin
                cmd_valid = 1'b1;
                cmd       = CMD_FSTP_M64;
            end

            // -------------------------------------------------
            // Phase 4/5/6: misc + transcendental group (register only)
            // -------------------------------------------------
            // These are encoded as D9 xx with mod=3.
            else if (fpu_op1 == 8'hD9 && modrm_is_reg) begin
                cmd_valid = 1'b1;

                // D9 E0/E1/E4: unary/simple status
                if (fpu_op2 == 8'hE0) begin
                    // FCHS
                    cmd = CMD_MISC; idx = 3'd0;
            end
                else if (fpu_op2 == 8'hE1) begin
                    // FABS
                    cmd = CMD_MISC; idx = 3'd1;
                end
                else if (fpu_op2 == 8'hE4) begin
                    // FTST
                    cmd = CMD_MISC; idx = 3'd2;
            end

                // D9 FA/FC: sqrt / rndint
                else if (fpu_op2 == 8'hFA) begin
                    // FSQRT
                    cmd = CMD_MISC; idx = 3'd4;
                end
                else if (fpu_op2 == 8'hFC) begin
                    // FRNDINT
                    cmd = CMD_MISC; idx = 3'd5;
            end
                else if (fpu_op2 == 8'hFD) begin
                    // FSCALE
                    cmd = CMD_MISC; idx = 3'd6;
                end
                else if (fpu_op2 == 8'hF4) begin
                    // FXTRACT
                    cmd = CMD_MISC; idx = 3'd7;
            end

                // D9 F8/F5: prem/prem1
                else if (fpu_op2 == 8'hF8) begin
                    // FPREM
                    cmd = CMD_FPREM; idx = 3'd0;
            end
                else if (fpu_op2 == 8'hF5) begin
                    // FPREM1
                    cmd = CMD_FPREM; idx = 3'd1;
            end

                // D9 F0/F1: exp/log helpers
                else if (fpu_op2 == 8'hF0) begin
                    // F2XM1
                    cmd = CMD_FPREM; idx = 3'd2;
                end
                else if (fpu_op2 == 8'hF1) begin
                    // FYL2X
                    cmd = CMD_FPREM; idx = 3'd3;
                end

                // D9 F2/F3: trig helpers
                else if (fpu_op2 == 8'hF2) begin
                    // FPTAN
                    cmd = CMD_FPREM; idx = 3'd4;
                end
                else if (fpu_op2 == 8'hF3) begin
                    // FPATAN
                    cmd = CMD_FPREM; idx = 3'd5;
                end

                // D9 FB: FSINCOS
                else if (fpu_op2 == 8'hFB) begin
                    cmd = CMD_FPREM; idx = 3'd6;
                end
                else begin
                    // Unsupported D9 reg form
                    cmd_valid = 1'b0;
                    cmd       = CMD_NOP;
                    idx       = 3'd0;
                end
            end

            // -------------------------------------------------
            // Default: not decoded
            // -------------------------------------------------
            else begin
                cmd_valid = 1'b0;
                cmd       = CMD_NOP;
                idx       = 3'd0;
            end
        end
    end
endmodule
