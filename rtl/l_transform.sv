// -----------------------------------------------------------------------------
// L Transform
// Linear mixing stage performing matrix-based XOR transformations
// across 8 independent 64-bit segments of the 512-bit input block.
//
// Each segment passes through matrix_multiplication module which
// applies a fixed 64×64 binary matrix (GF(2) arithmetic).
//
// Interface:
//  - i_data : 512-bit input block
//  - o_data : 512-bit output block (8 × 64-bit transformed segments)
//
// Notes:
//  - Fully combinational implementation.
// -----------------------------------------------------------------------------


module l_transform (
    input  logic [511:0] i_data,    // Input data block for 8 matrix multiplication
    output logic [511:0] o_data     // Output result of 8 multiplications
);

// Generate 8 parallel matrix multiplication units.
// Each unit processes one 64-bit slice of the 512-bit input block.
genvar i;
generate
    for (i = 0; i < 8; i++) begin : gen_loop
        // ---------------------------------------------------------------------
        // Matrix multiplication instance
        // Applies predefined 64×64 transformation matrix to one 64-bit input slice.
        // Produces one 64-bit output slice.
        //
        // Slice mapping:
        //  - i_data[i*64 +: 64] → o_data[i*64 +: 64]
        // ---------------------------------------------------------------------
        matrix_multiplication matr_mult_instance (
            .i_data(i_data[i*64 +: 64]),
            .o_data(o_data[i*64 +: 64])
        );
    end
endgenerate

// -----------------------------------------------------------------------------
// End of L Transform
// -----------------------------------------------------------------------------
endmodule : l_transform
