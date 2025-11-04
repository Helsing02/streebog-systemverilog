// -----------------------------------------------------------------------------
// HASH top-level controller
// Orchestrates padding, block processing (G transform), accumulation of N and Sigma,
// and final output formatting (256/512-bit modes).
//
// Key responsibilities:
//  - Receive streamed input blocks (s_axis_*), apply padding and feed blocks to G.
//  - Maintain running counters: N (total processed bits) and Sigma (sum of message blocks).
//  - Drive g_transform submodule and react to its o_h_valid to update h_reg.
//  - Produce final hash on m_axis_* when processing completes.
// Notes:
//  - RESET is synchronous active-low (rst_n).
//  - mode==1 => 512-bit output; mode==0 => 256-bit output (upper 256 bits discarded).
// -----------------------------------------------------------------------------

module hash # (
    parameter USE_S_RE = 1,             // 1 -> use s_transform_rc module, 0 -> use naive method
    parameter USE_PRECALC = 1
)(
    input logic clk,                    // Clock
    input logic rst_n,                  // Synchronous reset active low

    input logic mode,                   // Algorithm operating mode (1-512 bit, 0-256 bit)

    input  logic [511:0] s_axis_tdata,  // Input message block
    input  logic         s_axis_tvalid, // Input message validity
    output logic         s_axis_tready, // Module readiness to accept an input block
    input  logic [63:0]  s_axis_tkeep,  // Valid bytes in s_axis_tdata
    input  logic         s_axis_tlast,  // Signal of the last block of the input message

    output logic [511:0] m_axis_tdata,  // Output hash result
    output logic         m_axis_tvalid, // Output hash validity
    input  logic         m_axis_tready, // Signal of readiness to accept the calculated hash
    output logic [63:0]  m_axis_tkeep,  // Valid bytes in hash (m_axis_tdata)
    output logic         m_axis_tlast   // Signal of the last block of the output hash
);

// Count set bits in 64-bit keep mask.
// Returns number of valid bytes in the incoming AXIS beat (0..64).
// Implemented as simple loop — synthesizable and predictable.
// Used to compute message length in bytes for the last block.
function automatic logic [7:0] popcount(input logic [63:0] data);
    logic [7:0] result;
    integer i;
    begin
        result = '0;
        for (i = 0; i < 64; i++)
            result += data[i];
        popcount = result;
    end
endfunction

// Internal top-level signals:
//  - padded_data : block after padding (512 bits)
//  - i_N_data    : value forwarded to g_transform as N (may be zeroed in some states)
//  - o_h_data    : result from g_transform
//  - IV          : initial vector (depends on mode)
// These wires are shared between the main FSM and the block-processing FSM.
logic [511:0] padded_data;
logic [511:0] i_N_data;
logic [511:0] o_h_data;
logic         o_h_valid;
logic [511:0] IV;

// FSM outputs
logic M;                    // Main FSM
logic main_m_tvalid;        // Main FSM
logic R;                    // Message block processing FSM
logic block_hash_m_tvalid;  // Message block processing FSM


// ======================= Message block processing FSM ========================
// Block processing FSM (R pipeline):
//  - Controls the per-block interaction with g_transform.
//  - Sequence: BLOCK_IDLE -> T1 (start g transform) -> wait for o_h_valid -> T3 (finish).
//  - R is asserted in T3 to indicate block processing completed and registers
//    (N_reg, Sigma_reg, h_reg) should be updated on that cycle.
typedef enum logic [1:0] {
    BLOCK_IDLE, T1, T2, T3
} block_hash_state_t;

block_hash_state_t block_hash_state, block_hash_nextstate;

// Sequential register for the block-processing FSM (synchronous state update).
// Uses synchronous active-low reset to return to BLOCK_IDLE.
always_ff @(posedge clk) begin : proc_block_hash_state
    if(~rst_n) begin
        block_hash_state <= BLOCK_IDLE;
    end else begin
        block_hash_state <= block_hash_nextstate;
    end
end

// Combinational next-state logic for block-processing FSM.
// - T1 -> launch g_transform (block_hash_m_tvalid asserted).
// - T2 -> wait until g_transform asserts o_h_valid.
// - T3 -> handshake complete, update accumulators.
always_comb begin
    case (block_hash_state)
        BLOCK_IDLE:    block_hash_nextstate = (M) ? T1 : BLOCK_IDLE;
        T1:      block_hash_nextstate = T2;
        T2:      block_hash_nextstate = (o_h_valid) ? T3 : T2;
        T3:      block_hash_nextstate = BLOCK_IDLE;
        default: block_hash_nextstate = BLOCK_IDLE;
    endcase
end

// Outputs
assign R = block_hash_state == T3;
assign block_hash_m_tvalid = block_hash_state == T1;


// ================================= Main FSM ==================================
// Main FSM: controls overall message flow and phases.
// States:
//  - INITIAL : resets internal accumulators (IV, N_reg, Sigma_reg).
//  - IDLE    : wait for s_axis_tvalid to start processing.
//  - S2..S9 : phases that compose message handling, N/Sigma processing and finalization.
// hard_decision variable computes the next state when leaving IDLE based on incoming
// AXIS control signals (tvalid, tlast, tkeep).

// Main controller state encoding.
// Keep mapping in sync with comments in code that select s_axis_m_tdata and i_N_data.
typedef enum logic [3:0] {
    INITIAL, IDLE, S2, S3,
    S4,      S5,   S6, S7,
    S8,      S9,   READY
} main_state_t;

main_state_t main_state, main_nextstate;

// Synchronous state register for main FSM (synchronous reset).
// On reset go to INITIAL which will also reinitialize h_reg, N_reg and Sigma_reg.
always_ff @(posedge clk) begin : proc_main_state
    if(~rst_n) begin
        main_state <= INITIAL;
    end else begin
        main_state <= main_nextstate;
    end
end

// IDLE: decide next state based on incoming AXIS signals
// - if no tvalid, remain IDLE
// - if tvalid and not tlast -> S2 (full block, not last)
// - if tvalid and tlast and all keep bytes valid (&s_axis_tkeep) -> S3 (last full block)
// - else -> S5 (last partial block)
// This captures common AXI-Stream block cases and routes control accordingly.
main_state_t hard_decision;
assign hard_decision = (~s_axis_tvalid) ? IDLE :
                       (~s_axis_tlast)  ? S2   :
                       (&s_axis_tkeep)  ? S3   :
                                          S5;

// Main FSM combinational next-state logic.
// Transitions are guarded by R and o_h_valid when waiting for block completion.
// - S2/S3/S4/S5 are 'M' states (processing message blocks).
// - S6..S9 are finalization phases including N/Sigma injections and output emission.
// - READY is
always_comb begin
    case (main_state)
        INITIAL: main_nextstate = IDLE;
        IDLE:    main_nextstate = hard_decision;
        S2:      main_nextstate = (R) ? IDLE : S2;
        S3:      main_nextstate = (R) ? S4   : S3;
        S4:      main_nextstate = (R) ? S6   : S4;
        S5:      main_nextstate = (R) ? S6   : S5;
        S6:      main_nextstate = S7;
        S7:      main_nextstate = (o_h_valid) ? S8 : S7;
        S8:      main_nextstate = S9;
        S9:      main_nextstate = (o_h_valid) ? READY : S9;
        READY:     main_nextstate = (m_axis_tready) ? INITIAL : READY;
        default: main_nextstate = INITIAL;
    endcase
end

// Output encodings derived from main_state:
//  - M indicates we are in message-processing phase and should drive block FSM.
//  - s_axis_tready is asserted only in IDLE to implement simple AXIS flow-control.
assign M = (main_state == S2) || (main_state == S3) ||
           (main_state == S4) || (main_state == S5);
assign main_m_tvalid = (main_state == S6) || (main_state == S8);
assign s_axis_tready = main_state == IDLE;
assign m_axis_tvalid = main_state == READY;


// ============================ Sigma calculations =============================
// Sigma accumulator logic:
//  - Sigma_reg keeps the cumulative sum of processed message blocks (512-bit addition).
//  - new_Sigma = m_reg + Sigma_reg; update occurs when block FSM asserts R (T3).
//  - m_reg latches padded_data on each valid input beat so Sigma is the sum of padded blocks.


// Signals
logic [511:0] new_Sigma;

// Registers
logic [511:0] m_reg;
logic [511:0] Sigma_reg;

// ++++++++++++++++++++++++++ Input message block reg ++++++++++++++++++++++++++
// Latch padded input block when s_axis_tvalid is asserted.
// m_reg is the canonical block used for Sigma accumulation after processing.
always_ff @(posedge clk) begin : proc_m_reg
    if(~rst_n) begin
        m_reg <= '0;
    end else if (s_axis_tvalid && s_axis_tready) begin
        m_reg <= padded_data;
    end
end

// Wide 512-bit addition; consider mapping to DSP chains or slicing if synthesizer
// has trouble with single wide adder. This operation may be implemented as a ripple
// or carry-tree depending on target; verify timing.
assign new_Sigma = m_reg + Sigma_reg;

// +++++++++++++++++++++++++++++++++ Sigma reg +++++++++++++++++++++++++++++++++
// Update Sigma on block completion (block FSM T3).
// Also reset Sigma to zero on overall INITIAL state.
always_ff @(posedge clk) begin : proc_Sigma_reg
    if(~rst_n || main_state == INITIAL) begin
        Sigma_reg <= '0;
    end else if (block_hash_state == T3) begin
        Sigma_reg <= new_Sigma;
    end
end



// ============================== N calculations ===============================
// N accumulator logic (message length in bits):
//  - module_m (7 bits) equals number of valid bytes in the last beat (popcount of tkeep).
//  - mod_m_reg stores byte count for the current block (64 for full blocks).
//  - new_N = N_reg + (mod_m_reg << 3)  (multiply bytes by 8 -> bits).
//  - N_reg updated when block FSM indicates completion (R/T3).


// Signals
logic [511:0] new_N;
logic [6:0]   module_m;

// Registers
logic [6:0]   mod_m_reg;
logic [511:0] N_reg;

// Compute number of valid bytes for the incoming AXI beat.
// Used only when s_axis_tvalid && s_axis_tlast to account for final partial block.
assign module_m = popcount(s_axis_tkeep);

// ++++++++++++++++++++++ Input message block length reg +++++++++++++++++++++++
// Capture per-block byte count.
// If the beat is not last, assume full 64 bytes for the block.
always_ff @(posedge clk) begin : proc_mod_m_reg
    if(~rst_n) begin
        mod_m_reg <= '0;
    end else if (s_axis_tvalid && s_axis_tready) begin
        if (s_axis_tlast) begin
            mod_m_reg <= module_m;
        end else begin
            mod_m_reg <= 7'd64;
        end
    end
end

// Update total processed bits: add current block size in bits.
// Shifting left by 3 is equivalent to *8 (bytes->bits).
// Large 512-bit adder — check synthesizer mapping and timing behavior.
assign new_N = (mod_m_reg << 3) + N_reg;

// +++++++++++++++++++++++++++++++++++ N reg +++++++++++++++++++++++++++++++++++
// N accumulator register update.
// Reset to zero in INITIAL state.
// Updated when block processing completes (R/T3).
always_ff @(posedge clk) begin : proc_N_reg
    if(~rst_n || main_state == INITIAL) begin
        N_reg <= '0;
    end else if (block_hash_state == T3) begin
        N_reg <= new_N;
    end
end



// ======================== h register prosessing logic ========================
// Hash register (h_reg):
// - Initialized to IV during INITIAL state.
// - Updated with o_h_data when g_transform finishes (o_h_valid asserted).
// IV depends on mode: mode==1 => all-zero IV (512-bit), else fill with 0x01 bytes.
logic [511:0] h_reg;

// Initialization Vector selection:
// - 512-bit output mode uses zero IV per spec (mode==1).
// - 256-bit mode uses repeated 0x01 bytes as IV.
assign IV = (mode == 1) ? 512'h0 : {64{8'h01}};

// +++++++++++++++++++++++++++++++++ Hash reg ++++++++++++++++++++++++++++++++++
// h_reg sequential update:
// - On INITIAL, set to IV.
// - When g_transform indicates new h (o_h_valid) update h_reg with o_h_data.
always_ff @(posedge clk) begin : proc_h_reg
    if(~rst_n || main_state == INITIAL) begin
        h_reg <= IV;
    end else if (o_h_valid) begin
        h_reg <= o_h_data;
    end
end



// ================================ Submodules =================================
// ----------------------------- Padding submodule -----------------------------
// Padding block:
// - Expands incoming s_axis_tdata + s_axis_tkeep into a full 512-bit padded block.
// - padding implements 0x01 after last valid byte and zeros thereafter (see padding.sv).
padding padding_instance (
    .i_data(s_axis_tdata),
    .i_keep(s_axis_tkeep),
    .o_data(padded_data)
);

// --------------------------- G transform submodule ---------------------------
// G transform instance wiring:
// - s_axis_m_tdata is selected depending on main_state phases (message, N, Sigma, constant 1).
// - s_axis_m_tvalid is driven by main_m_tvalid OR block_hash_m_tvalid to support both flows.
// - i_N_data is zeroed in phases where N should not be used (main_state >= S6).
logic [511:0] s_axis_m_tdata;
logic         s_axis_m_tvalid;
logic         s_axis_m_tready;

g_transform # (
    .USE_S_RE       (USE_S_RE),
    .USE_PRECALC    (USE_PRECALC)
) g_instance (
    .clk            (clk),
    .rst_n          (rst_n),

    .i_N_data       (i_N_data),
    .i_h_data       (h_reg),
    .o_h_data       (o_h_data),
    .o_h_valid      (o_h_valid),

    .s_axis_m_tdata (s_axis_m_tdata),
    .s_axis_m_tvalid(s_axis_m_tvalid),
    .s_axis_m_tready(s_axis_m_tready)
);

// Provide N to g_transform only when appropriate.
// For finalization phases (main_state >= S6) N is forced to zero as per algorithm flow.
assign i_N_data = (main_state >= S6) ? 512'h0 : N_reg;

// Multiplex g_transform input 'm' based on main FSM phase:
//  - S4: constant 1 (algorithm-specific injection)
//  - S6: N_reg  (process N value)
//  - S8: Sigma_reg (process Sigma value)
//  - default: padded_data (regular message block)
// Keep mapping aligned with main FSM comments above.
assign s_axis_m_tdata = (main_state == S4) ? 512'h1    :
                        (main_state == S6) ? N_reg     :
                        (main_state == S8) ? Sigma_reg :
                                             padded_data;

// Drive validity to g_transform when either main FSM requests a special
// phase (main_m_tvalid) or the block-processing FSM requests processing
// of a normal message block (block_hash_m_tvalid).
//
// Both sources are mutually exclusive by state encoding, but keep OR for safety.
assign s_axis_m_tvalid = main_m_tvalid || block_hash_m_tvalid;

// Output formatting:
// - For 512-bit mode, output full h_reg.
// - For 256-bit mode, output the rightmost 256 bits (upper half shifted out).
// m_axis_tlast asserted always (single-beat response).
assign m_axis_tdata = mode ? h_reg : h_reg >> 256;

// Output AXIS metadata:
// - m_axis_tlast = 1 always (hash is a single-frame output).
// - m_axis_tkeep is full 512 or 256 mask depending on mode.
// Localparam KEEP_512 / KEEP_256 defined for clarity and to avoid recomputation.
assign m_axis_tlast = 1;

localparam logic [511:0] KEEP_512 = {64{1'b1}};
localparam logic [511:0] KEEP_256 = {{32{1'b0}}, {32{1'b1}}};
assign m_axis_tkeep = (mode == 1) ? KEEP_512 : KEEP_256;

// -----------------------------------------------------------------------------
// End of hash.sv
// -----------------------------------------------------------------------------
endmodule : hash