// -----------------------------------------------------------------------------
// x87_format.v - Shared x87 format constants (Phase 7B)
// Quartus-safe Verilog-2001
// -----------------------------------------------------------------------------
module x87_format(input wire clk,input wire rst);

    // Packed BCD 'indefinite' encoding used by FBSTP on masked invalid.
    // Intel-defined constant: FFFF C000 0000 0000 0000 00h (80-bit).
    localparam [79:0] PACKED_BCD_INDEFINITE = 80'hFFFFC000000000000000;

    // Quiet NaN 'indefinite' used internally for deterministic invalid conversions.
    localparam [63:0] FP64_QNAN_INDEFINITE  = 64'hFFF8000000000000;

endmodule
