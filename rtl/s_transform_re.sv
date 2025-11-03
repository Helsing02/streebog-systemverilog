// -----------------------------------------------------------------------------
// S Transform (Reverse Engineered Version)
// Implements the 8-bit substitution (S-box) operation using algebraic
// transformations instead of a precomputed lookup table.
//
// Operation summary:
//   - Input byte is first mixed with matrix α (alpha_matrix)
//   - Then split into 4-bit halves (l, r) processed in GF(2⁴)
//   - Applies nonlinear functions ν₀, ν₁, σ, φ and inversion over GF(16)
//   - Final 8-bit result is obtained by matrix multiplication with ω (omega_matrix)
//
// Purpose:
//   Provides an alternative, hardware-efficient implementation of S-box
//   using smaller lookup tables and combinational arithmetic.
//
// Interface:
//  - i_data : 8-bit input byte
//  - o_data : 8-bit substituted output byte
//
// Notes:
//  - Fully combinational (no sequential logic).
//  - Optimized for synthesis with LUT-based FPGA fabrics.
// -----------------------------------------------------------------------------

module s_transform_re (
    input  logic [7:0] i_data,
    output logic [7:0] o_data
);
// -----------------------------------------------------------------------------
// Lookup tables for nonlinear 4-bit functions (defined over GF(16)):
//  - ν₀, ν₁    : nonlinear substitution layers
//  - σ, φ      : intermediate transformation functions
//  - inv_field : multiplicative inverses in GF(16)
// -----------------------------------------------------------------------------
logic [3:0] nu0 [0:15] =       '{4'h2,4'h5,4'h3,4'hb,4'h6,4'h9,4'he,4'ha,4'h0,4'h4,4'hf,4'h1,4'h8,4'hd,4'hc,4'h7};
logic [3:0] nu1 [0:15] =       '{4'h7,4'h6,4'hc,4'h9,4'h0,4'hf,4'h8,4'h1,4'h4,4'h5,4'hb,4'he,4'hd,4'h2,4'h3,4'ha};
logic [3:0] sigma [0:15] =     '{4'hc,4'hd,4'h0,4'h4,4'h8,4'hb,4'ha,4'he,4'h3,4'h9,4'h5,4'h2,4'hf,4'h1,4'h6,4'h7};
logic [3:0] phi [0:15] =       '{4'hb,4'h2,4'hb,4'h8,4'hc,4'h4,4'h1,4'hc,4'h6,4'h3,4'h5,4'h8,4'he,4'h3,4'h6,4'hb};
logic [3:0] inv_field [0:15] = '{4'h0,4'h1,4'hc,4'h8,4'h6,4'hf,4'h4,4'he,4'h3,4'hd,4'hb,4'ha,4'h2,4'h9,4'h7,4'h5};

// -----------------------------------------------------------------------------
// Linear transformation matrices α (alpha) and ω (omega)
// Each defined as 8×8 binary matrices (one byte per row).
// Used for input pre-processing and output post-processing respectively.
// -----------------------------------------------------------------------------
logic [7:0] alpha_matrix[0:7] = {
    8'b00011000,
    8'b01110100,
    8'b00010001,
    8'b00000010,
    8'b10011010,
    8'b00010100,
    8'b00111010,
    8'b01110000
};

logic [7:0] omega_matrix[0:7] = {
    8'b00010010,
    8'b00000100,
    8'b00100000,
    8'b00010000,
    8'b10011000,
    8'b01000100,
    8'b10010010,
    8'b00000001
};

// -----------------------------------------------------------------------------
// 8×8 binary matrix multiplication
// Computes vector × matrix product over GF(2) using XOR arithmetic.
// -----------------------------------------------------------------------------
function logic [7:0] matmul8x8(input logic [7:0] x, input logic [7:0] matrix [7:0]);
    logic [7:0] res;
    integer i;
    begin
        res = 8'b0;
        for (i = 0; i < 8; i++) begin
            if(x[i]) begin
                res ^= matrix[i];
            end
        end
        return res;
    end
endfunction


// -----------------------------------------------------------------------------
// Multiplication in GF(2⁴) with primitive polynomial x⁴ + x³ + 1.
// Performs bitwise multiply followed by modular reduction.
// -----------------------------------------------------------------------------
function logic [3:0] gf16_mul(input logic [3:0] a, input logic [3:0] b);
    logic [7:0] p;
    int i;
    p = 0;
    for (i = 0; i < 4; i++) begin
        if (b[i]) p ^= (a << i);
    end
    // Редукция по X^4+X^3+1
    for (i = 7; i >= 4; i--) begin
        if (p[i]) p ^= (9 << (i - 4)); // 9 = 1001b corresponds X^4 + X^3 + 1
    end
    gf16_mul = p[3:0];
endfunction


logic [3:0] l, r, l_new, r_new;

// -----------------------------------------------------------------------------
// Main substitution algorithm (combinational):
// 1. Apply α-matrix transformation
// 2. Split byte into 4-bit halves (l, r)
// 3. Compute l_new using ν₀ or ν₁ depending on r
// 4. Compute r_new = σ(r × φ(l_new))
// 5. Combine (l_new, r_new) and apply ω-matrix transformation
// -----------------------------------------------------------------------------
always_comb begin
    logic [7:0] tmp;

    // 1
    tmp = matmul8x8(i_data, alpha_matrix);
    l = tmp[7:4];
    r = tmp[3:0];

    // 2
    if (r == 4'b0000) begin
        l_new = nu0[l];
    end else begin
        // l_new = nu1(l * r^-1)
        l_new = nu1[gf16_mul(l, inv_field[r])];
    end

    // 3
    // r_new = sigma(r * phi(l_new))
    r_new = sigma[gf16_mul(r, phi[l_new])];

    // 4
    // Final output transformation using ω-matrix
    // Produces substituted 8-bit output value.
    o_data = matmul8x8({l_new, r_new}, omega_matrix);
end

// -----------------------------------------------------------------------------
// End of S Transform (Reverse Engineered)
// -----------------------------------------------------------------------------
endmodule : s_transform_re
