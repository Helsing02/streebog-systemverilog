`timescale 1ns / 1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Testbench for p_transform
// Verifies byte-level permutation correctness with sequential and random inputs.
// -----------------------------------------------------------------------------
module tb_p_transform;

// -----------------------------------------------------------------------------
// DUT I/O
// -----------------------------------------------------------------------------
logic [511:0] i_data;
logic [511:0] o_data;
logic [511:0] expected;

// Statistics
int total_tests = 0;
int errors = 0;

// -----------------------------------------------------------------------------
// DUT Instance
// -----------------------------------------------------------------------------
p_transform dut (
    .i_data(i_data),
    .o_data(o_data)
);

// -----------------------------------------------------------------------------
// Reference model
// -----------------------------------------------------------------------------
function automatic [511:0] ref_p_transform(input [511:0] data);
    for (int i = 0; i < 64; i++) begin
        int src_idx = (i * 8 + i / 8) % 64;
        ref_p_transform[i*8 +: 8] = data[src_idx*8 +: 8];
    end
endfunction : ref_p_transform


// -----------------------------------------------------------------------------
// Common check task
// -----------------------------------------------------------------------------
task automatic check_result(string name);
    expected = ref_p_transform(i_data);
    #10;
    total_tests++;
    if (o_data !== expected) begin
        errors++;
        $display("[FAIL] %s", name);
        for (int i = 0; i < 64; i++) begin
            if (o_data[i*8 +: 8] !== expected[i*8 +: 8]) begin
                $display("  Byte[%0d]: expected %02h, got %02h",
                         i, expected[i*8 +: 8], o_data[i*8 +: 8]);
            end
        end
    end else begin
        $display("[PASS] %s", name);
    end
endtask : check_result

// -----------------------------------------------------------------------------
// Test: sequential bytes (0..63)
// -----------------------------------------------------------------------------
task automatic test_sequential();
    for (int i = 0; i < 64; i++)
        i_data[i*8 +: 8] = i[7:0];
    check_result("Sequential pattern");
endtask : test_sequential

// -----------------------------------------------------------------------------
// Test: all bytes equal (uniform)
// -----------------------------------------------------------------------------
task automatic test_uniform();
    for (int val = 0; val < 4; val++) begin
        i_data = {64{8'(val * 8'h11)}}; // 0x00, 0x11, 0x22, 0x33
        check_result($sformatf("Uniform pattern 0x%02h", val * 8'h11));
    end
endtask : test_uniform

// -----------------------------------------------------------------------------
// Test: random inputs (coverage sweep)
// -----------------------------------------------------------------------------
task automatic test_random(int num = 10);
    for (int n = 0; n < num; n++) begin
        i_data = $urandom();
        repeat (15) i_data = {i_data, $urandom()}; // fill all 512 bits
        check_result($sformatf("Random #%0d", n));
    end
endtask : test_random

// -----------------------------------------------------------------------------
// Main test sequence
// -----------------------------------------------------------------------------
initial begin
    $display("\n=== P Transform Testbench ===");

    test_sequential();
    test_uniform();
    test_random(10);

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

// -----------------------------------------------------------------------------
// Optional checks
// -----------------------------------------------------------------------------
always @(o_data) begin
    if (^o_data === 1'bx)
        $warning("Output contains X/Z at time %0t", $time);
end

endmodule : tb_p_transform

`default_nettype wire
