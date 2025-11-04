`timescale 1ns / 1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Testbench for matrix_multiplication
// Verifies correctness of 64×64 binary matrix multiplication in GF(2).
//
// Test strategy:
//   1. Zero input       → Expect zero output
//   2. Single-bit tests → Each bit selects one matrix row
//   3. Random vectors   → Cross-verifies full XOR accumulation logic
//
// Notes:
//   - Uses combinational DUT, zero-latency verification.
//   - Reference model: direct row-XOR accumulation (software equivalent).
// -----------------------------------------------------------------------------
module tb_matrix_multiplication;

localparam int ROUNDS = 100;

// -----------------------------------------------------------------------------
// DUT I/O
// -----------------------------------------------------------------------------
logic [63:0] i_data;
logic [63:0] o_data;
logic [63:0] expected;

// Statistics
int total_tests = 0;
int errors = 0;

// -----------------------------------------------------------------------------
// DUT Instance
// -----------------------------------------------------------------------------
matrix_multiplication dut (
    .i_data(i_data),
    .o_data(o_data)
);

// -----------------------------------------------------------------------------
// Reference Matrix (duplicated from DUT for test clarity)
// Each row defines 64-bit output contribution for a single input bit.
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
// Reference Model
// Direct GF(2) matrix multiplication implemented as XOR over selected rows.
// -----------------------------------------------------------------------------
function automatic logic [63:0] ref_matrix_mult(input logic [63:0] val);
    logic [63:0] res;
    res = 64'b0;
    for (int i = 0; i < 64; i++)
        if (val[i])
            res ^= L_MATRIX[i];
    return res;
endfunction

// -----------------------------------------------------------------------------
// Common Check Task
// -----------------------------------------------------------------------------
task automatic check_result(string name);
    #1;
    total_tests++;
    expected = ref_matrix_mult(i_data);
    if (o_data !== expected) begin
        errors++;
        $display("[FAIL] %s", name);
        $display("  Input:    %h", i_data);
        $display("  Expected: %h", expected);
        $display("  Got:      %h", o_data);
    end else begin
        $display("[PASS] %s", name);
    end
endtask

// -----------------------------------------------------------------------------
// Test: All-Zero Input
// Ensures that matrix multiplication with zero vector produces zero result.
// -----------------------------------------------------------------------------
task automatic test_zero_input();
    i_data = 64'b0;
    check_result("All-zero input");
endtask

// -----------------------------------------------------------------------------
// Test: Single-Bit Inputs
// Verifies that each input bit selects its corresponding matrix row exactly.
// -----------------------------------------------------------------------------
task automatic test_single_bit_inputs();
    for (int i = 0; i < 64; i++) begin
        i_data = 64'b1 << i;
        expected = L_MATRIX[i];
        #1;
        total_tests++;
        if (o_data !== expected) begin
            errors++;
            $display("[FAIL] Single bit #%0d", i);
            $display("  Expected: %h", expected);
            $display("  Got:      %h", o_data);
        end else begin
            $display("[PASS] Single bit #%0d", i);
        end
    end
endtask

// -----------------------------------------------------------------------------
// Test: Repeated Byte Patterns
// Ensures that uniform and low-entropy inputs produce deterministic outputs.
// -----------------------------------------------------------------------------
task automatic test_byte_patterns();
    for (int val = 0; val < 8; val++) begin
        logic [7:0] byte_val = (val * 8) & 8'hFF;
        i_data = {8{byte_val}}; // replicate byte pattern
        check_result($sformatf("Byte-repeat pattern val=0x%02h", byte_val));
    end
endtask : test_byte_patterns

// -----------------------------------------------------------------------------
// Test: Random Vectors
// Verifies correctness under multiple random combinations of input bits.
// -----------------------------------------------------------------------------
task automatic test_random_vectors(int num);
    for (int n = 0; n < num; n++) begin
        i_data = {$urandom, $urandom};
        check_result($sformatf("Random vector #%0d", n));
    end
endtask

// -----------------------------------------------------------------------------
// Main Test Sequence
// -----------------------------------------------------------------------------
initial begin
    $display("\n=== Matrix Multiplication Testbench ===");

    test_zero_input();
    test_single_bit_inputs();
    test_byte_patterns();
    test_random_vectors(ROUNDS);

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

endmodule : tb_matrix_multiplication
`default_nettype wire
