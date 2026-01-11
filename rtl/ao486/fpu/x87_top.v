module x87_top (
    input  wire        clk,
    input  wire        rst,

    input  wire        fpu_start,
    input  wire [7:0]  fpu_op1,
    input  wire [7:0]  fpu_op2,
    input  wire        fpu_op2_valid,
    input  wire [3:0]  fpu_step,

    input  wire [31:0] mem_rdata32,
    input  wire [63:0] mem_rdata64,

    output reg         fpu_busy,
    output reg         fpu_done,

    output reg         fpu_wb_valid,
    output reg  [2:0]  fpu_wb_kind,
    output reg  [15:0] fpu_wb_value,

    output reg         memstore_valid,
    output reg  [1:0]  memstore_size,
    output reg  [63:0] memstore_data64
);
    wire [4:0] dec_cmd;
    wire       dec_valid;
    wire [2:0] dec_idx;

    x87_decode u_dec(
        .fpu_op1(fpu_op1),
        .fpu_op2(fpu_op2),
        .fpu_op2_valid(fpu_op2_valid),
        .cmd(dec_cmd),
        .cmd_valid(dec_valid),
        .idx(dec_idx)
    );

    wire exec_busy, exec_done;
    wire exec_wb_valid;
    wire [2:0] exec_wb_kind;
    wire [15:0] exec_wb_value;

    wire exec_memstore_valid;
    wire [1:0] exec_memstore_size;
    wire [63:0] exec_memstore_data64;

    x87_exec u_exec(
        .clk(clk),
        .rst(rst),

        .start(fpu_start),
        .cmd(dec_cmd),
        .cmd_valid(dec_valid),
        .idx(dec_idx),
        .step(fpu_step),

        .mem_rdata32(mem_rdata32),
        .mem_rdata64(mem_rdata64),

        .memstore_valid(exec_memstore_valid),
        .memstore_size(exec_memstore_size),
        .memstore_data64(exec_memstore_data64),

        .busy(exec_busy),
        .done(exec_done),

        .wb_valid(exec_wb_valid),
        .wb_kind(exec_wb_kind),
        .wb_value(exec_wb_value)
    );

    always @(posedge clk) begin
        if (rst) begin
            fpu_busy <= 1'b0;
            fpu_done <= 1'b0;
            fpu_wb_valid <= 1'b0;
            fpu_wb_kind <= 3'd0;
            fpu_wb_value <= 16'd0;
            memstore_valid <= 1'b0;
            memstore_size <= 2'd0;
            memstore_data64 <= 64'd0;
        end else begin
            fpu_busy <= exec_busy;
            fpu_done <= exec_done;
            fpu_wb_valid <= exec_wb_valid;
            fpu_wb_kind <= exec_wb_kind;
            fpu_wb_value <= exec_wb_value;
            memstore_valid <= exec_memstore_valid;
            memstore_size <= exec_memstore_size;
            memstore_data64 <= exec_memstore_data64;
        end
    end
endmodule
