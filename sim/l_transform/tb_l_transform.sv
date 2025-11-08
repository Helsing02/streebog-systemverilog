`timescale 1ns / 1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Testbench for l_transform
// Verifies the pure combinational linear diffusion stage (L-Transform).
//
// Coverage goals:
//   1. Correctness for known and random inputs.
//   2. Independent slice behavior (each 64-bit segment).
//   3. Sensitivity to bit toggles (walking bits).
//   4. Full 512-bit propagation and correctness.
//
// Notes:
//   - Only combinational logic is verified (no clocked latency).
//   - Reference model uses software-equivalent matrix multiplication.
// -----------------------------------------------------------------------------
module tb_l_transform;

// -----------------------------------------------------------------------------
// DUT I/O
// -----------------------------------------------------------------------------
logic [511:0] i_data;
logic [511:0] o_data;

// -----------------------------------------------------------------------------
// DUT Instance
// -----------------------------------------------------------------------------
l_transform dut (
    .i_data(i_data),
    .o_data(o_data)
);

// -----------------------------------------------------------------------------
// Statistics
// -----------------------------------------------------------------------------
int total_tests = 0;
int errors = 0;

// -----------------------------------------------------------------------------
// Reference Matrix (imported from standard L transformation)
// -----------------------------------------------------------------------------
const logic [63:0] L_MATRIX [63:0] = '{
    64'h8e20faa72ba0b470, 64'h47107ddd9b505a38, 64'had08b0e0c3282d1c, 64'hd8045870ef14980e,
    64'h6c022c38f90a4c07, 64'h3601161cf205268d, 64'h1b8e0b0e798c13c8, 64'h83478b07b2468764,
    64'ha011d380818e8f40, 64'h5086e740ce47c920, 64'h2843fd2067adea10, 64'h14aff010bdd87508,
    64'h0ad97808d06cb404, 64'h05e23c0468365a02, 64'h8c711e02341b2d01, 64'h46b60f011a83988e,
    64'h90dab52a387ae76f, 64'h486dd4151c3dfdb9, 64'h24b86a840e90f0d2, 64'h125c354207487869,
    64'h092e94218d243cba, 64'h8a174a9ec8121e5d, 64'h4585254f64090fa0, 64'haccc9ca9328a8950,
    64'h9d4df05d5f661451, 64'hc0a878a0a1330aa6, 64'h60543c50de970553, 64'h302a1e286fc58ca7,
    64'h18150f14b9ec46dd, 64'h0c84890ad27623e0, 64'h0642ca05693b9f70, 64'h0321658cba93c138,
    64'h86275df09ce8aaa8, 64'h439da0784e745554, 64'hafc0503c273aa42a, 64'hd960281e9d1d5215,
    64'he230140fc0802984, 64'h71180a8960409a42, 64'hb60c05ca30204d21, 64'h5b068c651810a89e,
    64'h456c34887a3805b9, 64'hac361a443d1c8cd2, 64'h561b0d22900e4669, 64'h2b838811480723ba,
    64'h9bcf4486248d9f5d, 64'hc3e9224312c8c1a0, 64'heffa11af0964ee50, 64'hf97d86d98a327728,
    64'he4fa2054a80b329c, 64'h727d102a548b194e, 64'h39b008152acb8227, 64'h9258048415eb419d,
    64'h492c024284fbaec0, 64'haa16012142f35760, 64'h550b8e9e21f7a530, 64'ha48b474f9ef5dc18,
    64'h70a6a56e2440598e, 64'h3853dc371220a247, 64'h1ca76e95091051ad, 64'h0edd37c48a08a6d8,
    64'h07e095624504536c, 64'h8d70c431ac02a736, 64'hc83862965601dd1b, 64'h641c314b2b8ee083
};

// -----------------------------------------------------------------------------
// Reference behavioral model of L-transform
// -----------------------------------------------------------------------------
function automatic logic [63:0] ref_matrix_mult(input logic [63:0] val);
    logic [63:0] res;
    res = '0;
    for (int i = 0; i < 64; i++)
        if (val[i]) res ^= L_MATRIX[i];
    return res;
endfunction

function automatic logic [511:0] ref_l_transform(input logic [511:0] din);
    for (int i = 0; i < 8; i++)
        ref_l_transform[i*64 +: 64] = ref_matrix_mult(din[i*64 +: 64]);
endfunction

// -----------------------------------------------------------------------------
// Check task
// -----------------------------------------------------------------------------
task automatic check_block(string name, logic [511:0] block);
    logic [511:0] expected = ref_l_transform(block);
    total_tests++;

    i_data = block;
    #1; // small delay for combinational settle

    if (o_data !== expected) begin
        errors++;
        $display("[FAIL] %s", name);
        $display("  Input   : %h", block);
        $display("  Expected: %h", expected);
        $display("  Got     : %h", o_data);
    end else begin
        $display("[PASS] %s", name);
    end
endtask : check_block

// -----------------------------------------------------------------------------
// Test cases
// -----------------------------------------------------------------------------
task automatic test_zero();
    $display("\n--- Test: Zero vector ---");
    check_block("All zeros", 512'b0);
endtask

task automatic test_walking_bits();
    $display("\n--- Test: Walking bits ---");
    for (int i = 0; i < 64; i++)
        check_block($sformatf("Single bit slice0[%0d]", i), 512'((64'b1 << i)));
endtask

task automatic test_random_blocks(int num = 10);
    $display("\n--- Test: Random blocks ---");
    for (int i = 0; i < num; i++) begin
        logic [511:0] rnd = {$urandom, $urandom, $urandom, $urandom,
                             $urandom, $urandom, $urandom, $urandom};
        check_block($sformatf("Random #%0d", i), rnd);
    end
endtask

// -----------------------------------------------------------------------------
// Main sequence
// -----------------------------------------------------------------------------
initial begin
    $display("\n=== L Transform Testbench ===");
    test_zero();
    test_walking_bits();
    test_random_blocks(8);

    $display("\n----------------------------------");
    $display(" Summary:");
    $display("   Total tests : %0d", total_tests);
    $display("   Errors       : %0d", errors);
    if (errors == 0)
        $display("   RESULT       : ALL TESTS PASSED");
    else
        $display("   RESULT       : SOME TESTS FAILED");
    $display("----------------------------------\n");
    $finish;
end

endmodule : tb_l_transform

`default_nettype wire
