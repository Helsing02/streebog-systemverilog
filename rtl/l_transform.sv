// -----------------------------------------------------------------------------
// L Transform
// Linear diffusion stage performing 64×64 binary matrix multiplication
// across 8 independent 64-bit slices of the 512-bit input block.
//
// Concept:
//   - The 512-bit input block is split into 8 × 64-bit words.
//   - Each slice is independently transformed by a fixed 64×64 binary matrix
//     over GF(2) (XOR-based arithmetic).
//   - The results are concatenated back into a 512-bit output.
//
// Interface:
//   - i_data : 512-bit input block (8 × 64-bit words)
//   - o_data : 512-bit output block (8 × transformed 64-bit words)
//
// Notes:
//   - Fully combinational (no internal state).
//   - Each slice is handled by its own instance of matrix_multiplication.
//   - Used after S-Transform or other nonlinear stage.
// -----------------------------------------------------------------------------

module l_transform (
    input  logic [511:0] i_data,    // Input data block for 8 matrix multiplications
    output logic [511:0] o_data     // Output data block (concatenated results)
);

// -----------------------------------------------------------------------------
// Generate 8 parallel transformation units.
// Each 64-bit slice is transformed independently using matrix_multiplication.
// -----------------------------------------------------------------------------
genvar i;
generate
    for (i = 0; i < 8; i++) begin : gen_slice
        // ---------------------------------------------------------------------
        // 64-bit Matrix Multiplication Unit
        // Performs one instance of 64×64 matrix multiply in GF(2)
        // Slice mapping:
        //   i_data[i*64 +: 64] → o_data[i*64 +: 64]
        // ---------------------------------------------------------------------
        matrix_multiplication u_matrix_mul (
            .i_data(i_data[i*64 +: 64]),
            .o_data(o_data[i*64 +: 64])
        );
    end
endgenerate

// -----------------------------------------------------------------------------
// End of L Transform
// -----------------------------------------------------------------------------
endmodule : l_transform
