// -----------------------------------------------------------------------------
// 512-bit Adder Module
// Configurable adder implementation with optional DSP48E2 utilization.
//
// Operation:
//   - When USE_DSP = 1: Implements pipelined 512-bit addition using 11 DSP48E2
//     slices chained through carry cascade. Inputs are zero-extended to 528 bits
//     (11 × 48-bit DSP blocks) with 16-bit padding.
//   - When USE_DSP = 0: Implements combinational 512-bit addition using
//     standard logic fabric.
//
// DSP48E2 Configuration Notes:
//   - Each DSP block configured for 48-bit addition (A+B+C)
//   - A[29:0] = upper 30 bits of 48-bit slice (extended_a[i*48+18 +: 30])
//   - B[17:0] = lower 18 bits of 48-bit slice (extended_a[i*48 +: 18])
//   - C[47:0] = corresponding operand_b slice
//   - OPMODE = 9'b000110011: (P = A:B + C) with registered output
//   - ALUMODE = 4'b0000: (Z + W + X + Y + CIN) mode
//   - CARRYINSEL = 3'b010: CARRYCASCIN for chaining (except first slice)
//   - Registered on A2, B2, CREG, PREG with valid_in as clock enable
//   - Synchronous reset (active high) derived from rst_n
//
// Latency:
//   - USE_DSP = 1: 12 clock cycles from valid_in assertion to stable sum_out
//   - USE_DSP = 0: 0 cycles (combinational)
//
// Interface:
//   - clk:       System clock
//   - rst_n:     Synchronous reset (active low)
//   - valid_in:  Clock enable for pipeline registers
//   - operand_a: First 512-bit operand
//   - operand_b: Second 512-bit operand
//   - sum_out:   512-bit sum result (registered when USE_DSP=1)
//
// Timing:
//   - DSP mode: 1 cycle latency through DSP pipeline
//   - Fabric mode: 0 cycles latency (combinational)
// -----------------------------------------------------------------------------

module adder_512bit #(
    parameter USE_DSP = 1           // 1 = use DSP48E2 slices, 0 = fabric adder
)(
    input  logic         clk,       // Clock
    input  logic         rst_n,     // Synchronous reset active low
    input  logic         valid_in,  // Input valid / clock enable

    input  logic [511:0] operand_a, // First 512-bit operand
    input  logic [511:0] operand_b, // Second 512-bit operand
    output logic [511:0] sum_out    // 512-bit sum result
);

// -----------------------------------------------------------------------------
// Internal Signals Declaration
// -----------------------------------------------------------------------------
genvar i;                           // Generate loop index
logic [11:0] carry_chain;           // Carry chain between DSP slices (12 bits)
logic [527:0] extended_a;           // Zero-extended operand_a (528 bits)
logic [527:0] extended_b;           // Zero-extended operand_b (528 bits)
logic [527:0] extended_sum;         // Extended sum result (528 bits)
logic rst;                          // Active-high reset for DSP blocks

// -----------------------------------------------------------------------------
// DSP-based Implementation (USE_DSP = 1)
// -----------------------------------------------------------------------------
generate
    if (USE_DSP) begin : dsp_implementation
        // Extend inputs to 528 bits (11 DSP slices × 48 bits each)
        assign extended_a = {16'h0, operand_a};  // Zero-extend for alignment
        assign extended_b = {16'h0, operand_b};  // Zero-extend for alignment
        assign sum_out = extended_sum[511:0];    // Truncate to 512-bit result

        // Convert active-low reset to active-high for DSP blocks
        assign rst = ~rst_n;

        // ---------------------------------------------------------------------
        // Generate 11 DSP48E2 slices for 528-bit addition (48 bits each)
        // ---------------------------------------------------------------------
        for (i = 0; i < 11; i++) begin : dsp_slice_gen
            DSP48E2 #(
                // Feature Control Attributes: Data Path Selection
                .AMULTSEL("A"),                    // Selects A input to multiplier (A, AD)
                .A_INPUT("DIRECT"),                // Selects A input source, "DIRECT" (A port) or "CASCADE" (ACIN port)
                .BMULTSEL("B"),                    // Selects B input to multiplier (AD, B)
                .B_INPUT("DIRECT"),                // Selects B input source, "DIRECT" (B port) or "CASCADE" (BCIN port)
                .PREADDINSEL("A"),                 // Selects input to pre-adder (A, B)
                .RND(48'h000000000000),            // Rounding Constant
                .USE_MULT("NONE"),                 // Select multiplier usage (DYNAMIC, MULTIPLY, NONE)
                .USE_SIMD("ONE48"),                // SIMD selection (FOUR12, ONE48, TWO24)
                .USE_WIDEXOR("FALSE"),             // Use the Wide XOR function (FALSE, TRUE)
                .XORSIMD("XOR24_48_96"),           // Mode of operation for the Wide XOR (XOR12, XOR24_48_96)
                // Pattern Detector Attributes: Pattern Detection Configuration
                .AUTORESET_PATDET("NO_RESET"),     // NO_RESET, RESET_MATCH, RESET_NOT_MATCH
                .AUTORESET_PRIORITY("RESET"),      // Priority of AUTORESET vs. CEP (CEP, RESET).
                .MASK(48'h3fffffffffff),           // 48-bit mask value for pattern detect (1=ignore)
                .PATTERN(48'h000000000000),        // 48-bit pattern match for pattern detect
                .SEL_MASK("MASK"),                 // C, MASK, ROUNDING_MODE1, ROUNDING_MODE2
                .SEL_PATTERN("PATTERN"),           // Select pattern value (C, PATTERN)
                .USE_PATTERN_DETECT("NO_PATDET"),  // Enable pattern detect (NO_PATDET, PATDET)
                // Programmable Inversion Attributes: Specifies built-in programmable inversion
                .IS_ALUMODE_INVERTED(4'b0000),     // Optional inversion for ALUMODE
                .IS_CARRYIN_INVERTED(1'b0),        // Optional inversion for CARRYIN
                .IS_CLK_INVERTED(1'b0),            // Optional inversion for CLK
                .IS_INMODE_INVERTED(5'b00000),     // Optional inversion for INMODE
                .IS_OPMODE_INVERTED(9'b000000000), // Optional inversion for OPMODE
                .IS_RSTALLCARRYIN_INVERTED(1'b0),  // Optional inversion for RSTALLCARRYIN
                .IS_RSTALUMODE_INVERTED(1'b0),     // Optional inversion for RSTALUMODE
                .IS_RSTA_INVERTED(1'b0),           // Optional inversion for RSTA
                .IS_RSTB_INVERTED(1'b0),           // Optional inversion for RSTB
                .IS_RSTCTRL_INVERTED(1'b0),        // Optional inversion for RSTCTRL
                .IS_RSTC_INVERTED(1'b0),           // Optional inversion for RSTC
                .IS_RSTD_INVERTED(1'b0),           // Optional inversion for RSTD
                .IS_RSTINMODE_INVERTED(1'b0),      // Optional inversion for RSTINMODE
                .IS_RSTM_INVERTED(1'b0),           // Optional inversion for RSTM
                .IS_RSTP_INVERTED(1'b0),           // Optional inversion for RSTP
                // Register Control Attributes: Pipeline Register Configuration
                .ACASCREG(1),                      // Number of pipeline stages between A/ACIN and ACOUT (0-2)
                .ADREG(0),                         // Pipeline stages for pre-adder (0-1)
                .ALUMODEREG(0),                    // Pipeline stages for ALUMODE (0-1)
                .AREG(1),                          // Pipeline stages for A (0-2)
                .BCASCREG(1),                      // Number of pipeline stages between B/BCIN and BCOUT (0-2)
                .BREG(1),                          // Pipeline stages for B (0-2)
                .CARRYINREG(0),                    // Pipeline stages for CARRYIN (0-1)
                .CARRYINSELREG(0),                 // Pipeline stages for CARRYINSEL (0-1)
                .CREG(1),                          // Pipeline stages for C (0-1)
                .DREG(0),                          // Pipeline stages for D (0-1)
                .INMODEREG(0),                     // Pipeline stages for INMODE (0-1)
                .MREG(0),                          // Multiplier pipeline stages (0-1)
                .OPMODEREG(0),                     // Pipeline stages for OPMODE (0-1)
                .PREG(1)                           // Number of pipeline stages for P (0-1)
            )
            DSP48E2_inst (
                // Cascade outputs: Cascade Ports
                .ACOUT(),                          // 30-bit output: A port cascade
                .BCOUT(),                          // 18-bit output: B cascade
                .CARRYCASCOUT(carry_chain[i+1]),   // 1-bit output: Cascade carry
                .MULTSIGNOUT(),                    // 1-bit output: Multiplier sign cascade
                .PCOUT(),                          // 48-bit output: Cascade output
                // Control outputs: Control Inputs/Status Bits
                .OVERFLOW(),                       // 1-bit output: Overflow in add/acc
                .PATTERNBDETECT(),                 // 1-bit output: Pattern bar detect
                .PATTERNDETECT(),                  // 1-bit output: Pattern detect
                .UNDERFLOW(),                      // 1-bit output: Underflow in add/acc
                // Data outputs: Data Ports
                .CARRYOUT(),                       // 4-bit output: Carry
                .P(extended_sum[i*48 +: 48]),      // 48-bit output: Primary data (48-bit slice)
                .XOROUT(),                         // 8-bit output: XOR data
                // Cascade inputs: Cascade Ports
                .ACIN(),                           // 30-bit input: A cascade data
                .BCIN(),                           // 18-bit input: B cascade
                .CARRYCASCIN(carry_chain[i]),      // 1-bit input: Cascade carry from previous slice
                .MULTSIGNIN(),                     // 1-bit input: Multiplier sign cascade
                .PCIN(),                           // 48-bit input: P cascade
                // Control inputs: Control Inputs/Status Bits
                .ALUMODE(4'b0000),                 // 4-bit input: ALU control (Z+W+X+Y+CIN)
                .CARRYINSEL(i == 0 ? 3'b000 : 3'b010), // 3-bit input: CARRYIN source (0=const 0, 2=CARRYCASCIN)
                .CLK(clk),                         // 1-bit input: Clock
                .INMODE(5'b00000),                 // 5-bit input: INMODE control
                .OPMODE(9'b000110011),             // 9-bit input: Operation mode (P = A:B + C)
                // Data inputs: Data Ports
                .A(extended_a[i*48+18 +: 30]),     // 30-bit input: A data (upper 30 bits of slice)
                .B(extended_a[i*48 +: 18]),        // 18-bit input: B data (lower 18 bits of slice)
                .C(extended_b[i*48 +: 48]),        // 48-bit input: C data (operand_b slice)
                .CARRYIN(1'b0),                    // 1-bit input: Carry-in (unused in cascade mode)
                .D(27'h0),                         // 27-bit input: D data (unused)
                // Reset/Clock Enable inputs: Reset/Clock Enable Inputs
                .CEA1(1'b0),                       // 1-bit input: Clock enable for 1st stage AREG
                .CEA2(valid_in),                   // 1-bit input: Clock enable for 2nd stage AREG
                .CEAD(1'b0),                       // 1-bit input: Clock enable for ADREG
                .CEALUMODE(1'b0),                  // 1-bit input: Clock enable for ALUMODE
                .CEB1(1'b0),                       // 1-bit input: Clock enable for 1st stage BREG
                .CEB2(valid_in),                   // 1-bit input: Clock enable for 2nd stage BREG
                .CEC(valid_in),                    // 1-bit input: Clock enable for CREG
                .CECARRYIN(1'b0),                  // 1-bit input: Clock enable for CARRYINREG
                .CECTRL(1'b0),                     // 1-bit input: Clock enable for OPMODEREG and CARRYINSELREG
                .CED(1'b0),                        // 1-bit input: Clock enable for DREG
                .CEINMODE(1'b0),                   // 1-bit input: Clock enable for INMODEREG
                .CEM(1'b0),                        // 1-bit input: Clock enable for MREG
                .CEP(1'b1),                        // 1-bit input: Clock enable for PREG
                .RSTA(rst),                        // 1-bit input: Reset for AREG
                .RSTALLCARRYIN(rst),               // 1-bit input: Reset for CARRYINREG
                .RSTALUMODE(1'b0),                 // 1-bit input: Reset for ALUMODEREG
                .RSTB(rst),                        // 1-bit input: Reset for BREG
                .RSTC(rst),                        // 1-bit input: Reset for CREG
                .RSTCTRL(1'b0),                    // 1-bit input: Reset for OPMODEREG and CARRYINSELREG
                .RSTD(1'b0),                       // 1-bit input: Reset for DREG and ADREG
                .RSTINMODE(1'b0),                  // 1-bit input: Reset for INMODEREG
                .RSTM(1'b0),                       // 1-bit input: Reset for MREG
                .RSTP(rst)                         // 1-bit input: Reset for PREG
            );
        end
    end else begin : fabric_implementation
        // ---------------------------------------------------------------------
        // Fabric Implementation (USE_DSP = 0)
        // Simple combinational 512-bit adder using logic fabric
        // Latency: 0 cycles (pure combinational)
        // ---------------------------------------------------------------------
        assign sum_out = operand_a + operand_b;
    end
endgenerate

// -----------------------------------------------------------------------------
// End of Adder 512-bit
// -----------------------------------------------------------------------------
endmodule : adder_512bit
