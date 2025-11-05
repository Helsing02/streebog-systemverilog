// -----------------------------------------------------------------------------
// LPSX Transform
// Combined transformation performing S, P, and L stages sequentially.
// Implements the core round operation: L(P(S(A ⊕ B)))
//
// Interface:
//  - i_data_a, i_data_b : 512-bit operands (usually message block and round key).
//  - o_data             : 512-bit output (transformed block).
//
// Notes:
//  - USE_S_RE parameter selects S-box variant (regular or reversed).
//  - This unit is purely combinational (no internal registers).
// -----------------------------------------------------------------------------

module lpsx_transform # (
    parameter USE_S_RE = 1,         // 1 -> use s_transform_rc module, 0 -> use naive method
    parameter USE_PRECALC = 1
)(
    input  logic         clk,
    input  logic         rst_n,

    input  logic [511:0] i_data_a,  // Input data block A
    input  logic [511:0] i_data_b,  // Input data block B
    input  logic         i_valid,

    output logic [511:0] o_data,    // Output transformed data block
    output logic         o_valid
);

// Intermediate stage results:
//  x_out : XOR of input data blocks (A ⊕ B)
//  s_out : output of substitution (S-box) stage
//  p_out : output of permutation (byte reordering) stage
logic [511:0] x_out;
logic [511:0] s_out;
logic [511:0] p_out;

// -----------------------------------------------------------------------------
// X-stage: initial mixing layer
// Compute bitwise XOR of A and B before substitution.
// -----------------------------------------------------------------------------
assign x_out = i_data_a ^ i_data_b;

genvar i;
generate
    if (USE_PRECALC) begin
        p_transform P_instance (
            .i_data  (x_out),
            .o_data  (p_out)
        );

        logic [7:0] valid_temp;

        for (i = 0; i < 8; i++) begin
            matrix_multiplication_rom rom_instance (
                .clk    (clk),
                .rst_n  (rst_n),

                .i_data (p_out[i*64 +: 64]),
                .i_valid(i_valid),

                .o_data (o_data[i*64 +: 64]),
                .o_valid(valid_temp[i])
            );
        end
        assign o_valid = &valid_temp;
    end else begin
        // ---------------------------------------------------------------------
        // S-stage: nonlinear substitution layer
        // Applies byte-wise substitution using S-box table.
        // Parameter USE_S_RE selects S-box variant (0 = regular, 1 = reverse engineering (improved)).
        // ---------------------------------------------------------------------
        s_transform # (
            .USE_S_RE(USE_S_RE)
        ) S_instance (
            .i_data  (x_out),
            .o_data  (s_out)
        );

        // ---------------------------------------------------------------------
        // P-stage: byte permutation layer
        // Reorders bytes according to fixed permutation table (Pi).
        // Provides diffusion across the 512-bit data block.
        // ---------------------------------------------------------------------
        p_transform P_instance (
            .i_data  (s_out),
            .o_data  (p_out)
        );

        // ---------------------------------------------------------------------
        // L-stage: linear mixing layer
        // Applies matrix-based XOR mixing over 64-byte vector.
        // Produces the final transformed block for this round.
        // ---------------------------------------------------------------------
        l_transform L_instance (
            .i_data  (p_out),
            .o_data  (o_data)
        );

        assign o_valid = i_valid;
    end
endgenerate

// -----------------------------------------------------------------------------
// End of LPSX Transform
// -----------------------------------------------------------------------------
endmodule : lpsx_transform
