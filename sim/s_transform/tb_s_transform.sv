`timescale 1ns / 1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Testbench for s_transform
// Verifies byte-wise substitution correctness for two DUT parameterizations:
//   - naive table mode (USE_S_RE = 0)
//   - reverse-engineered mode (USE_S_RE = 1)
// Test style and output are consistent with existing tb_p_transform.
// -----------------------------------------------------------------------------
module tb_s_transform;

// -----------------------------------------------------------------------------
// DUT I/O and reference signals
// -----------------------------------------------------------------------------
logic [511:0] i_data;
logic [511:0] o_naive;
logic [511:0] o_re;

logic [511:0] expected;

// Statistics
int total_tests = 0; // counts checks (2 per stimulus: naive + re)
int errors = 0;

// -----------------------------------------------------------------------------
// DUT Instances (two parameter sets)
// -----------------------------------------------------------------------------
s_transform #(.USE_S_RE(0)) dut_naive (
    .i_data(i_data),
    .o_data(o_naive)
);

s_transform #(.USE_S_RE(1)) dut_re (
    .i_data(i_data),
    .o_data(o_re)
);

// -----------------------------------------------------------------------------
// Reference S-box
// -----------------------------------------------------------------------------
const logic [7:0] SBOX_REF [0:255] = '{
    8'hFC, 8'hEE, 8'hDD, 8'h11, 8'hCF, 8'h6E, 8'h31, 8'h16, 8'hFB, 8'hC4, 8'hFA, 8'hDA, 8'h23, 8'hC5, 8'h04, 8'h4D,
    8'hE9, 8'h77, 8'hF0, 8'hDB, 8'h93, 8'h2E, 8'h99, 8'hBA, 8'h17, 8'h36, 8'hF1, 8'hBB, 8'h14, 8'hCD, 8'h5F, 8'hC1,
    8'hF9, 8'h18, 8'h65, 8'h5A, 8'hE2, 8'h5C, 8'hEF, 8'h21, 8'h81, 8'h1C, 8'h3C, 8'h42, 8'h8B, 8'h01, 8'h8E, 8'h4F,
    8'h05, 8'h84, 8'h02, 8'hAE, 8'hE3, 8'h6A, 8'h8F, 8'hA0, 8'h06, 8'h0B, 8'hED, 8'h98, 8'h7F, 8'hD4, 8'hD3, 8'h1F,
    8'hEB, 8'h34, 8'h2C, 8'h51, 8'hEA, 8'hC8, 8'h48, 8'hAB, 8'hF2, 8'h2A, 8'h68, 8'hA2, 8'hFD, 8'h3A, 8'hCE, 8'hCC,
    8'hB5, 8'h70, 8'h0E, 8'h56, 8'h08, 8'h0C, 8'h76, 8'h12, 8'hBF, 8'h72, 8'h13, 8'h47, 8'h9C, 8'hB7, 8'h5D, 8'h87,
    8'h15, 8'hA1, 8'h96, 8'h29, 8'h10, 8'h7B, 8'h9A, 8'hC7, 8'hF3, 8'h91, 8'h78, 8'h6F, 8'h9D, 8'h9E, 8'hB2, 8'hB1,
    8'h32, 8'h75, 8'h19, 8'h3D, 8'hFF, 8'h35, 8'h8A, 8'h7E, 8'h6D, 8'h54, 8'hC6, 8'h80, 8'hC3, 8'hBD, 8'h0D, 8'h57,
    8'hDF, 8'hF5, 8'h24, 8'hA9, 8'h3E, 8'hA8, 8'h43, 8'hC9, 8'hD7, 8'h79, 8'hD6, 8'hF6, 8'h7C, 8'h22, 8'hB9, 8'h03,
    8'hE0, 8'h0F, 8'hEC, 8'hDE, 8'h7A, 8'h94, 8'hB0, 8'hBC, 8'hDC, 8'hE8, 8'h28, 8'h50, 8'h4E, 8'h33, 8'h0A, 8'h4A,
    8'hA7, 8'h97, 8'h60, 8'h73, 8'h1E, 8'h00, 8'h62, 8'h44, 8'h1A, 8'hB8, 8'h38, 8'h82, 8'h64, 8'h9F, 8'h26, 8'h41,
    8'hAD, 8'h45, 8'h46, 8'h92, 8'h27, 8'h5E, 8'h55, 8'h2F, 8'h8C, 8'hA3, 8'hA5, 8'h7D, 8'h69, 8'hD5, 8'h95, 8'h3B,
    8'h07, 8'h58, 8'hB3, 8'h40, 8'h86, 8'hAC, 8'h1D, 8'hF7, 8'h30, 8'h37, 8'h6B, 8'hE4, 8'h88, 8'hD9, 8'hE7, 8'h89,
    8'hE1, 8'h1B, 8'h83, 8'h49, 8'h4C, 8'h3F, 8'hF8, 8'hFE, 8'h8D, 8'h53, 8'hAA, 8'h90, 8'hCA, 8'hD8, 8'h85, 8'h61,
    8'h20, 8'h71, 8'h67, 8'hA4, 8'h2D, 8'h2B, 8'h09, 8'h5B, 8'hCB, 8'h9B, 8'h25, 8'hD0, 8'hBE, 8'hE5, 8'h6C, 8'h52,
    8'h59, 8'hA6, 8'h74, 8'hD2, 8'hE6, 8'hF4, 8'hB4, 8'hC0, 8'hD1, 8'h66, 8'hAF, 8'hC2, 8'h39, 8'h4B, 8'h63, 8'hB6
};

// -----------------------------------------------------------------------------
// Reference model
// -----------------------------------------------------------------------------
function automatic [511:0] ref_naive(input [511:0] data);
    for (int i = 0; i < 64; i++) begin
        ref_naive[i*8 +: 8] = SBOX_REF[data[i*8 +: 8]];
    end
endfunction : ref_naive

// -----------------------------------------------------------------------------
// Common check task (checks both DUT variants for single stimulus)
// Matches style of tb_p_transform: compute expected, then #10, then compare.
// -----------------------------------------------------------------------------
task automatic check_result(string name);
    // compute expected results before waiting (keeps waveform clean)
    expected = ref_naive(i_data);

    #10; // allow combinational outputs to settle

    // naive DUT
    total_tests++;
    if (o_naive !== expected) begin
        errors++;
        $display("[FAIL]  naive : %s", name);
        for (int i = 0; i < 64; i++) begin
            if (o_naive[i*8 +: 8] !== expected[i*8 +: 8]) begin
                $display("  Byte[%0d]: expected %02h, got %02h",
                         i, expected[i*8 +: 8], o_naive[i*8 +: 8]);
            end
        end
    end else begin
        $display("[PASS]  naive : %s", name);
    end

    // reverse DUT
    total_tests++;
    if (o_re !== expected) begin
        errors++;
        $display("[FAIL]  reverse: %s", name);
        for (int i = 0; i < 64; i++) begin
            if (o_re[i*8 +: 8] !== expected[i*8 +: 8]) begin
                $display("  Byte[%0d]: expected %02h, got %02h",
                         i, expected[i*8 +: 8], o_re[i*8 +: 8]);
            end
        end
    end else begin
        $display("[PASS]  reverse: %s", name);
    end
endtask : check_result

// -----------------------------------------------------------------------------
// Test vectors (same structure & style as tb_p_transform)
// -----------------------------------------------------------------------------
task automatic test_sequential();
    for (int start = 0; start < 256; start += 64) begin
        for (int i = 0; i < 64; i++)
            i_data[i*8 +: 8] = i[7:0] + start;
        check_result($sformatf("Sequential pattern start=%0d", start));
    end
endtask : test_sequential

task automatic test_random(int num = 10);
    for (int n = 0; n < num; n++) begin
        // build full 512-bit random value (16 x 32-bit words)
        i_data = $urandom();
        repeat (15) i_data = {i_data, $urandom()};
        check_result($sformatf("Random #%0d", n));
    end
endtask : test_random

// -----------------------------------------------------------------------------
// Test sequence
// -----------------------------------------------------------------------------
initial begin
    $display("\n=== s_transform Testbench ===");

    test_sequential();
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
// Optional sanity check: detect X/Z on outputs
// -----------------------------------------------------------------------------
always @(o_naive or o_re) begin
    if (^o_naive === 1'bx)
        $warning("Output (naive) contains X/Z at time %0t", $time);
    if (^o_re === 1'bx)
        $warning("Output (reverse) contains X/Z at time %0t", $time);
end

endmodule : tb_s_transform

`default_nettype wire
