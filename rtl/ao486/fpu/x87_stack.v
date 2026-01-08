// -----------------------------------------------------------------------------
// x87_stack.v - Phase 2A/2B x87 register stack (Quartus-safe Verilog)
// Internal format: 64-bit (double-precision bit pattern)
// Tag word: 2 bits per physical register (00=valid, 11=empty; others reserved)
// -----------------------------------------------------------------------------
module x87_stack (
    input  wire        clk,
    input  wire        rst,
    input  wire        soft_reset,

    // Stack operations (one-cycle pulses; may be combined as defined below)
    input  wire        do_push,
    input  wire        do_pop,
    input  wire        do_fxch,
    input  wire        do_write,

    // Indices are logical (relative to TOP)
    input  wire [2:0]  fxch_idx,
    input  wire [2:0]  write_idx,
    input  wire [2:0]  read_idx,

    // Data
    input  wire [63:0] push_value,
    input  wire [63:0] write_value,

    output wire [63:0] st0_value,
    output wire [63:0] sti_value,

    output reg  [2:0]  top,
    output reg  [15:0] tag_word
);

    reg [63:0] st_regs [0:7];

    // Physical index = TOP + logical (mod 8 via 3-bit wrap)
    function [2:0] phys_idx;
        input [2:0] logical;
        begin
            phys_idx = top + logical;
        end
    endfunction

    // Tag helpers (avoid variable part-select for Quartus)
    function [1:0] tag_get;
        input [2:0] phys;
        begin
            case (phys)
                3'd0: tag_get = tag_word[1:0];
                3'd1: tag_get = tag_word[3:2];
                3'd2: tag_get = tag_word[5:4];
                3'd3: tag_get = tag_word[7:6];
                3'd4: tag_get = tag_word[9:8];
                3'd5: tag_get = tag_word[11:10];
                3'd6: tag_get = tag_word[13:12];
                default: tag_get = tag_word[15:14];
            endcase
        end
    endfunction

    task tag_set_valid;
        input [2:0] phys;
        begin
            case (phys)
                3'd0: tag_word[1:0]   <= 2'b00;
                3'd1: tag_word[3:2]   <= 2'b00;
                3'd2: tag_word[5:4]   <= 2'b00;
                3'd3: tag_word[7:6]   <= 2'b00;
                3'd4: tag_word[9:8]   <= 2'b00;
                3'd5: tag_word[11:10] <= 2'b00;
                3'd6: tag_word[13:12] <= 2'b00;
                default: tag_word[15:14] <= 2'b00;
            endcase
        end
    endtask

    task tag_set_empty;
        input [2:0] phys;
        begin
            case (phys)
                3'd0: tag_word[1:0]   <= 2'b11;
                3'd1: tag_word[3:2]   <= 2'b11;
                3'd2: tag_word[5:4]   <= 2'b11;
                3'd3: tag_word[7:6]   <= 2'b11;
                3'd4: tag_word[9:8]   <= 2'b11;
                3'd5: tag_word[11:10] <= 2'b11;
                3'd6: tag_word[13:12] <= 2'b11;
                default: tag_word[15:14] <= 2'b11;
            endcase
        end
    endtask

    wire [2:0] st0_phys = phys_idx(3'd0);
    wire [2:0] read_phys = phys_idx(read_idx);
    wire [2:0] fxch_phys = phys_idx(fxch_idx);
    wire [2:0] write_phys = phys_idx(write_idx);

    assign st0_value = st_regs[st0_phys];
    assign sti_value = st_regs[read_phys];

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            top      <= 3'd0;
            tag_word <= 16'hFFFF;
            for (i = 0; i < 8; i = i + 1)
                st_regs[i] <= 64'd0;
        end
        else if (soft_reset) begin
            top      <= 3'd0;
            tag_word <= 16'hFFFF;
            for (i = 0; i < 8; i = i + 1)
                st_regs[i] <= 64'd0;
        end
        else begin
            // PUSH: TOP := TOP-1; write new ST0
            if (do_push) begin
                top <= top - 3'd1;
                st_regs[top - 3'd1] <= push_value;
                tag_set_valid(top - 3'd1);
            end

            // Arbitrary write: ST(write_idx) := write_value; mark valid
            if (do_write) begin
                st_regs[write_phys] <= write_value;
                tag_set_valid(write_phys);
            end

            // FXCH: swap ST0 and ST(fxch_idx)
            if (do_fxch) begin
                st_regs[st0_phys]  <= st_regs[fxch_phys];
                st_regs[fxch_phys] <= st_regs[st0_phys];
                // tags unchanged
            end

            // POP: mark current ST0 empty; TOP := TOP+1
            if (do_pop) begin
                tag_set_empty(st0_phys);
                top <= top + 3'd1;
            end
        end
    end

endmodule
