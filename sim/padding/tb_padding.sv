`timescale 1ns / 1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Testbench for padding
// Verifies correct insertion of 0x01 and 0x00 bytes depending on keep mask.
// Consistent structure and style with tb_p_transform / tb_s_transform.
// -----------------------------------------------------------------------------
module tb_padding;

// -----------------------------------------------------------------------------
// DUT I/O
// -----------------------------------------------------------------------------
logic [511:0] i_data;
logic [63:0]  i_keep;
logic [511:0] o_data;
logic [511:0] expected;

// Statistics
int total_tests = 0;
int errors = 0;

// -----------------------------------------------------------------------------
// DUT Instance
// -----------------------------------------------------------------------------
padding dut (
    .i_data(i_data),
    .i_keep(i_keep),
    .o_data(o_data)
);

// -----------------------------------------------------------------------------
// Human-readable reference padding: find first zero in keep mask and apply rule.
// This is easy to read and verify when debugging.
// -----------------------------------------------------------------------------
function automatic [511:0] ref_padding(input [511:0] data, input [63:0] keep);
    int first_zero;
    // default: no zero found => first_zero = -1
    first_zero = -1;
    for (int i = 0; i < 64; i++) begin
        if (keep[i] == 1'b0) begin
            first_zero = i;
            break;
        end
    end

    // If all bytes valid -> pass through all
    if (first_zero == -1) begin
        ref_padding = data;
        return ref_padding;
    end

    // Build output: bytes before first_zero are input, first_zero -> 0x01, rest -> 0x00
    for (int i = 0; i < 64; i++) begin
        if (i < first_zero)
            ref_padding[i*8 +: 8] = data[i*8 +: 8];
        else if (i == first_zero)
            ref_padding[i*8 +: 8] = 8'h01;
        else
            ref_padding[i*8 +: 8] = 8'h00;
    end
endfunction : ref_padding

// -----------------------------------------------------------------------------
// Common check task
// -----------------------------------------------------------------------------
task automatic check_result(string name);
    expected = ref_padding(i_data, i_keep);
    #10;
    total_tests++;
    if (o_data !== expected) begin
        errors++;
        $display("[FAIL] %s", name);
        for (int i = 0; i < 64; i++) begin
            if (o_data[i*8 +: 8] !== expected[i*8 +: 8]) begin
                $display("  Byte[%0d]: expected %02h, got %02h | keep=%0b",
                         i, expected[i*8 +: 8], o_data[i*8 +: 8], i_keep[i]);
            end
        end
    end else begin
        $display("[PASS] %s", name);
    end
endtask : check_result

// -----------------------------------------------------------------------------
// Test: full keep mask (no padding expected)
// -----------------------------------------------------------------------------
task automatic test_full_keep();
    i_keep = '1; // all valid
    for (int i = 0; i < 64; i++)
        i_data[i*8 +: 8] = i[7:0];
    check_result("Full keep (no padding)");
endtask : test_full_keep

// -----------------------------------------------------------------------------
// Test: empty keep mask (all padding, starts with 0x01 then 0x00)
// -----------------------------------------------------------------------------
task automatic test_empty_keep();
    i_keep = '0;
    i_data = 'hDEADBEEFCAFEBABE_1122334455667788_FEDCBA9876543210_0BADF00DDEADC0DE;
    check_result("Empty keep (all padding)");
endtask : test_empty_keep

// -----------------------------------------------------------------------------
// Test: single valid byte (padding after first)
// -----------------------------------------------------------------------------
task automatic test_single_keep();
    i_keep = 64'b1; // only byte[0] valid
    i_data = {64{8'hAA}};
    check_result("Single valid byte");
endtask : test_single_keep

// -----------------------------------------------------------------------------
// Test: partial keeps (simulate message remainder cases)
// -----------------------------------------------------------------------------
task automatic test_partial_patterns();
    int len_list[5] = '{2, 8, 16, 31, 63};
    for (int t = 0; t < $size(len_list); t++) begin
        int len = len_list[t];
        i_keep = (64'hFFFFFFFFFFFFFFFF >> (64 - len));
        for (int i = 0; i < 64; i++)
            i_data[i*8 +: 8] = i;
        check_result($sformatf("Partial keep length=%0d", len));
    end
endtask : test_partial_patterns

// -----------------------------------------------------------------------------
// Main test sequence
// -----------------------------------------------------------------------------
initial begin
    $display("\n=== Padding Testbench ===");

    test_full_keep();
    test_empty_keep();
    test_single_keep();
    test_partial_patterns();

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

endmodule : tb_padding

`default_nettype wire
