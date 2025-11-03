// -----------------------------------------------------------------------------
// P Transform
// Byte permutation stage that reorders the 64 bytes of the 512-bit input block
// according to a fixed permutation pattern.
//
// Operation:
//   o_data[i] = i_data[Pi(i)]
// where Pi(i) is the permutation table implemented via local index calculation.
//
// Interface:
//  - i_data : 512-bit input block
//  - o_data : 512-bit output block with permuted bytes
//
// Notes:
//  - Fully combinational; no internal state or registers.
//  - The permutation is defined by the formula below (idx computation).
// -----------------------------------------------------------------------------

module p_transform (
    input  logic [511:0] i_data,    // Input data block for permutation
    output logic [511:0] o_data     // Output permuted block
);

// Generate 64 parallel assignment statements — one per byte of the block.
genvar i;
generate
    for (i = 0; i < 64; i++) begin : perm_loop
        // ---------------------------------------------------------------------
        // Compute source byte index for current output position:
        //   idx = (i * 8 + i / 8) % 64
        // This formula encodes the fixed permutation table (Pi) used in the standard.
        // ---------------------------------------------------------------------
        localparam int idx = (i * 8 + i / 8) % 64;
        // Assign permuted byte from input to output based on calculated index.
        assign o_data[i*8 +: 8] = i_data[idx*8 +: 8];
    end
endgenerate

// -----------------------------------------------------------------------------
// End of P Transform
// -----------------------------------------------------------------------------
endmodule : p_transform
