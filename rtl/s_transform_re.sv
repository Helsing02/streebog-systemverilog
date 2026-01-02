// -----------------------------------------------------------------------------
// S Transform Combinational (S-box logic implementation)
//
// Implements the Streebog S-box transformation using optimized combinational logic
// instead of lookup tables.
//
// Operation:
//   Given an 8-bit input byte, applies a sequence of GF(2^4) operations to compute
//   the S-box output value. The transformation is mathematically equivalent to the
//   standard S-box but implemented through optimized boolean logic equations.
//
// Implementation Details:
//   - Decomposes the 8-bit transformation into 4 steps with intermediate
//     computations in GF(2^4) (4-bit Galois Field)
//   - Uses hand-optimized boolean equations derived from the algebraic normal form
//   - Fully combinational with no internal registers
//
// Interface:
//   - i_data : 8-bit input byte (original value)
//   - o_data : 8-bit output byte (S-box transformed value)
//
// Note: This implementation is functionally equivalent to the standard S-box table
//       but implemented through optimized logic gates for better performance.
// -----------------------------------------------------------------------------

module s_transform_re (
    input  logic [7:0] i_data,  // Input byte (original value)
    output logic [7:0] o_data   // Output byte (S-box transformed value)
);

    // -------------------------------------------------------------------------
    // Step 1: Input Decomposition
    //
    // Decompose the 8-bit input into individual bits and compute intermediate
    // values used in subsequent GF(2^4) operations. These equations are derived
    // from the algebraic normal form (ANF) of the S-box transformation.
    // -------------------------------------------------------------------------
    logic al_p1, alpha1, alpha2, alpha3, alpha4, alpha5, alpha6, alpha7, alpha8;
    assign al_p1  = i_data[3] ^ i_data[1];
    assign alpha1 = i_data[3];
    assign alpha2 = i_data[6] ^ i_data[0];
    assign alpha3 = alpha2 ^ i_data[1];
    assign alpha4 = alpha2 ^ alpha5 ^ i_data[5] ^ i_data[2];
    assign alpha5 = i_data[7] ^ al_p1;
    assign alpha6 = i_data[6] ^ i_data[2];
    assign alpha7 = i_data[4] ^ al_p1;
    assign alpha8 = i_data[5];

    // -------------------------------------------------------------------------
    // Step 2: Left Half (L) Computation
    //
    // Compute the 4-bit left half (L) of the intermediate representation using:
    //   L = ν₀(α₁α₂α₃α₄) ⊕ ν₁(I(α₅α₆α₇α₈) · (α₁α₂α₃α₄))
    // Special case handling when right half (α₅α₆α₇α₈) is zero.
    // -------------------------------------------------------------------------
    logic r_is_zero;
    assign r_is_zero = ~(alpha5 | alpha6 | alpha7 | alpha8);  // Detect zero right half

    logic [3:0] I_of_r;    // I transformation of right half
    I I_inst(
        .x({alpha5, alpha6, alpha7, alpha8}),
        .y(I_of_r)
    );

    logic [3:0] mult_result;  // GF(2^4) multiplication result
    gf_mult mult_l_ir (
        .x({alpha1, alpha2, alpha3, alpha4}),  // Left half
        .y(I_of_r),                            // Transformed right half
        .z(mult_result)
    );

    logic [3:0] nu0_of_l;    // ν₀ transformation of left half
    nu0 nu0_inst (
        .x({alpha1, alpha2, alpha3, alpha4}),
        .y(nu0_of_l)
    );

    logic [3:0] nu1_of_mult;  // ν₁ transformation of multiplication result
    nu1 nu1_inst (
        .x(mult_result),
        .y(nu1_of_mult)
    );

    logic [3:0] l_step2;     // Final left half value after Step 2
    localparam logic [3:0] NU1_OF_ZERO = {1'b0, 1'b1, 1'b1, 1'b1};  // ν₁(0) constant
    generate
        for (genvar i = 0; i < 4; i++) begin
            // Handle special case when right half is zero
            assign l_step2[i] = (r_is_zero & (nu0_of_l[i] ^ NU1_OF_ZERO[i])) ^ nu1_of_mult[i];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Step 3: Right Half (R) Computation
    //
    // Compute the 4-bit right half (R) of the intermediate representation:
    //   R = σ(φ(L) · (α₅α₆α₇α₈))
    // where · denotes GF(2^4) multiplication.
    // -------------------------------------------------------------------------
    logic [3:0] phi_of_l;    // φ transformation of left half
    phi phi_inst(
        .x(l_step2),
        .y(phi_of_l)
    );

    logic [3:0] mult_result2;  // Second GF(2^4) multiplication
    gf_mult mult_r_phil (
        .x({alpha5, alpha6, alpha7, alpha8}),  // Right half
        .y(phi_of_l),                          // φ-transformed left half
        .z(mult_result2)
    );

    logic [3:0] r_step3;     // Final right half value after Step 3
    sigma sigma_inst(
        .x(mult_result2),
        .y(r_step3)
    );

    // -------------------------------------------------------------------------
    // Step 4: Output Reconstruction
    //
    // Reconstruct the final 8-bit output from the 4-bit left and right halves
    // (L and R) using the bit permutation defined by the S-box structure.
    // -------------------------------------------------------------------------
    logic t1, t2;  // Temporary terms for output bit computation
    assign t1 = l_step2[0] ^ r_step3[3];
    assign t2 = t1 ^ r_step3[1];

    // Output bit assignments according to S-box permutation pattern
    assign o_data[7] = r_step3[3] ^ r_step3[1];
    assign o_data[6] = r_step3[2];
    assign o_data[5] = l_step2[1];
    assign o_data[4] = l_step2[3] ^ t2;
    assign o_data[3] = r_step3[3];
    assign o_data[2] = l_step2[2] ^ r_step3[2];
    assign o_data[1] = l_step2[3] ^ r_step3[1];
    assign o_data[0] = r_step3[0];

// -----------------------------------------------------------------------------
// End of S Transform Combinational
// -----------------------------------------------------------------------------
endmodule : s_transform_re

// -----------------------------------------------------------------------------
// I Transformation
//
// Interface:
//   - x : 4-bit input value
//   - y : 4-bit transformed output
// -----------------------------------------------------------------------------
module I (
    input  logic [3:0] x,
    output logic [3:0] y
);
    logic p1, p2;  // Intermediate parity terms
    assign p1 = x[0] ^ x[2];
    assign p2 = x[2] ^ x[3];

    // Optimized boolean equations for I transformation
    assign y[0] = (x[0] & ~x[1]) | (((x[0] ^ x[1]) | ~p1) & x[3]);
    assign y[1] = (x[0] & x[2]) ^ (~x[1] & p1 & p2) ^ x[3];
    assign y[2] = ((x[1] ^ x[3]) & ((x[0] | x[2]) ^ x[1])) ^ x[2];
    assign y[3] = (x[1] & ~x[2]) | (((x[1] ^ x[2]) | p2) & x[0]);

// -----------------------------------------------------------------------------
// End of I Transform
// -----------------------------------------------------------------------------
endmodule : I

// -----------------------------------------------------------------------------
// GF(2^4) Multiplier
//
// Performs multiplication in the Galois Field GF(2^4) defined by the standard
// polynomial x^4 + x^3 + 1 (hexadecimal representation: 0x19).
//
// Operation:
//   Computes z = x × y in GF(2^4) where both inputs and output are 4-bit vectors.
//   Multiplication follows the standard polynomial multiplication with reduction
//   modulo the irreducible polynomial.
//
// Interface:
//   - x : 4-bit multiplicand (GF(2^4) element)
//   - y : 4-bit multiplier (GF(2^4) element)
//   - z : 4-bit product (GF(2^4) element)
// -----------------------------------------------------------------------------
module gf_mult (
    input  logic [3:0] x,
    input  logic [3:0] y,
    output logic [3:0] z
);
    logic p1, p2;  // Intermediate terms for optimization
    assign p1 = x[3] ^ x[2];
    assign p2 = p1 ^ x[1];

    // Optimized product computation using shared terms
    assign z[3] = (p2 ^ x[0]) & y[3] ^ p2 & y[2] ^ p1 & y[1] ^ x[3] & y[0];
    assign z[2] = x[3] & y[3] ^ x[0] & y[2] ^ x[1] & y[1] ^ x[2] & y[0];
    assign z[1] = p1 & y[3] ^ x[3] & y[2] ^ x[0] & y[1] ^ x[1] & y[0];
    assign z[0] = p2 & y[3] ^ p1 & y[2] ^ x[3] & y[1] ^ x[0] & y[0];

// -----------------------------------------------------------------------------
// End of GF multiplication
// -----------------------------------------------------------------------------
endmodule : gf_mult

// -----------------------------------------------------------------------------
// ν₀ Transformation
//
// Interface:
//   - x : 4-bit input value
//   - y : 4-bit transformed output
// -----------------------------------------------------------------------------
module nu0 (
    input  logic [3:0] x,
    output logic [3:0] y
);
    logic p1;  // Intermediate term
    assign p1 = x[0] | x[3];

    // Boolean equations for ν₀ transformation
    assign y[0] = (x[1] & ~x[2]) | (((x[1] ^ x[2]) | (~x[1] ^ x[3])) & x[0]);
    assign y[1] = (~((x[0] ^ x[2]) & x[3]) & x[1]) | ~p1;
    assign y[2] = (x[1] & x[3]) ^ (((x[2] ^ x[3]) | ~x[1]) & x[0]) ^ (x[2] & ~x[3]);
    assign y[3] = ((x[1] ^ p1) & x[2]) ^ ((x[0] ^ x[3]) & x[1]);

// -----------------------------------------------------------------------------
// End of ν₀ Transform
// -----------------------------------------------------------------------------
endmodule : nu0

// -----------------------------------------------------------------------------
// ν₁ Transformation
//
// Interface:
//   - x : 4-bit input value
//   - y : 4-bit transformed output
// -----------------------------------------------------------------------------
module nu1 (
    input  logic [3:0] x,
    output logic [3:0] y
);
    logic p1;  // Intermediate term
    assign p1 = x[0] ^ x[3];

    // Boolean equations for ν₁ transformation
    assign y[0] = ~((x[1] | x[2]) ^ p1);
    assign y[1] = ~(((x[2] | x[3]) ^ (x[0] & x[2])) | x[1]) ^ (x[1] & x[3]);
    assign y[2] = ((x[1] ^ x[2]) & p1) ^ ~x[2];
    assign y[3] = (x[2] & p1) ^ x[1];

// -----------------------------------------------------------------------------
// End of ν₁ Transform
// -----------------------------------------------------------------------------
endmodule : nu1

// -----------------------------------------------------------------------------
// φ Transformation
//
// Interface:
//   - x : 4-bit input value
//   - y : 4-bit transformed output
// -----------------------------------------------------------------------------
module phi (
    input  logic [3:0] x,
    output logic [3:0] y
);
    // Boolean equations for φ transformation
    assign y[0] = (~((x[0] & ~x[1]) | (x[1] ^ x[3])) & x[2]) ^ (~x[1] & x[3]) ^ ~x[0];
    assign y[1] = ~(((x[0] | x[3]) & x[1]) | x[2]) ^ (x[2] & x[3]);
    assign y[2] = (~x[0] & x[3]) | (((x[0] | ~x[1]) ^ (x[0] & x[3])) & x[2]);
    assign y[3] = (x[0] & x[1]) ^ (((x[2] | ~x[3]) ^ (x[1] & x[2])) & ~x[0]);

// -----------------------------------------------------------------------------
// End of φ Transform
// -----------------------------------------------------------------------------
endmodule : phi

// -----------------------------------------------------------------------------
// σ Transformation
//
// Interface:
//   - x : 4-bit input value
//   - y : 4-bit transformed output
// -----------------------------------------------------------------------------
module sigma (
    input  logic [3:0] x,
    output logic [3:0] y
);
    logic p1;  // Intermediate term
    assign p1 = x[0] ^ x[2];

    // Boolean equations for σ transformation
    assign y[0] = (x[0] & ~x[1]) | (~(x[1] & p1) & x[3]);
    assign y[1] = (((x[2] | x[3]) ^ (x[1] & x[2])) & x[0]) ^ ((x[2] ^ x[3]) & x[1]) ^ x[3];
    assign y[2] = (x[0] & x[1]) ^ (((x[0] & x[3]) ^ ~x[1]) & x[2]) ^ ~x[1] ^ x[3];
    assign y[3] = (x[2] & ~x[3]) | ((~x[3] | p1) & ~x[1]);

// -----------------------------------------------------------------------------
// End of σ Transform
// -----------------------------------------------------------------------------
endmodule : sigma
