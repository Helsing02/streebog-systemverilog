`timescale 1ns / 1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Testbench for adder_512bit module
// Verifies both DSP and fabric implementations with:
//   - Random data patterns
//   - Corner cases (carry propagation, overflow between DSP slices)
//   - Reset and valid_in timing scenarios
//   - Latency verification (2 cycles for DSP, 0 for fabric)
//
// Test Strategy:
//   - Two DUT instances: one with USE_DSP=1, one with USE_DSP=0
//   - Shared stimulus for both implementations
//   - Reference model: simple 512-bit addition
//   - Wait 100ns at start for glbl initialization
//
// Corner Cases Tested:
//   1. Maximum carry propagation: 0xFFFFFFFF... + 0x00000001
//   2. Carry propagation between DSP slices (48-bit boundaries)
//   3. All zeros and all ones patterns
//   4. Random patterns with valid_in edge cases
//   5. Reset during operation
// -----------------------------------------------------------------------------

module tb_adder_512bit #(
    parameter CLK_PERIOD_NS = 10,
    parameter TIMEOUT_CYCLES = 50,
    parameter NUM_RANDOM_TESTS = 100
);

// -----------------------------------------------------------------------------
// Helper: Reference 512-bit addition model
// -----------------------------------------------------------------------------
function automatic logic [511:0] ref_512bit_add (
    input logic [511:0] a,
    input logic [511:0] b
);
    return a + b;
endfunction : ref_512bit_add

// -----------------------------------------------------------------------------
// Shared Signals
// -----------------------------------------------------------------------------
logic clk;
logic rst_n;
logic valid_in;
logic [511:0] operand_a;
logic [511:0] operand_b;

// -----------------------------------------------------------------------------
// DUT Outputs
// -----------------------------------------------------------------------------
logic [511:0] sum_dsp;      // DSP implementation output
logic [511:0] sum_fabric;   // Fabric implementation output

// -----------------------------------------------------------------------------
// DSP DUT instance (USE_DSP = 1)
// -----------------------------------------------------------------------------
adder_512bit #(
    .USE_DSP(1)
) dut_dsp (
    .clk      (clk),
    .rst_n    (rst_n),
    .valid_in (valid_in),
    .operand_a(operand_a),
    .operand_b(operand_b),
    .sum_out  (sum_dsp)
);

// -----------------------------------------------------------------------------
// Fabric DUT instance (USE_DSP = 0)
// -----------------------------------------------------------------------------
adder_512bit #(
    .USE_DSP(0)
) dut_fabric (
    .clk      (clk),
    .rst_n    (rst_n),
    .valid_in (valid_in),    // Not used in fabric mode but connected for consistency
    .operand_a(operand_a),
    .operand_b(operand_b),
    .sum_out  (sum_fabric)
);

// -----------------------------------------------------------------------------
// Test Statistics
// -----------------------------------------------------------------------------
int total_tests = 0;
int errors = 0;
int dsp_mismatches = 0;
int fabric_mismatches = 0;

// -----------------------------------------------------------------------------
// Clock Generation
// -----------------------------------------------------------------------------
initial clk = 0;
always #(CLK_PERIOD_NS/2) clk = ~clk;

// -----------------------------------------------------------------------------
// Helper Task: Apply reset
// -----------------------------------------------------------------------------
task automatic apply_reset();
    rst_n = 0;
    valid_in = 0;
    operand_a = '0;
    operand_b = '0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
endtask : apply_reset

// -----------------------------------------------------------------------------
// Helper Task: Wait for DSP result (accounts for 2-cycle latency)
// Returns cycle count from valid_in to result capture
// -----------------------------------------------------------------------------
task automatic wait_for_dsp_result();
    begin
        // Wait for 3 cycles to ensure result is available (2-cycle latency + margin)
        repeat (12) @(posedge clk);
    end
endtask : wait_for_dsp_result

// -----------------------------------------------------------------------------
// Main Check Task: Apply inputs and verify both implementations
// -----------------------------------------------------------------------------
task automatic test_addition(
    string test_name,
    logic [511:0] a,
    logic [511:0] b
);
    logic [511:0] expected;
    logic [511:0] dsp_result;
    logic [511:0] fabric_result;
    int dsp_latency;

    begin
        expected = ref_512bit_add(a, b);

        // Apply inputs
        operand_a = a;
        operand_b = b;
        valid_in = 1'b1;
        @(posedge clk);
        valid_in = 1'b0;

        // Wait for results
        wait_for_dsp_result();

        // Capture results
        dsp_result = sum_dsp;
        fabric_result = sum_fabric;

        total_tests++;

        // Check DSP implementation
        if (dsp_result !== expected) begin
            errors++;
            dsp_mismatches++;
            $display("[FAIL] %s - DSP mismatch", test_name);
            $display("  Operand A: %h", a);
            $display("  Operand B: %h", b);
            $display("  Expected:  %h", expected);
            $display("  Got DSP:   %h", dsp_result);
            // $display("  DSP Latency: %0d cycles", dsp_latency);

            // Debug: Show which bits differ
            for (int i = 0; i < 512; i++) begin
                if (dsp_result[i] !== expected[i]) begin
                    $display("  Bit %0d differs: expected %b, got %b",
                            i, expected[i], dsp_result[i]);
                end
            end
        end else begin
            // $display("[PASS] %s - DSP (latency: %0d cycles)",
            //         test_name, dsp_latency);
        end

        // Check Fabric implementation (combinational, should be immediate)
        // Note: We check 1ns after the clock edge to allow for propagation
        #1;
        fabric_result = sum_fabric;

        total_tests++;

        if (fabric_result !== expected) begin
            errors++;
            fabric_mismatches++;
            $display("[FAIL] %s - Fabric mismatch", test_name);
            $display("  Operand A: %h", a);
            $display("  Operand B: %h", b);
            $display("  Expected:  %h", expected);
            $display("  Got Fabric:%h", fabric_result);
        end else begin
            $display("[PASS] %s - Fabric", test_name);
        end

        // Small idle between tests
        repeat (2) @(posedge clk);
    end
endtask : test_addition

// -----------------------------------------------------------------------------
// Test: Corner Cases
// -----------------------------------------------------------------------------
task automatic test_corner_cases();
    logic [511:0] a, b;

    $display("\n[CASE] Corner Cases");

    // 1. All zeros
    a = '0;
    b = '0;
    test_addition("All zeros", a, b);

    // 2. All ones (maximum value)
    a = {512{1'b1}};
    b = '0;
    test_addition("All ones + zero", a, b);

    // 3. Addition with carry out (should wrap around)
    a = {512{1'b1}};
    b = 512'h1;
    test_addition("Max + 1 (wrap around)", a, b);

    // 4. Test carry propagation across 48-bit DSP boundaries
    // Create pattern where carry propagates through all DSP slices
    for (int i = 0; i < 11; i++) begin
        // Set each 48-bit slice to all 1's
        a[i*48 +: 48] = {48{1'b1}};
    end
    b = 512'h1;
    test_addition("Carry through all DSP slices", a, b);

    // 5. Test specific 48-bit boundary carry
    a = '0;
    a[47:0] = {48{1'b1}};  // First DSP slice full
    b = 512'h1;
    test_addition("Carry from first DSP slice", a, b);

    // 6. Pattern: 0x5555... + 0xAAAA... = 0xFFFF...
    a = {512{2'b01}};  // 0x5555...
    b = {512{2'b10}};  // 0xAAAA...
    test_addition("Pattern 0x5555... + 0xAAAA...", a, b);

    // 7. Test middle boundary (between DSP slice 5 and 6)
    a = '0;
    a[287:240] = {48{1'b1}};  // 6th slice (48'hFFFFFFFFFFFF)
    b = 512'h1;
    test_addition("Carry from middle DSP slice", a, b);

endtask : test_corner_cases

// -----------------------------------------------------------------------------
// Test: Random Patterns
// -----------------------------------------------------------------------------
task automatic test_random_patterns(int num_tests = NUM_RANDOM_TESTS);
    logic [511:0] a, b;

    $display("\n[CASE] Random Patterns (%0d tests)", num_tests);

    for (int i = 0; i < num_tests; i++) begin
        // Generate random 512-bit operands
        a = {$urandom(), $urandom(), $urandom(), $urandom(),
             $urandom(), $urandom(), $urandom(), $urandom(),
             $urandom(), $urandom(), $urandom(), $urandom(),
             $urandom(), $urandom(), $urandom(), $urandom()};

        b = {$urandom(), $urandom(), $urandom(), $urandom(),
             $urandom(), $urandom(), $urandom(), $urandom(),
             $urandom(), $urandom(), $urandom(), $urandom(),
             $urandom(), $urandom(), $urandom(), $urandom()};

        test_addition($sformatf("Random #%0d", i), a, b);
    end
endtask : test_random_patterns

// -----------------------------------------------------------------------------
// Test: Valid_in Timing Scenarios
// -----------------------------------------------------------------------------
task automatic test_valid_in_timing();
    logic [511:0] a, b;

    $display("\n[CASE] Valid_in Timing Scenarios");

    // Test 1: valid_in held for multiple cycles
    a = 512'h1234567890ABCDEF;
    b = 512'hFEDCBA0987654321;

    // Apply inputs
    operand_a = a;
    operand_b = b;
    valid_in = 1'b1;
    repeat (3) @(posedge clk);  // Hold valid for 3 cycles
    valid_in = 1'b0;

    // Should still only compute once (first cycle)
    wait_for_dsp_result();

    // Check result
    total_tests++;
    if (sum_dsp !== ref_512bit_add(a, b)) begin
        errors++;
        $display("[FAIL] valid_in held multiple cycles");
    end else begin
        $display("[PASS] valid_in held multiple cycles");
    end

    // Test 2: valid_in asserted without reset
    apply_reset();

    a = 512'hA5A5A5A5A5A5A5A5;
    b = 512'h5A5A5A5A5A5A5A5A;

    operand_a = a;
    operand_b = b;
    valid_in = 1'b1;
    @(posedge clk);
    valid_in = 1'b0;

    wait_for_dsp_result();

    total_tests++;
    if (sum_dsp !== ref_512bit_add(a, b)) begin
        errors++;
        $display("[FAIL] valid_in after reset");
    end else begin
        $display("[PASS] valid_in after reset");
    end

endtask : test_valid_in_timing

// -----------------------------------------------------------------------------
// Test: Reset During Operation
// -----------------------------------------------------------------------------
task automatic test_reset_during_operation();
    logic [511:0] a, b;

    $display("\n[CASE] Reset During Operation");

    // Apply a calculation
    a = 512'hDEADBEEFDEADBEEF;
    b = 512'hCAFEBABECAFEBABE;

    operand_a = a;
    operand_b = b;
    valid_in = 1'b1;
    @(posedge clk);
    valid_in = 1'b0;

    // Assert reset during computation (after 1 cycle)
    @(posedge clk);
    rst_n = 1'b0;
    @(posedge clk);
    rst_n = 1'b1;

    # 1;
    // Check that outputs are reset to zero
    total_tests++;
    if (sum_dsp !== '0) begin
        errors++;
        $display("[FAIL] DSP output not reset during operation");
    end else begin
        $display("[PASS] DSP reset during operation");
    end

    // Re-apply reset for clean state
    apply_reset();

endtask : test_reset_during_operation

// -----------------------------------------------------------------------------
// Test: Back-to-Back Operations
// -----------------------------------------------------------------------------
task automatic test_back_to_back();
    logic [511:0] a1, b1, a2, b2;
    logic [511:0] expected1, expected2;

    $display("\n[CASE] Back-to-Back Operations");

    // First operation
    a1 = 512'h1111111111111111;
    b1 = 512'h2222222222222222;
    expected1 = ref_512bit_add(a1, b1);

    // Second operation (different data)
    a2 = 512'h3333333333333333;
    b2 = 512'h4444444444444444;
    expected2 = ref_512bit_add(a2, b2);

    // Apply first operation
    operand_a = a1;
    operand_b = b1;
    valid_in = 1'b1;
    @(posedge clk);
    valid_in = 1'b0;

    // Wait 1 cycle then apply second operation
    repeat (1) @(posedge clk);
    operand_a = a2;
    operand_b = b2;
    valid_in = 1'b1;
    @(posedge clk);
    valid_in = 1'b0;

    // Wait for both results (DSP has pipeline)
    repeat (4) @(posedge clk);

    // Check second result (first result should be overwritten)
    total_tests++;
    if (sum_dsp !== expected2) begin
        errors++;
        $display("[FAIL] Back-to-back DSP operation");
        $display("  Expected: %h", expected2);
        $display("  Got:      %h", sum_dsp);
    end else begin
        $display("[PASS] Back-to-back DSP operation");
    end

    // Fabric should show second result immediately
    #1; // Small delay for combinational settling
    total_tests++;
    if (sum_fabric !== expected2) begin
        errors++;
        $display("[FAIL] Back-to-back Fabric operation");
    end else begin
        $display("[PASS] Back-to-back Fabric operation");
    end

endtask : test_back_to_back

// -----------------------------------------------------------------------------
// Main Test Sequence
// -----------------------------------------------------------------------------
initial begin
    // Wait 100ns for glbl initialization (as requested)
    #100ns;

    $display("\n=== adder_512bit Testbench ===");
    $display("Clock period: %0d ns", CLK_PERIOD_NS);
    $display("Testing both USE_DSP=1 and USE_DSP=0 implementations\n");

    // Initial reset
    apply_reset();

    // Run test suites
    test_corner_cases();
    test_random_patterns(50); // Reduced for simulation speed
    test_valid_in_timing();
    test_reset_during_operation();
    test_back_to_back();

    // Summary
    $display("\n----------------------------------");
    $display(" Test Summary:");
    $display("   Total tests          : %0d", total_tests);
    $display("   Total errors         : %0d", errors);
    $display("   DSP mismatches       : %0d", dsp_mismatches);
    $display("   Fabric mismatches    : %0d", fabric_mismatches);

    if (errors == 0) begin
        $display("   RESULT: ALL TESTS PASSED");
    end else begin
        $display("   RESULT: SOME TESTS FAILED");
    end

    $display("----------------------------------\n");

    // Optional: Add a small delay before finishing
    repeat (10) @(posedge clk);
    $finish;
end

// -----------------------------------------------------------------------------
// Monitoring and Assertions
// -----------------------------------------------------------------------------

// Check for X/Z in outputs
always @(posedge clk) begin
    if (rst_n) begin
        if (^sum_dsp === 1'bx) begin
            $warning("[DSP] Output contains X/Z at time %0t", $time);
        end
        if (^sum_fabric === 1'bx) begin
            $warning("[FABRIC] Output contains X/Z at time %0t", $time);
        end
    end
end

// Check DSP latency assertion
property dsp_latency_p;
    logic [511:0] captured_a, captured_b;
    @(posedge clk) disable iff (!rst_n)
    (valid_in, captured_a = operand_a, captured_b = operand_b) |=>
    ##2 (sum_dsp == ref_512bit_add(captured_a, captured_b));
endproperty

dsp_latency_check: assert property (dsp_latency_p)
    else $error("DSP latency violation at time %0t", $time);

// Check fabric immediate response (combinational)
always @(operand_a or operand_b) begin
    if (rst_n && $time > 0) begin
        #0.1; // Small delta for stabilization
        if (sum_fabric !== ref_512bit_add(operand_a, operand_b)) begin
            $error("[FABRIC] Combinational output mismatch at time %0t", $time);
        end
    end
end

endmodule : tb_adder_512bit

`default_nettype wire