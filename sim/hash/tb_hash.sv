`timescale 1ns / 1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Testbench for hash
// Verifies three configurations in parallel:
//   - naive   : USE_S_RE=0, USE_PRECALC=0
//   - reverse : USE_S_RE=1, USE_PRECALC=0
//   - precalc : USE_PRECALC=1 (ROM-based precomputed path)
//
// Approach:
//   - Use DPI model (stribog_init / stribog_update / stribog_final) as golden.
//   - For each packet:
//       * call stribog_init(ctx, mode)
//       * for each AXIS beat: wait until all DUTs ready, drive s_axis_tdata/tkeep/tlast/tvalid
//         and call stribog_update(ctx, block, len) once the beat is accepted.
//       * after last beat call stribog_final(ctx, hash) to obtain expected hash
//       * wait (in parallel) for each DUT m_axis_tvalid and capture its output,
//         compare to expected (considering mode -> mapping of 256/512 bits).
//
// Notes:
//   - Mode may be toggled between packets but must remain stable during a packet.
//   - The testbench observes s_axis_tready from all 3 DUTs and only transmits when
//     all are ready (keeps test deterministic and comparable to prior benches).
// -----------------------------------------------------------------------------

module tb_hash #(
    parameter CLK_PERIOD_NS = 10,
    parameter INT_TIMEOUT_CYCLES = 2000,
    parameter ROUNDS = 128
);

// -----------------------------------------------------------------------------
// DPI imports (trusted reference model)
// -----------------------------------------------------------------------------
import "DPI-C" function void stribog_init(
    inout byte unsigned    ctx[280],
    input int              hash_size
);
import "DPI-C" function void stribog_update(
    inout byte unsigned    ctx[280],
    input byte unsigned    data[64],
    input longint unsigned len
);
import "DPI-C" function void stribog_final(
    input  byte unsigned   ctx[280],
    output byte unsigned   hash[64]
);

// -----------------------------------------------------------------------------
// DPI context (shared, reinitialized per packet)
// -----------------------------------------------------------------------------
byte unsigned ctx[280];

// -----------------------------------------------------------------------------
// Helper wrappers
// -----------------------------------------------------------------------------
task automatic tb_stribog_init(input logic mode);
    int mode_val;
    begin
        mode_val = mode ? 512 : 256;
        stribog_init(ctx, mode_val);
    end
endtask

task automatic tb_stribog_update(input logic [511:0] block, input int len_bytes);
    byte unsigned data[64];
    longint unsigned len;
    begin
        len = len_bytes;
        for (int i = 0; i < 64; i++)
            data[i] = block[i*8 +: 8];
        stribog_update(ctx, data, len);
    end
endtask

function automatic logic [511:0] tb_stribog_final();
    byte unsigned hash_out[64];
    logic [511:0] result;
    begin
        stribog_final(ctx, hash_out);
        for (int i = 0; i < 64; i++)
            result[i*8 +: 8] = hash_out[i];
        return result;
    end
endfunction

// -----------------------------------------------------------------------------
// Local signals (AXIS-like interface to DUTs)
// -----------------------------------------------------------------------------
logic clk;
logic rst_n;

logic        mode;                // single-mode input shared by all DUTs

// s_axis (shared across DUT instances)
logic [511:0] s_axis_tdata;
logic         s_axis_tvalid;
logic [63:0]  s_axis_tkeep;
logic         s_axis_tlast;
logic         s_axis_tready_naive;
logic         s_axis_tready_reverse;
logic         s_axis_tready_precalc;

// m_axis (outputs per DUT)
logic [511:0] m_naive_data; logic m_naive_valid;
logic [63:0]  m_naive_keep; logic m_naive_last;
logic [511:0] m_reverse_data; logic m_reverse_valid;
logic [63:0]  m_reverse_keep; logic m_reverse_last;
logic [511:0] m_precalc_data; logic m_precalc_valid;
logic [63:0]  m_precalc_keep; logic m_precalc_last;

// m_axis_tready (we will always accept the result)
logic m_axis_tready;

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
// DUT instantiations (three variants)
// -----------------------------------------------------------------------------
hash #(.USE_S_RE(0), .USE_PRECALC(0)) dut_naive (
    .clk          (clk),
    .rst_n        (rst_n),
    .mode         (mode),

    .s_axis_tdata (s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready_naive),
    .s_axis_tkeep  (s_axis_tkeep),
    .s_axis_tlast  (s_axis_tlast),

    .m_axis_tdata  (m_naive_data),
    .m_axis_tvalid (m_naive_valid),
    .m_axis_tready (m_axis_tready),
    .m_axis_tkeep  (m_naive_keep),
    .m_axis_tlast  (m_naive_last)
);

hash #(.USE_S_RE(1), .USE_PRECALC(0)) dut_reverse (
    .clk          (clk),
    .rst_n        (rst_n),
    .mode         (mode),

    .s_axis_tdata (s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready_reverse),
    .s_axis_tkeep  (s_axis_tkeep),
    .s_axis_tlast  (s_axis_tlast),

    .m_axis_tdata  (m_reverse_data),
    .m_axis_tvalid (m_reverse_valid),
    .m_axis_tready (m_axis_tready),
    .m_axis_tkeep  (m_reverse_keep),
    .m_axis_tlast  (m_reverse_last)
);

hash #(.USE_PRECALC(1)) dut_precalc (
    .clk          (clk),
    .rst_n        (rst_n),
    .mode         (mode),

    .s_axis_tdata (s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready_precalc),
    .s_axis_tkeep  (s_axis_tkeep),
    .s_axis_tlast  (s_axis_tlast),

    .m_axis_tdata  (m_precalc_data),
    .m_axis_tvalid (m_precalc_valid),
    .m_axis_tready (m_axis_tready),
    .m_axis_tkeep  (m_precalc_keep),
    .m_axis_tlast  (m_precalc_last)
);

// Always-ready for outputs (consume DUT outputs immediately)
initial m_axis_tready = 1'b1;

// -----------------------------------------------------------------------------
// Utility functions
// -----------------------------------------------------------------------------
function automatic int popcount64(input logic [63:0] v);
    int cnt;
    begin
        cnt = 0;
        for (int i = 0; i < 64; i++)
            cnt += v[i];
        return cnt;
    end
endfunction

// Build tkeep mask with lower N bytes = 1
function automatic logic [63:0] tkeep_from_len(input int len_bytes);
    logic [63:0] mask;
    begin
        if (len_bytes <= 0)
            mask = 64'h0;
        else if (len_bytes >= 64)
            mask = ~64'h0;
        else
            mask = (64'h1 << len_bytes) - 1;
        return mask;
    end
endfunction

// Wait until all DUTs report ready to accept s_axis (with timeout)
task automatic wait_all_ready(input int timeout_cycles = 200);
    int cycles;
    begin
        cycles = 0;
        while (!(s_axis_tready_naive && s_axis_tready_reverse && s_axis_tready_precalc)) begin
            @(posedge clk);
            cycles++;
            if (cycles >= timeout_cycles) begin
                $display("[ERROR] Timeout waiting for all DUTs ready (cycles=%0d). ready_naive=%b ready_reverse=%b ready_precalc=%b",
                         cycles, s_axis_tready_naive, s_axis_tready_reverse, s_axis_tready_precalc);
                errors++;
                disable wait_all_ready;
            end
        end
    end
endtask : wait_all_ready

// Parallel wait for three outputs' valid flags, capture outputs and meta; timeout if any fails
task automatic wait_for_all_outputs(
    input  int timeout_cycles,
    output logic [511:0] got_naive, output logic [63:0] got_naive_keep, output logic got_naive_last, output bit ok_naive,
    output logic [511:0] got_reverse, output logic [63:0] got_reverse_keep, output logic got_reverse_last, output bit ok_reverse,
    output logic [511:0] got_precalc, output logic [63:0] got_precalc_keep, output logic got_precalc_last, output bit ok_precalc
);
    int cycles;
    bit cap_naive = 0, cap_reverse = 0, cap_precalc = 0;
    begin
        ok_naive = 0; ok_reverse = 0; ok_precalc = 0;
        got_naive = '0; got_reverse = '0; got_precalc = '0;
        got_naive_keep = '0; got_reverse_keep = '0; got_precalc_keep = '0;
        got_naive_last = 1'b0; got_reverse_last = 1'b0; got_precalc_last = 1'b0;

        cycles = 0;
        while (!(cap_naive && cap_reverse && cap_precalc) && cycles < timeout_cycles) begin
            @(posedge clk);
            cycles++;

            if (m_naive_valid && !cap_naive) begin
                got_naive = m_naive_data;
                got_naive_keep = m_naive_keep;
                got_naive_last = m_naive_last;
                cap_naive = 1;
                ok_naive = 1;
            end

            if (m_reverse_valid && !cap_reverse) begin
                got_reverse = m_reverse_data;
                got_reverse_keep = m_reverse_keep;
                got_reverse_last = m_reverse_last;
                cap_reverse = 1;
                ok_reverse = 1;
            end

            if (m_precalc_valid && !cap_precalc) begin
                got_precalc = m_precalc_data;
                got_precalc_keep = m_precalc_keep;
                got_precalc_last = m_precalc_last;
                cap_precalc = 1;
                ok_precalc = 1;
            end
        end

        // timeouts: mark failed ones
        if (!cap_naive) ok_naive = 0;
        if (!cap_reverse) ok_reverse = 0;
        if (!cap_precalc) ok_precalc = 0;
    end
endtask : wait_for_all_outputs

// -----------------------------------------------------------------------------
// Send one AXIS beat to DUTs (waits all ready, drives one-cycle valid)
// Also calls DPI update once the beat is handshaken.
// -----------------------------------------------------------------------------
// Variant where caller indicates whether this is last beat
task automatic send_block_and_update_last(
    input logic [511:0] block,
    input int len_bytes,
    input bit is_last
);
    begin
        // Wait until all DUTs can accept the beat
        wait_all_ready();

        // set signals for one cycle
        s_axis_tdata  = block;
        s_axis_tkeep  = tkeep_from_len(len_bytes);
        s_axis_tlast  = is_last;
        s_axis_tvalid = 1'b1;
        @(posedge clk);
        // accepted this cycle (we waited for ready), call DPI update with same block
        tb_stribog_update(block, len_bytes);
        // deassert valid
        s_axis_tvalid = 1'b0;
        // small settle
        @(posedge clk);
    end
endtask : send_block_and_update_last

// -----------------------------------------------------------------------------
// High-level: submit a whole packet (message) to DUTs using AXIS beats. The
// message is a byte-length `msg_len`. For simplicity a random byte stream is
// generated. Mode must be set before calling this task and remains constant
// during the packet.
// -----------------------------------------------------------------------------
task automatic send_packet_and_check(string name, int msg_len);
    // scratch variables
    int remaining;
    logic [511:0] block;
    int chunk_len;
    logic [511:0] got_naive, got_reverse, got_precalc;
    logic [63:0] got_naive_keep, got_reverse_keep, got_precalc_keep;
    logic got_naive_last, got_reverse_last, got_precalc_last;

    logic [511:0] expected_out;
    logic [63:0]  expected_keep;

    bit ok_naive, ok_reverse, ok_precalc;
    begin
        // init DPI context for this packet
        tb_stribog_init(mode);

        // prepare random message of msg_len bytes, and send it chunk-by-chunk
        remaining = msg_len;
        while (remaining > 0) begin
            chunk_len = (remaining >= 64) ? 64 : remaining;
            // generate random block: fill chunk_len bytes, rest zero
            block = '0;
            for (int b = 0; b < chunk_len; b++) begin
                block[b*8 +: 8] = $urandom_range(0,255);
            end
            remaining -= chunk_len;
            // if this is last chunk, mark is_last
            send_block_and_update_last(block, chunk_len, (remaining == 0));
        end

        // After last update, call final to get expected hash
        expected_out = tb_stribog_final();

        // Wait and capture outputs in parallel
        wait_for_all_outputs(INT_TIMEOUT_CYCLES,
            got_naive,   got_naive_keep,   got_naive_last,   ok_naive,
            got_reverse, got_reverse_keep, got_reverse_last, ok_reverse,
            got_precalc, got_precalc_keep, got_precalc_last, ok_precalc
        );

        // Evaluate naive
        total_checks++;
        if (!ok_naive) begin
            errors++;
            $display("[FAIL] %s : naive TIMED OUT waiting for output", name);
        end else begin
            if (got_naive !== expected_out) begin
                errors++;
                $display("[FAIL] %s : naive mismatch", name);
                $display("  expected: %h", expected_out);
                $display("  got     : %h", got_naive);
            end else begin
                $display("[PASS] %s : naive", name);
            end
            // check tkeep / tlast semantics
            expected_keep = mode ? ~64'h0 : tkeep_from_len(32);
            if (got_naive_keep !== expected_keep) begin
                errors++;
                $display("[WARN] %s : naive m_axis_tkeep unexpected (got=%h expected=%h)", name, got_naive_keep, expected_keep);
            end
            if (got_naive_last !== 1'b1) begin
                errors++;
                $display("[WARN] %s : naive m_axis_tlast not asserted as expected", name);
            end
        end

        // Evaluate reverse
        total_checks++;
        if (!ok_reverse) begin
            errors++;
            $display("[FAIL] %s : reverse TIMED OUT waiting for output", name);
        end else begin
            if (got_reverse !== expected_out) begin
                errors++;
                $display("[FAIL] %s : reverse mismatch", name);
                $display("  expected: %h", expected_out);
                $display("  got     : %h", got_reverse);
            end else begin
                $display("[PASS] %s : reverse", name);
            end
            expected_keep = mode ? ~64'h0 : tkeep_from_len(32);
            if (got_reverse_keep !== expected_keep) begin
                errors++;
                $display("[WARN] %s : reverse m_axis_tkeep unexpected (got=%h expected=%h)", name, got_reverse_keep, expected_keep);
            end
            if (got_reverse_last !== 1'b1) begin
                errors++;
                $display("[WARN] %s : reverse m_axis_tlast not asserted as expected", name);
            end
        end

        // Evaluate precalc
        total_checks++;
        if (!ok_precalc) begin
            errors++;
            $display("[FAIL] %s : precalc TIMED OUT waiting for output", name);
        end else begin
            if (got_precalc !== expected_out) begin
                errors++;
                $display("[FAIL] %s : precalc mismatch", name);
                $display("  expected: %h", expected_out);
                $display("  got     : %h", got_precalc);
            end else begin
                $display("[PASS] %s : precalc", name);
            end
            expected_keep = mode ? ~64'h0 : tkeep_from_len(32);
            if (got_precalc_keep !== expected_keep) begin
                errors++;
                $display("[WARN] %s : precalc m_axis_tkeep unexpected (got=%h expected=%h)", name, got_precalc_keep, expected_keep);
            end
            if (got_precalc_last !== 1'b1) begin
                errors++;
                $display("[WARN] %s : precalc m_axis_tlast not asserted as expected", name);
            end
        end

        // short pause between packets
        repeat (1) @(posedge clk);
    end
endtask : send_packet_and_check

// -----------------------------------------------------------------------------
// Testcases
// -----------------------------------------------------------------------------

// Edge-cases: zero-length, single full block, single partial (8 bytes), small length
task automatic test_edge_cases();
    $display("\n--- test_edge_cases ---");

    // 1) Zero-length message (should still process: send one beat with len=0 and tlast=1)
    // According to AXIS semantics we still need to send a beat; we will send a 0-length final beat.
    // mode = 1'b1; // 512-bit mode
    // send_packet_and_check("edge zero-length (mode=512)", 0);

    // 2) Single full block
    mode = 1'b1;
    @(posedge clk);
    send_packet_and_check("edge single full block (mode=512)", 64);

    // 3) Single partial block: 8 bytes example -> tkeep = 64'hFF
    mode = 1'b0; // 256-bit mode (exercise both modes)
    @(posedge clk);
    send_packet_and_check("edge single partial 8B (mode=256)", 8);

    // 4) small length (e.g., 33 bytes crossing boundary)
    mode = 1'b1;
    @(posedge clk);
    send_packet_and_check("edge 33 bytes (mode=512)", 33);
endtask : test_edge_cases

// Random packets: random lengths (1..512 bytes) to exercise segmentation
task automatic test_random_packets(int n = ROUNDS);
    $display("\n--- test_random_packets (%0d) ---", n);
    for (int i = 0; i < n; i++) begin
        int len = $urandom_range(0, 512) + 1;
        // toggle mode sometimes
        if ($urandom_range(0,1))
            mode = 1'b1;
        else
            mode = 1'b0;
        @(posedge clk);
        send_packet_and_check($sformatf("random packet #%0d len=%0d mode=%0d", i, len, mode), len);
    end
endtask : test_random_packets

// Back-to-back attempt: try to submit second packet immediately and assert that
// DUTs do not accept it if busy (we test that at least one ready signal is de-asserted)
task automatic test_back_to_back();
    logic [511:0] block;
    int chunk;
    // create a short message of two beats so DUT will be busy after first
    int total_len1 = 128; // two full blocks
    int total_len2 = 64;
    // build and send two beats manually, but do not wait for final capturing here
    int remaining = total_len1;

    // wait outputs and discard in this test (we rely on generic tests for functional check)
    logic [511:0] g_naive, g_reverse, g_precalc;
    logic [63:0]  k_naive, k_reverse, k_precalc;
    logic g_naive_last, g_reverse_last, g_precalc_last;
    bit ok1, ok2, ok3;
    logic [511:0] expected_out;

    mode = 1'b1;
    @(posedge clk);
    $display("\n--- test_back_to_back ---");
    // send first packet (without waiting for result)
    tb_stribog_init(mode);
    while (remaining > 0) begin
        chunk = (remaining >= 64) ? 64 : remaining;
        block = '0;
        for (int b = 0; b < chunk; b++)
            block[b*8 +: 8] = $urandom_range(0,255);
        // wait all ready and send
        wait_all_ready();
        s_axis_tdata = block;
        s_axis_tkeep = tkeep_from_len(chunk);
        s_axis_tlast = (remaining - chunk == 0);
        s_axis_tvalid = 1'b1;
        @(posedge clk);
        // acknowledged by all (we waited ready), update DPI and deassert
        tb_stribog_update(block, chunk);
        s_axis_tvalid = 1'b0;
        remaining -= chunk;
        @(posedge clk);
    end
    // Immediately try to send second packet on next cycle without waiting for all DUTs to become ready
    // Prepare second packet first beat
    block = '0;
    for (int b = 0; b < 64; b++) block[b*8 +: 8] = $urandom_range(0,255);
    // Sample ready signals on next cycle
    @(posedge clk);
    if (s_axis_tready_naive && s_axis_tready_reverse && s_axis_tready_precalc) begin
        $display("[WARN] back-to-back: unexpectedly all DUTs reported ready immediately after submit");
    end else begin
        $display("[INFO] back-to-back: DUTs reported busy as expected (ready_naive=%b ready_reverse=%b ready_precalc=%b)",
                 s_axis_tready_naive, s_axis_tready_reverse, s_axis_tready_precalc);
    end

    // Now wait for completion and then send second packet using standard flow and verify it
    // finish first packet using final + capture through helper to keep logs consistent
    expected_out = tb_stribog_final(); // finalize first
    wait_for_all_outputs(INT_TIMEOUT_CYCLES, g_naive, k_naive, g_naive_last, ok1,
                                            g_reverse, k_reverse, g_reverse_last, ok2,
                                            g_precalc, k_precalc, g_precalc_last, ok3);
    // Now send second packet normally via helper
    send_packet_and_check("back-to-back recovery packet", total_len2);
endtask : test_back_to_back

// Reset midstream: assert reset while a packet is being processed, then resume and verify correctness
task automatic test_reset_midstream();
    // prepare a 3-beat message
    int msg_len = 200; // multiple beats
    // Collect blocks to an array to be able to resend after reset
    logic [511:0] blocks[0:7]; // enough for msg_len<=512 -> up to 8 blocks
    int block_cnt = 0;
    int remaining = msg_len;

    $display("\n--- test_reset_midstream ---");
    // initialize DPI ctx and also store full message blocks to replay after reset
    tb_stribog_init(1'b1);
    while (remaining > 0) begin
        int chunk = (remaining >= 64) ? 64 : remaining;
        blocks[block_cnt] = '0;
        for (int b = 0; b < chunk; b++) blocks[block_cnt][b*8 +: 8] = $urandom_range(0,255);
        // send first two blocks, then issue reset in-flight
        if (block_cnt < 2) begin
            send_block_and_update_last(blocks[block_cnt], chunk, 0);
        end
        remaining -= chunk;
        block_cnt++;
    end
    // Now assert reset midstream
    repeat (1) @(posedge clk);
    rst_n = 1'b0;
    @(posedge clk);
    rst_n = 1'b1;
    // Re-send the same packet from scratch and compare result
    // mode = 512
    mode = 1'b1;
    @(posedge clk);
    send_packet_and_check("reset midstream replay", msg_len);
endtask : test_reset_midstream

// -----------------------------------------------------------------------------
// Top-level test sequence
// -----------------------------------------------------------------------------
initial begin
    $display("\n=== hash Testbench ===");
    // init input signals
    rst_n = 1'b0;
    mode = 1'b1;
    @(posedge clk);
    s_axis_tdata = '0; s_axis_tvalid = 1'b0; s_axis_tkeep = '0; s_axis_tlast = 1'b0;

    // reset release
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // Run tests
    test_edge_cases();
    test_random_packets(ROUNDS);
    test_back_to_back();
    test_reset_midstream();

    // Summary
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
always @(m_naive_data or m_reverse_data or m_precalc_data) begin
    if (^m_naive_data === 1'bx)  $warning("m_naive_data contains X/Z at time %0t", $time);
    if (^m_reverse_data === 1'bx) $warning("m_reverse_data contains X/Z at time %0t", $time);
    if (^m_precalc_data === 1'bx) $warning("m_precalc_data contains X/Z at time %0t", $time);
end

endmodule : tb_hash

`default_nettype wire
