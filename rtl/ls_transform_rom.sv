// -----------------------------------------------------------------------------
// LS Transform ROM
// Precomputed nonlinear substitution (S-box) + linear transformation (L-matrix)
// stage implemented as ROM-based lookup.
//
// Overview:
//   This module performs a combined **S-transform** and **L-transform**
//   for a single 64-bit word (8 bytes) using precomputed lookup tables
//   stored in block ROMs.
//
//   Each ROM entry encodes the result of applying both transforms to
//   one input byte and its corresponding matrix row:
//
//       o_data = Σ_i (L_i × S(i_data[i]))  (GF(2) XOR reduction)
//
//   Thus, each ROM effectively stores the vector (L_i × S(x)) for all
//   possible byte values (x = 0..255). The eight partial 64-bit vectors
//   are XORed to form the final output.
//
// Architecture:
//   - 8 × 256×64-bit ROMs (rom0..rom7), one per byte position
//   - 1 clock-cycle synchronous pipeline
//   - Fully precomputed S×L results (no separate S-transform needed)
//
// Interface:
//   - clk, rst_n : synchronous clock and reset
//   - i_data     : 64-bit input block (8 bytes)
//   - i_valid    : input valid (asserted for one cycle)
//   - o_data     : 64-bit output block (registered, 1-cycle latency)
//   - o_valid    : output valid (aligned with o_data)
//
// Parameters:
//   - INIT_FILE_P0..P7 : initialization HEX files for ROMs (S×L precomputed tables)
//
// Notes:
//   - Each ROM is inferred as true block RAM (`(* ram_style="block" *)`).
//   - Deterministic 1-cycle latency.
//   - When using this module, DO NOT apply `s_transform` separately.
//   - Forms the core computational unit for the precomputed LS transform stage.
// -----------------------------------------------------------------------------

module ls_transform_rom #(
    parameter INIT_FILE_P0 = "../rtl/tables/rom_p0.hex",
    parameter INIT_FILE_P1 = "../rtl/tables/rom_p1.hex",
    parameter INIT_FILE_P2 = "../rtl/tables/rom_p2.hex",
    parameter INIT_FILE_P3 = "../rtl/tables/rom_p3.hex",
    parameter INIT_FILE_P4 = "../rtl/tables/rom_p4.hex",
    parameter INIT_FILE_P5 = "../rtl/tables/rom_p5.hex",
    parameter INIT_FILE_P6 = "../rtl/tables/rom_p6.hex",
    parameter INIT_FILE_P7 = "../rtl/tables/rom_p7.hex"
)(
    input  logic         clk,        // Clock
    input  logic         rst_n,      // Synchronous active-low reset

    input  logic [63:0]  i_data,     // Input 64-bit block (8 bytes)
    input  logic         i_valid,    // Input valid flag

    output logic [63:0]  o_data,     // Output 64-bit block, 1-cycle latency
    output logic         o_valid     // Output valid flag
);

// -----------------------------------------------------------------------------
// ROM Declarations
// Each ROM holds 256 entries of 64-bit precomputed vectors for one byte position.
// -----------------------------------------------------------------------------
(* ram_style = "block" *) reg [63:0] rom0 [0:255];
(* ram_style = "block" *) reg [63:0] rom1 [0:255];
(* ram_style = "block" *) reg [63:0] rom2 [0:255];
(* ram_style = "block" *) reg [63:0] rom3 [0:255];
(* ram_style = "block" *) reg [63:0] rom4 [0:255];
(* ram_style = "block" *) reg [63:0] rom5 [0:255];
(* ram_style = "block" *) reg [63:0] rom6 [0:255];
(* ram_style = "block" *) reg [63:0] rom7 [0:255];

// -----------------------------------------------------------------------------
// Initialization from external HEX files
// -----------------------------------------------------------------------------
initial begin
    $readmemh(INIT_FILE_P0, rom0);
    $readmemh(INIT_FILE_P1, rom1);
    $readmemh(INIT_FILE_P2, rom2);
    $readmemh(INIT_FILE_P3, rom3);
    $readmemh(INIT_FILE_P4, rom4);
    $readmemh(INIT_FILE_P5, rom5);
    $readmemh(INIT_FILE_P6, rom6);
    $readmemh(INIT_FILE_P7, rom7);
end

// -----------------------------------------------------------------------------
// Byte extraction from input word
// -----------------------------------------------------------------------------
logic [7:0] b0, b1, b2, b3, b4, b5, b6, b7;

assign {b7, b6, b5, b4, b3, b2, b1, b0} = i_data;

// -----------------------------------------------------------------------------
// Synchronous ROM read stage (1-cycle pipeline)
// -----------------------------------------------------------------------------
logic [63:0] r0, r1, r2, r3, r4, r5, r6, r7;

always_ff @(posedge clk) begin : proc_rom_read
    if (~rst_n) begin
        r0 <= '0; r1 <= '0; r2 <= '0; r3 <= '0;
        r4 <= '0; r5 <= '0; r6 <= '0; r7 <= '0;
    end else begin
        r0 <= rom0[b0];
        r1 <= rom1[b1];
        r2 <= rom2[b2];
        r3 <= rom3[b3];
        r4 <= rom4[b4];
        r5 <= rom5[b5];
        r6 <= rom6[b6];
        r7 <= rom7[b7];
    end
end

// -----------------------------------------------------------------------------
// Output valid pipelining
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin : proc_valid
    if (~rst_n)
        o_valid <= 1'b0;
    else
        o_valid <= i_valid;
end

// -----------------------------------------------------------------------------
// XOR accumulation of ROM outputs
// Produces final 64-bit result = r0 ⊕ r1 ⊕ ... ⊕ r7
// -----------------------------------------------------------------------------
assign o_data = r0 ^ r1 ^ r2 ^ r3 ^ r4 ^ r5 ^ r6 ^ r7;

// -----------------------------------------------------------------------------
// End of LS Transform ROM
// -----------------------------------------------------------------------------
endmodule : ls_transform_rom
