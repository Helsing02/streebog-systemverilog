`timescale 1ns / 1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Testbench for lpsx_transform (DPI reference model)
// Verifies three configurations produce identical results:
//   - naive   : USE_PRECALC=0, USE_S_RE=0
//   - reverse : USE_PRECALC=0, USE_S_RE=1
//   - precalc : USE_PRECALC=1 (real ROM-based path; user provides HEX files)
//
// Reference model: calls C DPI functions:
//   stribog_S_transform(byte[64])
//   stribog_P_transform(byte[64])
//   stribog_L_transform(byte[64])
//
// Behavior:
//   - For naive/reverse: treated as combinational in DUT (compare after small settle).
//   - For precalc: DUT uses ROM/BRAM and produces registered outputs; we sample on next clock edge
//     and require o_valid == 1 when sampling.
//
// Notes:
//   - Ensure DPI C object/library is built and passed to simulator (see instructions below).
// -----------------------------------------------------------------------------
module tb_lpsx_transform #(
    parameter ROUNDS = 200,
    parameter CLK_PERIOD_NS = 10
);

// -----------------------------------------------------------------------------
// DPI imports (user C model functions)
import "DPI-C" function void stribog_S_transform(input byte unsigned block[64]);
import "DPI-C" function void stribog_P_transform(input byte unsigned block[64]);
import "DPI-C" function void stribog_L_transform(input byte unsigned block[64]);

// -----------------------------------------------------------------------------
// Signals
// -----------------------------------------------------------------------------
logic clk;
logic rst_n;

logic [511:0] i_data_a;
logic [511:0] i_data_b;
logic         i_valid;

// DUT outputs
logic [511:0] o_naive;
logic         v_naive;

logic [511:0] o_reverse;
logic         v_reverse;

logic [511:0] o_precalc;
logic         v_precalc;

// Statistics
int total_checks = 0;
int errors = 0;

// Clock
initial clk = 0;
always #(CLK_PERIOD_NS/2) clk = ~clk;

// -----------------------------------------------------------------------------
// Instantiate DUTs
// (Assumes lpsx_transform module is in the compile list)
// -----------------------------------------------------------------------------
lpsx_transform #(.USE_S_RE(0), .USE_PRECALC(0)) dut_naive (
    .clk     (clk),
    .rst_n   (rst_n),
    .i_data_a(i_data_a),
    .i_data_b(i_data_b),
    .i_valid (i_valid),
    .o_data  (o_naive),
    .o_valid (v_naive)
);

lpsx_transform #(.USE_S_RE(1), .USE_PRECALC(0)) dut_reverse (
    .clk     (clk),
    .rst_n   (rst_n),
    .i_data_a(i_data_a),
    .i_data_b(i_data_b),
    .i_valid (i_valid),
    .o_data  (o_reverse),
    .o_valid (v_reverse)
);

// Precalc path: real module uses ROMs loaded from HEX; user stated files already exist.
lpsx_transform #(.USE_PRECALC(1)) dut_precalc (
    .clk     (clk),
    .rst_n   (rst_n),
    .i_data_a(i_data_a),
    .i_data_b(i_data_b),
    .i_valid (i_valid),
    .o_data  (o_precalc),
    .o_valid (v_precalc)
);

// -----------------------------------------------------------------------------
// Helper: convert two 512-bit vectors into byte array, call DPI S/P/L and return 512-bit
// -----------------------------------------------------------------------------
function automatic logic [511:0] ref_do_lpsx(input logic [511:0] A, input logic [511:0] B);
    byte unsigned tmp[64];
    logic [511:0] outv;
    begin
        // X = A ^ B, then copy bytes into tmp
        for (int i = 0; i < 64; i++) begin
            tmp[i] = (A[i*8 +: 8] ^ B[i*8 +: 8]);
        end

        // Call DPI C model (in-place)
        stribog_S_transform(tmp);
        stribog_P_transform(tmp);
        stribog_L_transform(tmp);

        // Collect back into 512-bit vector (byte 0 -> LSB byte 0*8..)
        for (int i = 0; i < 64; i++) begin
            outv[i*8 +: 8] = tmp[i];
        end
        return outv;
    end
endfunction

// -----------------------------------------------------------------------------
// Common check task:
//  - compute expected via DPI
//  - apply stimulus
//  - check naive & reverse after small settle (combinational)
//  - check precalc on next rising edge (registered, check o_valid)
// -----------------------------------------------------------------------------
task automatic check_vector(string case_name, logic [511:0] A, logic [511:0] B);
    logic [511:0] expected;
    begin
        expected = ref_do_lpsx(A, B);

        // Drive stimulus
        i_data_a = A;
        i_data_b = B;
        i_valid  = 1'b1;

        // Small settle time for combinational outputs
        #1;

        // Check naive
        total_checks++;
        if ((o_naive !== expected) || (v_naive !== 1'b1)) begin
            errors++;
            $display("[FAIL] naive   : %s", case_name);
            $display("  Expected: %h", expected);
            $display("  Got     : %h (valid=%b)", o_naive, v_naive);
        end else begin
            $display("[PASS] naive   : %s", case_name);
        end

        // Check reverse
        total_checks++;
        if ((o_reverse !== expected) || (v_reverse !== 1'b1)) begin
            errors++;
            $display("[FAIL] reverse : %s", case_name);
            $display("  Expected: %h", expected);
            $display("  Got     : %h (valid=%b)", o_reverse, v_reverse);
        end else begin
            $display("[PASS] reverse : %s", case_name);
        end

        // For precalc: wait for registered output (one clock)
        @(posedge clk);
        // Small settle time for combinational outputs
        #1;
        total_checks++;
        if ((v_precalc !== 1'b1) || (o_precalc !== expected)) begin
            errors++;
            $display("[FAIL] precalc : %s", case_name);
            $display("  Expected: %h", expected);
            $display("  Got     : %h (valid=%b)", o_precalc, v_precalc);
        end else begin
            $display("[PASS] precalc : %s", case_name);
        end

        // Deassert valid and wait one clock to let pipeline settle
        i_valid = 1'b0;
        @(posedge clk);
    end
endtask

// -----------------------------------------------------------------------------
// Testcases
// -----------------------------------------------------------------------------
task automatic test_sequential();
    logic [511:0] A, B;
    for (int start = 0; start < 256; start += 64) begin
        for (int i = 0; i < 64; i++) begin
            byte b = (i + start) & 8'hFF;
            A[i*8 +: 8] = b;
            B[i*8 +: 8] = b ^ 8'h5A;
        end
        check_vector($sformatf("sequential start=%0d", start), A, B);
    end
endtask

task automatic test_edge_cases();
    logic [511:0] A, B;
    // all zeros
    A = '0; B = '0;
    check_vector("all zeros", A, B);
    // all ones
    A = {512{1'b1}}; B = {512{1'b1}};
    check_vector("all ones", A, B);
    // alternating
    for (int i=0;i<64;i++) begin
        A[i*8 +: 8] = 8'hAA;
        B[i*8 +: 8] = 8'h55;
    end
    check_vector("alt AA/55", A, B);
endtask

task automatic test_randoms(int n = 64);
    logic [511:0] A, B;
    for (int t = 0; t < n; t++) begin
        A = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
        B = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
        check_vector($sformatf("random %0d", t), A, B);
    end
endtask

// -----------------------------------------------------------------------------
// Reset helper
// -----------------------------------------------------------------------------
task automatic apply_reset();
    rst_n = 0;
    i_valid = 0;
    i_data_a = '0;
    i_data_b = '0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
endtask

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------
initial begin
    $display("\n=== lpsx_transform DPI Testbench ===");
    apply_reset();

    test_sequential();
    test_edge_cases();
    test_randoms(ROUNDS);

    $display("\n----------------------------------");
    $display(" Test Summary:");
    $display("   Total checks : %0d", total_checks);
    $display("   Errors       : %0d", errors);
    if (errors == 0)
        $display("   RESULT       : ALL TESTS PASSED");
    else
        $display("   RESULT       : SOME TESTS FAILED");
    $display("----------------------------------\n");

    $finish;
end

// -----------------------------------------------------------------------------
// Sanity: warn if any DUT output contains x/z
// -----------------------------------------------------------------------------
always @(o_naive or o_reverse or o_precalc) begin
    if (^o_naive === 1'bx)  $warning("o_naive contains X/Z at time %0t", $time);
    if (^o_reverse === 1'bx) $warning("o_reverse contains X/Z at time %0t", $time);
    if (^o_precalc === 1'bx) $warning("o_precalc contains X/Z at time %0t", $time);
end

endmodule : tb_lpsx_transform

`default_nettype wire
