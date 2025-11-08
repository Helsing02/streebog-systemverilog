// -----------------------------------------------------------------------------
// LPSX Transform
// -----------------------------------------------------------------------------
// Combined transformation performing S, P, and L stages sequentially,
// preceded by an initial XOR mixing layer (X-stage).
//
// Implements the core round function used in several cipher pipelines:
//
//     L(P(S(A ⊕ B)))
//
// where:
//   - A, B : 512-bit operands (e.g. message and round key)
//   - S    : nonlinear substitution layer (S-boxes)
//   - P    : byte permutation layer
//   - L    : linear diffusion layer
//
// Two operating modes:
//   1. USE_PRECALC = 0 → pure combinational pipeline: S → P → L
//   2. USE_PRECALC = 1 → precomputed ROM-based pipeline (uses ls_transform_rom)
//
// Interface:
//   - clk, rst_n   : clock and active-low reset (used only for USE_PRECALC=1)
//   - i_data_a/b   : 512-bit input operands
//   - i_valid      : input valid signal
//   - o_data       : 512-bit transformed result
//   - o_valid      : output valid (delayed by 1 cycle when USE_PRECALC=1)
//
// Notes:
//   - Fully combinational in naive mode (USE_PRECALC=0).
//   - One-cycle pipeline latency in precalculated ROM mode.
// -----------------------------------------------------------------------------

module lpsx_transform #(
    parameter USE_S_RE     = 1,     // 1 → use improved (reverse-engineered) S-box variant
    parameter USE_PRECALC  = 1      // 1 → use ROM-based precalculated pipeline
)(
    input  logic         clk,       // Clock
    input  logic         rst_n,     // Synchronous active-low reset

    input  logic [511:0] i_data_a,  // Input data block A
    input  logic [511:0] i_data_b,  // Input data block B
    input  logic         i_valid,   // Input valid

    output logic [511:0] o_data,    // Output transformed data block
    output logic         o_valid    // Output valid signal
);

// -----------------------------------------------------------------------------
// Stage interconnect signals
// -----------------------------------------------------------------------------
logic [511:0] x_out;   // XOR stage output (A ⊕ B)
logic [511:0] s_out;   // S-stage output
logic [511:0] p_out;   // P-stage output

// -----------------------------------------------------------------------------
// X-stage: initial mixing layer
// -----------------------------------------------------------------------------
assign x_out = i_data_a ^ i_data_b;

// -----------------------------------------------------------------------------
// Generate alternative pipelines based on USE_PRECALC
// -----------------------------------------------------------------------------
genvar i;
generate
    if (USE_PRECALC) begin : gen_precalc_mode
        // ---------------------------------------------------------------------
        // PRECALC (ROM-based) pipeline
        // Performs integrated LS transformation using precomputed ROM tables.
        // ---------------------------------------------------------------------
        //
        // Stage order:
        //     X (⊕) → P → LS_ROM
        //
        // Each 64-bit slice of P output is fed into an LS-ROM instance,
        // which performs substitution + linear diffusion + precomputation.
        // The LS-ROM stage adds 1 clock latency and generates its own valid.
        //
        // ---------------------------------------------------------------------

        // ---------------------------------------------------------------------
        // P-stage: byte permutation
        // ---------------------------------------------------------------------
        p_transform P_stage (
            .i_data (x_out),
            .o_data (p_out)
        );

        // ---------------------------------------------------------------------
        // LS-ROM stage (8 parallel slices)
        // ---------------------------------------------------------------------
        logic [7:0] valid_slices;  // per-slice valid signals (aggregated)

        for (i = 0; i < 8; i++) begin : gen_ls_rom
            ls_transform_rom u_ls_rom (
                .clk     (clk),
                .rst_n   (rst_n),
                .i_data  (p_out[i*64 +: 64]),
                .i_valid (i_valid),
                .o_data  (o_data[i*64 +: 64]),
                .o_valid (valid_slices[i])
            );
        end

        // ---------------------------------------------------------------------
        // Aggregate valid signals
        // ---------------------------------------------------------------------
        // All LS-ROM instances should assert valid simultaneously
        // (identical latency and synchronous design).
        // Therefore, a simple OR-reduction is safe.
        assign o_valid = |valid_slices;

    end else begin : gen_naive_mode
        // ---------------------------------------------------------------------
        // NAIVE (combinational) pipeline
        // Performs standard sequential S → P → L transformations.
        // ---------------------------------------------------------------------
        //
        // Stage order:
        //     X (⊕) → S → P → L
        // ---------------------------------------------------------------------

        // ---------------------------------------------------------------------
        // S-stage: substitution
        // ---------------------------------------------------------------------
        s_transform #(
            .USE_S_RE(USE_S_RE)
        ) S_stage (
            .i_data (x_out),
            .o_data (s_out)
        );

        // ---------------------------------------------------------------------
        // P-stage: byte permutation
        // ---------------------------------------------------------------------
        p_transform P_stage (
            .i_data (s_out),
            .o_data (p_out)
        );

        // ---------------------------------------------------------------------
        // L-stage: linear diffusion
        // ---------------------------------------------------------------------
        l_transform L_stage (
            .i_data (p_out),
            .o_data (o_data)
        );

        // Combinational mode has no latency — propagate valid directly.
        assign o_valid = i_valid;
    end
endgenerate

// -----------------------------------------------------------------------------
// End of LPSX Transform
// -----------------------------------------------------------------------------
endmodule : lpsx_transform
