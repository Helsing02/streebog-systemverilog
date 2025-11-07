`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// Testbench for LS Transform ROM
// ----------------------------------------------------------------------------
// Purpose:
//   Functional verification of the combined precomputed S+L transform stage
//   implemented via ROM lookup.
//
// Verification Goals:
//   - Verify correct ROM addressing per byte position.
//   - Confirm proper synchronous 1-cycle pipeline behavior.
//   - Check deterministic XOR accumulation across ROM outputs.
//   - Validate output against software-equivalent S→L reference model.
//
// Coverage Focus:
//   - Zero vector check.
//   - Walking bit patterns (structural sensitivity).
//   - Randomized 64-bit inputs (statistical correctness).
//
// Reference:
//   The testbench explicitly performs S-box substitution + GF(2) matrix multiply
//   to produce the expected result, ensuring independence from DUT’s ROM content.
//
// DUT: ls_transform_rom
// ============================================================================
module tb_ls_transform_rom;

localparam CLK_PERIOD = 10ns;
localparam integer NUM_RANDOM_TESTS = 32;

// -----------------------------------------------------------------------------
// DUT I/O
// -----------------------------------------------------------------------------
logic clk;
logic rst_n;
logic [63:0] i_data;
logic i_valid;
logic [63:0] o_data;
logic o_valid;

// Statistics
int total_tests = 0;
int errors = 0;

// -----------------------------------------------------------------------------
// Clock generation
// -----------------------------------------------------------------------------
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// -----------------------------------------------------------------------------
// DUT instantiation
// -----------------------------------------------------------------------------
ls_transform_rom #(
    .INIT_FILE_P0("../rtl/tables/rom_p0.hex"),
    .INIT_FILE_P1("../rtl/tables/rom_p1.hex"),
    .INIT_FILE_P2("../rtl/tables/rom_p2.hex"),
    .INIT_FILE_P3("../rtl/tables/rom_p3.hex"),
    .INIT_FILE_P4("../rtl/tables/rom_p4.hex"),
    .INIT_FILE_P5("../rtl/tables/rom_p5.hex"),
    .INIT_FILE_P6("../rtl/tables/rom_p6.hex"),
    .INIT_FILE_P7("../rtl/tables/rom_p7.hex")
) dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .i_data  (i_data),
    .i_valid (i_valid),
    .o_data  (o_data),
    .o_valid (o_valid)
);

// -----------------------------------------------------------------------------
// Reference S-box (as used in ROM generation)
// -----------------------------------------------------------------------------
const logic [7:0] SBOX_REF [0:255] = '{
    8'hFC,8'hEE,8'hDD,8'h11,8'hCF,8'h6E,8'h31,8'h16,8'hFB,8'hC4,8'hFA,8'hDA,8'h23,8'hC5,8'h04,8'h4D,
    8'hE9,8'h77,8'hF0,8'hDB,8'h93,8'h2E,8'h99,8'hBA,8'h17,8'h36,8'hF1,8'hBB,8'h14,8'hCD,8'h5F,8'hC1,
    8'hF9,8'h18,8'h65,8'h5A,8'hE2,8'h5C,8'hEF,8'h21,8'h81,8'h1C,8'h3C,8'h42,8'h8B,8'h01,8'h8E,8'h4F,
    8'h05,8'h84,8'h02,8'hAE,8'hE3,8'h6A,8'h8F,8'hA0,8'h06,8'h0B,8'hED,8'h98,8'h7F,8'hD4,8'hD3,8'h1F,
    8'hEB,8'h34,8'h2C,8'h51,8'hEA,8'hC8,8'h48,8'hAB,8'hF2,8'h2A,8'h68,8'hA2,8'hFD,8'h3A,8'hCE,8'hCC,
    8'hB5,8'h70,8'h0E,8'h56,8'h08,8'h0C,8'h76,8'h12,8'hBF,8'h72,8'h13,8'h47,8'h9C,8'hB7,8'h5D,8'h87,
    8'h15,8'hA1,8'h96,8'h29,8'h10,8'h7B,8'h9A,8'hC7,8'hF3,8'h91,8'h78,8'h6F,8'h9D,8'h9E,8'hB2,8'hB1,
    8'h32,8'h75,8'h19,8'h3D,8'hFF,8'h35,8'h8A,8'h7E,8'h6D,8'h54,8'hC6,8'h80,8'hC3,8'hBD,8'h0D,8'h57,
    8'hDF,8'hF5,8'h24,8'hA9,8'h3E,8'hA8,8'h43,8'hC9,8'hD7,8'h79,8'hD6,8'hF6,8'h7C,8'h22,8'hB9,8'h03,
    8'hE0,8'h0F,8'hEC,8'hDE,8'h7A,8'h94,8'hB0,8'hBC,8'hDC,8'hE8,8'h28,8'h50,8'h4E,8'h33,8'h0A,8'h4A,
    8'hA7,8'h97,8'h60,8'h73,8'h1E,8'h00,8'h62,8'h44,8'h1A,8'hB8,8'h38,8'h82,8'h64,8'h9F,8'h26,8'h41,
    8'hAD,8'h45,8'h46,8'h92,8'h27,8'h5E,8'h55,8'h2F,8'h8C,8'hA3,8'hA5,8'h7D,8'h69,8'hD5,8'h95,8'h3B,
    8'h07,8'h58,8'hB3,8'h40,8'h86,8'hAC,8'h1D,8'hF7,8'h30,8'h37,8'h6B,8'hE4,8'h88,8'hD9,8'hE7,8'h89,
    8'hE1,8'h1B,8'h83,8'h49,8'h4C,8'h3F,8'hF8,8'hFE,8'h8D,8'h53,8'hAA,8'h90,8'hCA,8'hD8,8'h85,8'h61,
    8'h20,8'h71,8'h67,8'hA4,8'h2D,8'h2B,8'h09,8'h5B,8'hCB,8'h9B,8'h25,8'hD0,8'hBE,8'hE5,8'h6C,8'h52,
    8'h59,8'hA6,8'h74,8'hD2,8'hE6,8'hF4,8'hB4,8'hC0,8'hD1,8'h66,8'hAF,8'hC2,8'h39,8'h4B,8'h63,8'hB6
};

// -----------------------------------------------------------------------------
// Reference L-matrix (as used in LS transform definition)
// -----------------------------------------------------------------------------
const logic [63:0] L_MATRIX [63:0] = '{
    64'h8e20faa72ba0b470,64'h47107ddd9b505a38,64'had08b0e0c3282d1c,64'hd8045870ef14980e,
    64'h6c022c38f90a4c07,64'h3601161cf205268d,64'h1b8e0b0e798c13c8,64'h83478b07b2468764,
    64'ha011d380818e8f40,64'h5086e740ce47c920,64'h2843fd2067adea10,64'h14aff010bdd87508,
    64'h0ad97808d06cb404,64'h05e23c0468365a02,64'h8c711e02341b2d01,64'h46b60f011a83988e,
    64'h90dab52a387ae76f,64'h486dd4151c3dfdb9,64'h24b86a840e90f0d2,64'h125c354207487869,
    64'h092e94218d243cba,64'h8a174a9ec8121e5d,64'h4585254f64090fa0,64'haccc9ca9328a8950,
    64'h9d4df05d5f661451,64'hc0a878a0a1330aa6,64'h60543c50de970553,64'h302a1e286fc58ca7,
    64'h18150f14b9ec46dd,64'h0c84890ad27623e0,64'h0642ca05693b9f70,64'h0321658cba93c138,
    64'h86275df09ce8aaa8,64'h439da0784e745554,64'hafc0503c273aa42a,64'hd960281e9d1d5215,
    64'he230140fc0802984,64'h71180a8960409a42,64'hb60c05ca30204d21,64'h5b068c651810a89e,
    64'h456c34887a3805b9,64'hac361a443d1c8cd2,64'h561b0d22900e4669,64'h2b838811480723ba,
    64'h9bcf4486248d9f5d,64'hc3e9224312c8c1a0,64'heffa11af0964ee50,64'hf97d86d98a327728,
    64'he4fa2054a80b329c,64'h727d102a548b194e,64'h39b008152acb8227,64'h9258048415eb419d,
    64'h492c024284fbaec0,64'haa16012142f35760,64'h550b8e9e21f7a530,64'ha48b474f9ef5dc18,
    64'h70a6a56e2440598e,64'h3853dc371220a247,64'h1ca76e95091051ad,64'h0edd37c48a08a6d8,
    64'h07e095624504536c,64'h8d70c431ac02a736,64'hc83862965601dd1b,64'h641c314b2b8ee083
};

// -----------------------------------------------------------------------------
// Reference software-equivalent LS-transform model
// -----------------------------------------------------------------------------
function automatic logic [63:0] ref_ls_transform(input logic [63:0] val);
    logic [63:0] res = '0;
    logic [63:0] sboxed = '0;
    // Apply S-box per byte
    for (int i = 0; i < 8; i++)
        sboxed[i*8 +: 8] = SBOX_REF[val[i*8 +: 8]];
    // Apply matrix multiplication (GF(2))
    for (int i = 0; i < 64; i++)
        if (sboxed[i])
            res ^= L_MATRIX[i];
    return res;
endfunction

// -----------------------------------------------------------------------------
// Check procedure (accounts for 1-cycle latency)
// -----------------------------------------------------------------------------
task automatic check_result(string name, logic [63:0] in_val);
    logic [63:0] expected = ref_ls_transform(in_val);
    i_data  = in_val;
    i_valid = 1;
    @(posedge clk);
    i_valid = 0;
    @(posedge clk); // wait for registered output
    total_tests++;
    if (o_valid !== 1'b1 || o_data !== expected) begin
        errors++;
        $display("[FAIL] %s", name);
        $display("  Input   : %h", in_val);
        $display("  Expected: %h", expected);
        $display("  Got     : %h (valid=%0b)", o_data, o_valid);
    end else begin
        $display("[PASS] %s", name);
    end
endtask

// -----------------------------------------------------------------------------
// Reset sequence
// -----------------------------------------------------------------------------
task automatic apply_reset();
    rst_n = 0;
    i_data = 0;
    i_valid = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
endtask

// -----------------------------------------------------------------------------
// TEST CASES
// -----------------------------------------------------------------------------

// Case 1: Zero vector
task automatic test_zero();
    $display("\n[CASE] Zero Input");
    check_result("All zeros", 64'b0);
endtask

// Case 2: Walking bit pattern
task automatic test_walking_bits();
    $display("\n[CASE] Walking Bits");
    for (int i = 0; i < 64; i++)
        check_result($sformatf("Single bit %0d", i), 64'b1 << i);
endtask

// Case 3: Random vectors
task automatic test_random_vectors(int num = 10);
    $display("\n[CASE] Random Vectors");
    for (int n = 0; n < num; n++) begin
        logic [63:0] rand_val = {$urandom, $urandom};
        check_result($sformatf("Random #%0d", n), rand_val);
    end
endtask

// Case 4: Byte repetition patterns
task automatic test_byte_repeat();
    $display("\n[CASE] Byte-Repetition Patterns");
    for (int val = 0; val < 16; val++) begin
        logic [7:0] b = val * 8;
        logic [63:0] pattern = {8{b}};
        check_result($sformatf("Byte repeat 0x%02h", b), pattern);
    end
endtask

// -----------------------------------------------------------------------------
// Main test sequence
// -----------------------------------------------------------------------------
initial begin
    $display("\n=== LS Transform ROM Testbench ===");
    apply_reset();

    test_zero();
    test_walking_bits();
    test_byte_repeat();
    test_random_vectors(NUM_RANDOM_TESTS);

    $display("\n----------------------------------");
    $display(" Summary:");
    $display("   Total tests : %0d", total_tests);
    $display("   Errors      : %0d", errors);
    if (errors == 0)
        $display("   RESULT      : ALL TESTS PASSED");
    else
        $display("   RESULT      : SOME TESTS FAILED");
    $display("----------------------------------\n");
    $finish;
end

endmodule : tb_ls_transform_rom

`default_nettype wire
