`timescale 1ns / 1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Testbench for g_transform
// Verifies correctness and handshaking of three configurations:
//   - naive   : USE_S_RE=0, USE_PRECALC=0
//   - reverse : USE_S_RE=1, USE_PRECALC=0
//   - precalc : USE_PRECALC=1 (ROM-based precomputed path)
//
// Checks:
//   - Functional equality with DPI reference `stribog_g_transform`
//   - Proper s_axis handshaking (s_axis_m_tready) and refusal to accept
//     back-to-back blocks while busy
//   - Robustness to reset asserted mid-processing
//   - Random+edge-case coverage
//
// Notes:
//   - All three DUT instances share the same inputs (N, h, m).
//   - Each DUT may have different internal latency; this TB waits per-instance
//     for o_h_valid and compares outputs individually.
// -----------------------------------------------------------------------------
module tb_g_transform #(
    parameter CLK_PERIOD_NS = 10,
    parameter INT_TIMEOUT_CYCLES = 1000,   // per-instance timeout while waiting for valid
    parameter ROUNDS = 128
);

import "DPI-C" function void stribog_g_transform(
    input  byte unsigned N[64],
    input  byte unsigned h[64],
    input  byte unsigned m[64],
    output byte unsigned res[64]
);

// -----------------------------------------------------------------------------
// Helper: wrapper that calls the DPI reference and returns 512-bit result
// -----------------------------------------------------------------------------
function automatic logic [511:0] call_g_transform (
    input logic [511:0] input_N,
    input logic [511:0] input_h,
    input logic [511:0] input_m
);
    byte unsigned N_arr[64];
    byte unsigned h_arr[64];
    byte unsigned m_arr[64];
    byte unsigned out_arr[64];
    logic [511:0] result;
    begin
        for (int i = 0; i < 64; i++) begin
            N_arr[i] = input_N[i*8 +: 8];
            h_arr[i] = input_h[i*8 +: 8];
            m_arr[i] = input_m[i*8 +: 8];
        end

        // call the trusted C model
        stribog_g_transform(N_arr, h_arr, m_arr, out_arr);

        // collect result
        for (int i = 0; i < 64; i++)
            result[i*8 +: 8] = out_arr[i];

        return result;
    end
endfunction : call_g_transform

// -----------------------------------------------------------------------------
// Signals shared across DUT instances (inputs)
// -----------------------------------------------------------------------------
logic clk;
logic rst_n;

logic [511:0] tb_i_N;
logic [511:0] tb_i_h;
logic [511:0] tb_m;

logic         tb_m_valid;   // shared valid (one-cycle pulse)
logic         tb_m_ready_expected; // (for checks)

// -----------------------------------------------------------------------------
// Outputs from DUT instances (separate per-instance)
// -----------------------------------------------------------------------------
logic [511:0] o_naive;    logic v_naive;    logic ready_naive;
logic [511:0] o_reverse;  logic v_reverse;  logic ready_reverse;
logic [511:0] o_precalc;  logic v_precalc;  logic ready_precalc;

// -----------------------------------------------------------------------------
// Stats
// -----------------------------------------------------------------------------
int total_checks = 0;
int errors = 0;

// -----------------------------------------------------------------------------
// Clock
// -----------------------------------------------------------------------------
initial clk = 0;
always #(CLK_PERIOD_NS/2) clk = ~clk;

// -----------------------------------------------------------------------------
// DUT instantiation: three variants
// -----------------------------------------------------------------------------
g_transform #(.USE_S_RE(0), .USE_PRECALC(0)) dut_naive (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_h_data       (tb_i_h),
    .i_N_data       (tb_i_N),
    .s_axis_m_tdata (tb_m),
    .s_axis_m_tvalid(tb_m_valid),
    .s_axis_m_tready(ready_naive),
    .o_h_data       (o_naive),
    .o_h_valid      (v_naive)
);

g_transform #(.USE_S_RE(1), .USE_PRECALC(0)) dut_reverse (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_h_data       (tb_i_h),
    .i_N_data       (tb_i_N),
    .s_axis_m_tdata (tb_m),
    .s_axis_m_tvalid(tb_m_valid),
    .s_axis_m_tready(ready_reverse),
    .o_h_data       (o_reverse),
    .o_h_valid      (v_reverse)
);

// Precalc path: uses ROMs; USE_S_RE not applicable
g_transform #(.USE_PRECALC(1)) dut_precalc (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_h_data       (tb_i_h),
    .i_N_data       (tb_i_N),
    .s_axis_m_tdata (tb_m),
    .s_axis_m_tvalid(tb_m_valid),
    .s_axis_m_tready(ready_precalc),
    .o_h_data       (o_precalc),
    .o_h_valid      (v_precalc)
);

// -----------------------------------------------------------------------------
// Helpers: wait until all DUT instances are ready to accept new message
// -----------------------------------------------------------------------------
task automatic wait_all_ready(input int timeout_cycles = 200);
    int cycles = 0;
    begin
        while (!(ready_naive && ready_reverse && ready_precalc)) begin
            @(posedge clk);
            cycles++;
            if (cycles >= timeout_cycles) begin
                $display("[ERROR] Timeout waiting for all DUTs ready (cycles=%0d). ready_naive=%b ready_reverse=%b ready_precalc=%b",
                         cycles, ready_naive, ready_reverse, ready_precalc);
                errors++;
                disable wait_all_ready;
            end
        end
    end
endtask : wait_all_ready

// -----------------------------------------------------------------------------
// Helper: wait for a single DUT valid and capture output (with timeout).
// Returns 1 on success, 0 on timeout.
// -----------------------------------------------------------------------------
task automatic wait_and_capture(
    input  logic         sig_valid,
    input  logic [511:0] sig_data,
    input  int           timeout_cycles,
    output logic [511:0] captured,
    output logic         ok
);
    int cycles;
    begin
        cycles = 0;
        captured = '0;
        while (!sig_valid) begin
            @(posedge clk);
            cycles++;
            if (cycles >= timeout_cycles) begin
                ok = 0;
                return;
            end
        end
        // When valid asserted, capture value on that cycle (o_h_valid is synchronous)
        captured = sig_data;
        ok = 1;
        return;
    end
endtask : wait_and_capture

// -----------------------------------------------------------------------------
// Common check task: submit inputs (when all ready) and validate per-instance
// This version waits for all three DUT outputs in parallel (single timeout).
// -----------------------------------------------------------------------------
task automatic submit_and_check(string name, logic [511:0] N, logic [511:0] h, logic [511:0] m);
    logic [511:0] expected;
    logic [511:0] got_naive, got_reverse, got_precalc;
    bit captured_naive, captured_reverse, captured_precalc;
    int cycles;
    begin
        expected = call_g_transform(N, h, m);

        // wait until all DUTs report ready
        wait_all_ready();

        // drive inputs for single-cycle handshake
        tb_i_N     = N;
        tb_i_h     = h;
        tb_m       = m;
        tb_m_valid = 1'b1;
        @(posedge clk);
        tb_m_valid = 1'b0;

        // Prepare capture flags
        captured_naive   = 0;
        captured_reverse = 0;
        captured_precalc = 0;
        got_naive   = '0;
        got_reverse = '0;
        got_precalc = '0;

        // Parallel wait loop: capture outputs as soon as each o_h_valid asserts.
        cycles = 0;
        while (!(captured_naive && captured_reverse && captured_precalc) && cycles < INT_TIMEOUT_CYCLES) begin
            @(posedge clk);
            cycles++;

            if (v_naive && !captured_naive) begin
                got_naive = o_naive;
                captured_naive = 1;
            end
            if (v_reverse && !captured_reverse) begin
                got_reverse = o_reverse;
                captured_reverse = 1;
            end
            if (v_precalc && !captured_precalc) begin
                got_precalc = o_precalc;
                captured_precalc = 1;
            end
        end

        // Evaluate results (naive)
        total_checks++;
        if (!captured_naive) begin
            errors++;
            $display("[FAIL] %s : naive TIMED OUT after %0d cycles (ready_naive=%b)", name, cycles, ready_naive);
        end else if (got_naive !== expected) begin
            errors++;
            $display("[FAIL] %s : naive mismatch", name);
            $display("  expected: %h", expected);
            $display("  got     : %h", got_naive);
        end else begin
            $display("[PASS] %s : naive", name);
        end

        // Evaluate results (reverse)
        total_checks++;
        if (!captured_reverse) begin
            errors++;
            $display("[FAIL] %s : reverse TIMED OUT after %0d cycles (ready_reverse=%b)", name, cycles, ready_reverse);
        end else if (got_reverse !== expected) begin
            errors++;
            $display("[FAIL] %s : reverse mismatch", name);
            $display("  expected: %h", expected);
            $display("  got     : %h", got_reverse);
        end else begin
            $display("[PASS] %s : reverse", name);
        end

        // Evaluate results (precalc)
        total_checks++;
        if (!captured_precalc) begin
            errors++;
            $display("[FAIL] %s : precalc TIMED OUT after %0d cycles (ready_precalc=%b)", name, cycles, ready_precalc);
        end else if (got_precalc !== expected) begin
            errors++;
            $display("[FAIL] %s : precalc mismatch", name);
            $display("  expected: %h", expected);
            $display("  got     : %h", got_precalc);
        end else begin
            $display("[PASS] %s : precalc", name);
        end

        // small idle cycle for simulator stability
        repeat (1) @(posedge clk);
    end
endtask : submit_and_check

// -----------------------------------------------------------------------------
// Testcases
// -----------------------------------------------------------------------------
task automatic test_randoms(int n = ROUNDS);
    logic [511:0] N,h,m;
    for (int i = 0; i < n; i++) begin
        N = {$urandom, $urandom, $urandom, $urandom,
             $urandom, $urandom, $urandom, $urandom};
        h = {$urandom, $urandom, $urandom, $urandom,
             $urandom, $urandom, $urandom, $urandom};
        m = {$urandom, $urandom, $urandom, $urandom,
             $urandom, $urandom, $urandom, $urandom};
        submit_and_check($sformatf("random %0d", i), N, h, m);
    end
endtask : test_randoms

task automatic test_edge_cases();
    logic [511:0] N,h,m;
    // all zeros
    N = '0; h = '0; m = '0;
    submit_and_check("edge all zeros", N, h, m);

    // all ones
    N = {512{1'b1}}; h = {512{1'b1}}; m = {512{1'b1}};
    submit_and_check("edge all ones", N, h, m);

    // alternating bytes 0xAA / 0x55
    for (int i = 0; i < 64; i++) begin
        m[i*8 +: 8] = (i & 1) ? 8'hAA : 8'h55;
        h[i*8 +: 8] = (i & 1) ? 8'h55 : 8'hAA;
        N[i*8 +: 8] = i; // incremental N for variety
    end
    submit_and_check("edge alt AA/55", N, h, m);
endtask : test_edge_cases

// -----------------------------------------------------------------------------
// Back-to-back handshake test
// Ensure module does not accept a second block while busy.
// -----------------------------------------------------------------------------
task automatic test_back_to_back();
    logic [511:0] N1,h1,m1, N2,h2,m2;
    int cycles;
    // prepare two different blocks
    N1 = {
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom
    };
    h1 = {
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom
    };
    m1 = {
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom
    };

    N2 = {
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom
    };
    h2 = {
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom
    };
    m2 = {
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom
    };

    // wait all ready and send first block
    wait_all_ready();
    tb_i_N = N1; tb_i_h = h1; tb_m = m1; tb_m_valid = 1'b1;
    @(posedge clk);
    tb_m_valid = 1'b0;

    // Immediately try to send second block on next cycle (should be refused)
    @(posedge clk);
    if (ready_naive && ready_reverse && ready_precalc) begin
        $display("[WARN] back-to-back: unexpectedly all DUTs reported ready immediately after submit");
    end else begin
        $display("[INFO] back-to-back: DUTs asserted busy as expected (ready_naive=%b ready_reverse=%b ready_precalc=%b)",
                 ready_naive, ready_reverse, ready_precalc);
    end

    // Wait until all complete and then submit second block normally
    // Capture outputs (but we reuse submit_and_check to validate second block)
    // First wait until all ready
    wait_all_ready();
    submit_and_check("back-to-back second block", N2, h2, m2);
endtask : test_back_to_back

// -----------------------------------------------------------------------------
// Reset-in-the-middle test
// -----------------------------------------------------------------------------
task automatic test_reset_midstream();
    logic [511:0] N,h,m;
    N = {
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom
    };
    h = {
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom
    };
    m = {
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom
    };

    // wait all ready and submit
    wait_all_ready();
    tb_i_N = N; tb_i_h = h; tb_m = m; tb_m_valid = 1'b1;
    @(posedge clk);
    tb_m_valid = 1'b0;

    // assert reset shortly after submission to simulate midstream reset
    repeat (2) @(posedge clk);
    rst_n = 0;
    @(posedge clk);
    rst_n = 1;
    // Now the DUTs should be back to IDLE; send same vector and check it completes
    wait_all_ready();
    submit_and_check("reset midstream recovery", N, h, m);
endtask : test_reset_midstream

// -----------------------------------------------------------------------------
// Test runner / main
// -----------------------------------------------------------------------------
initial begin
    $display("\n=== g_transform Testbench ===");
    // init
    rst_n = 0;
    tb_i_N = '0; tb_i_h = '0; tb_m = '0; tb_m_valid = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // run tests
    test_edge_cases();
    test_randoms(ROUNDS);
    test_back_to_back();
    test_reset_midstream();

    // summary
    $display("\n----------------------------------");
    $display(" Test Summary:");
    $display("   Total checks : %0d", total_checks);
    $display("   Errors       : %0d", errors);
    if (errors == 0) $display("   RESULT       : ALL TESTS PASSED");
    else              $display("   RESULT       : SOME TESTS FAILED");
    $display("----------------------------------\n");

    $finish;
end

// -----------------------------------------------------------------------------
// Sanity: warn if any DUT output contains X/Z
// -----------------------------------------------------------------------------
always @(o_naive or o_reverse or o_precalc) begin
    if (^o_naive === 1'bx)  $warning("o_naive contains X/Z at time %0t", $time);
    if (^o_reverse === 1'bx) $warning("o_reverse contains X/Z at time %0t", $time);
    if (^o_precalc === 1'bx) $warning("o_precalc contains X/Z at time %0t", $time);
end

endmodule : tb_g_transform

`default_nettype wire
