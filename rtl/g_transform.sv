// -----------------------------------------------------------------------------
// G Transform (g_N(h, m))
// Performs up to 13 internal rounds using LPSX transformations to update the
// hash state.
//
// High-level behaviour:
//  - IDLE   : wait for new message (s_axis_m_tvalid). Start key scheduling
//             by asserting i_valid_key so lpsx_for_key starts producing.
//  - WAIT   : transient state used when lpsx_for_key is sequential and the
//             first key (or subsequent key) is not yet available in the same
//             cycle as handshake; continue requesting key until o_valid_key.
//  - RUNNING: process rounds 1..12. On each lpsx_for_key completion (o_valid_key)
//             advance round counter. Also run lpsx_for_m in parallel (i_valid_m).
//  - READY  : compute and present final o_h_data, assert o_h_valid for one cycle,
//             then return to IDLE.
//
// Notes on concurrency and ordering:
//  - Two LPSX instances are instantiated:
//      * lpsx_for_key : generates the key stream (K1..K13).
//      * lpsx_for_m   : applies current key to m_reg to produce next m_reg.
//  - Typical timeline (per your design):
//      1) On entering IDLE with s_axis_m_tvalid, lpsx_for_key is requested to
//         produce K1 (i_valid_key asserted).
//      2) When K1 is produced (o_valid_key), key_reg captures it.
//      3) On next round the lpsx_for_m uses the captured key_reg to compute
//         the first message round; at the same time lpsx_for_key is asked to
//         produce K2. Thus from round 2 onward both lpsx instances work in
//         parallel: lpsx_for_m consumes previous key while lpsx_for_key
//         produces the next key.
//  - WAIT exists to support sequential lpsx_for_key: if lpsx_for_key cannot
//    complete within the same cycle, WAIT keeps asserting i_valid_key until
//    o_valid_key appears.
// -----------------------------------------------------------------------------

module g_transform # (
    parameter USE_S_RE = 1,                 // 1 -> use s_transform_rc module, 0 -> use naive method
    parameter USE_PRECALC = 1               // 1 -> use ls_transform_rom module, 0 -> use naive method (or s_transform_rc)
)(
    input  logic clk,                       // Clock
    input  logic rst_n,                     // Synchronous reset active low

    input  logic [511:0] i_h_data,          // Input h signal in gN(h, m)
    input  logic [511:0] i_N_data,          // Input N signal in gN(h, m)

    input  logic [511:0] s_axis_m_tdata,    // Input m signal (message block)
    input  logic         s_axis_m_tvalid,   // Input message valid
    output logic         s_axis_m_tready,   // Ready to accept new message

    output logic [511:0] o_h_data,          // Output hash result
    output logic         o_h_valid          // Output valid
);

// -----------------------------------------------------------------------------
// Constants
// -----------------------------------------------------------------------------
// Round constants table C[0..11]
// These 512-bit constants are used as the B-input for key schedule in
// rounds 1..12. The 13th round uses zero as B per algorithm semantics.
// -----------------------------------------------------------------------------
const logic [511:0] C[0:11] = {
    512'hb1085bda1ecadae9ebcb2f81c0657c1f2f6a76432e45d016714eb88d7585c4fc4b7ce09192676901a2422a08a460d31505767436cc744d23dd806559f2a64507,
    512'h6fa3b58aa99d2f1a4fe39d460f70b5d7f3feea720a232b9861d55e0f16b501319ab5176b12d699585cb561c2db0aa7ca55dda21bd7cbcd56e679047021b19bb7,
    512'hf574dcac2bce2fc70a39fc286a3d843506f15e5f529c1f8bf2ea7514b1297b7bd3e20fe490359eb1c1c93a376062db09c2b6f443867adb31991e96f50aba0ab2,
    512'hef1fdfb3e81566d2f948e1a05d71e4dd488e857e335c3c7d9d721cad685e353fa9d72c82ed03d675d8b71333935203be3453eaa193e837f1220cbebc84e3d12e,
    512'h4bea6bacad4747999a3f410c6ca923637f151c1f1686104a359e35d7800fffbdbfcd1747253af5a3dfff00b723271a167a56a27ea9ea63f5601758fd7c6cfe57,
    512'hae4faeae1d3ad3d96fa4c33b7a3039c02d66c4f95142a46c187f9ab49af08ec6cffaa6b71c9ab7b40af21f66c2bec6b6bf71c57236904f35fa68407a46647d6e,
    512'hf4c70e16eeaac5ec51ac86febf240954399ec6c7e6bf87c9d3473e33197a93c90992abc52d822c3706476983284a05043517454ca23c4af38886564d3a14d493,
    512'h9b1f5b424d93c9a703e7aa020c6e41414eb7f8719c36de1e89b4443b4ddbc49af4892bcb929b069069d18d2bd1a5c42f36acc2355951a8d9a47f0dd4bf02e71e,
    512'h378f5a541631229b944c9ad8ec165fde3a7d3a1b258942243cd955b7e00d0984800a440bdbb2ceb17b2b8a9aa6079c540e38dc92cb1f2a607261445183235adb,
    512'habbedea680056f52382ae548b2e4f3f38941e71cff8a78db1fffe18a1b3361039fe76702af69334b7a1e6c303b7652f43698fad1153bb6c374b4c7fb98459ced,
    512'h7bcd9ed0efc889fb3002c6cd635afe94d8fa6bbbebab076120018021148466798a1d71efea48b9caefbacd1d7d476e98dea2594ac06fd85d6bcaa4cd81f32d1b,
    512'h378ee767f11631bad21380b00449b17acda43c32bcdf1d77f82012d430219f9b5d80ef9d1891cc86e71da4aa88e12852faf417d5d9b21b9948bc924af11bd720
};

// -----------------------------------------------------------------------------
// Registers
// -----------------------------------------------------------------------------
// key_reg : stores last accepted key (updated on o_valid_key)
// m_reg   : stores current message state (updated each round by lpsx_for_m)
// m_xor_h_reg : stores (m ^ h) captured at the start of the G-transform
// -----------------------------------------------------------------------------
logic [511:0] key_reg;
logic [511:0] m_reg;
logic [511:0] m_xor_h_reg;

// -----------------------------------------------------------------------------
// LPSX interface signals (two parallel transforms)
// i_data_a_key / i_data_b_key : inputs for key schedule LPSX
// i_valid_key : request for key LPSX to start/continue work
// o_data_key / o_valid_key : produced key and its valid flag
// -----------------------------------------------------------------------------
logic [511:0] i_data_a_key;
logic [511:0] i_data_b_key;
logic         i_valid_key;
logic [511:0] o_data_key;
logic         o_valid_key;

// For m-transform
logic [511:0] o_data_m;
logic         o_valid_m;
logic         i_valid_m;

// -----------------------------------------------------------------------------
// FSM + round counter
// -----------------------------------------------------------------------------
// state     : current FSM state (IDLE, RUNNING, WAIT, READY)
// round_cnt : count of accepted keys (0..12). Semantics: number of keys
//             already produced and captured in key_reg sequence.
// -----------------------------------------------------------------------------
typedef enum logic [1:0] {IDLE, RUNNING, WAIT, READY} statetype;
statetype state, nextstate;

logic [3:0] round_cnt; // needs to represent 0..12

// ---------------------------- FSM sequential ---------------------------------
always_ff @(posedge clk) begin : proc_state
    if (~rst_n) begin
        state     <= IDLE;
    end else begin
        state     <= nextstate;
    end
end

// -----------------------------------------------------------------------------
// FSM combinational
// -----------------------------------------------------------------------------
// Next-state logic:
//  - IDLE: on incoming m (s_axis_m_tvalid) request first key. If the key
//          appears in the same cycle (o_valid_key), immediately go to RUNNING,
//          otherwise enter WAIT (keep requesting key).
//  - RUNNING: when keys keep arriving advance rounds; if no key this cycle go
//             to WAIT to continue requesting it.
//  - WAIT:  stay until o_valid_key asserted, then go to RUNNING or READY
//  - READY: present final value for one cycle then IDLE
//
// This structure implements the concurrent behaviour:
//  - first the key LPSX runs to produce K1;
//  - then in subsequent cycles lpsx_for_m and lpsx_for_key operate in
//    a pipelined fashion (m-transform consumes previous key while key LPSX
//    computes the next key).
// -----------------------------------------------------------------------------
always_comb begin
    case (state)
        IDLE: begin
            if (s_axis_m_tvalid) begin
                if (o_valid_key)
                    nextstate = RUNNING;
                else
                    nextstate = WAIT;
            end
            else
                nextstate = IDLE;
        end
        RUNNING: begin
            if (o_valid_key) begin
                if (round_cnt >= 4'd11)
                    nextstate = READY;
                else
                    nextstate = RUNNING;
            end
            else
                nextstate = WAIT;
        end
        WAIT: begin
            if (o_valid_key)
                if (round_cnt >= 4'd12)
                    nextstate = READY;
                else
                    nextstate = RUNNING;
            else
                nextstate = WAIT;
        end
        READY:   nextstate = IDLE; // Present output for one cycle, then back to IDLE
        default: nextstate = IDLE;
    endcase
end

// -----------------------------------------------------------------------------
// Round counter logic
// -----------------------------------------------------------------------------
// round_cnt tracks number of accepted keys. It is advanced in RUNNING state
// (on each cycle when keys are accepted); it remains stable in WAIT and is
// reset on READY/IDLE. This encoding pairs with the FSM above to ensure that
// both combinational and sequential lpsx_for_key implementations behave
// correctly: WAIT exists to cover sequential key generation latency.
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (~rst_n) begin
        round_cnt <= 4'd0;
    end else begin
        case (state)
            RUNNING: begin
                if (round_cnt < 4'd13) round_cnt <= round_cnt + 4'd1;
            end
            WAIT: round_cnt <= round_cnt;
            READY: begin
                round_cnt <= 4'd0;
            end
            default: round_cnt <= 4'd0;
        endcase
    end
end

// -----------------------------------------------------------------------------
// Latching registers
// -----------------------------------------------------------------------------
// key_reg updated on each key result (o_valid_key) — stable storage of last key.
// This allows lpsx_for_m to read key_reg without race conditions once it
// has been captured.
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (~rst_n) begin
        key_reg <= '0;
    end else if (o_valid_key) begin
        // store the produced key
        key_reg <= o_data_key;
    end
end

// -----------------------------------------------------------------------------
// Capture input message block at start (IDLE)
// - on IDLE + s_axis_m_tvalid latch initial m_reg
// - afterwards each completed m-transform (o_valid_m) replaces m_reg
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (~rst_n) begin
        m_reg <= '0;
    end else if (state == IDLE && s_axis_m_tvalid) begin
        // latch incoming message when starting new G-transform
        m_reg <= s_axis_m_tdata;
    end else if (o_valid_m) begin
        // each round, m_reg becomes transformed result from lpsx_for_m
        m_reg <= o_data_m;
    end
end

// store m ^ h when new message arrives (captured at beginning)
always_ff @(posedge clk) begin
    if (~rst_n) begin
        m_xor_h_reg <= '0;
    end else if (state == IDLE && s_axis_m_tvalid) begin
        m_xor_h_reg <= s_axis_m_tdata ^ i_h_data;
    end
end

// -----------------------------------------------------------------------------
// Produce final o_h_data when READY. The final value is computed as:
//    o_h = last_key ^ last_m_reg ^ (initial_m ^ h)
// where last_key is the last produced key_reg and last_m_reg is the
// transformed m after the final round. This follows the algorithm flow.
// -----------------------------------------------------------------------------
assign o_h_data = key_reg ^ m_reg ^ m_xor_h_reg;


// o_h_valid asserted only in READY (one cycle)
assign o_h_valid = (state == READY);

// -----------------------------------------------------------------------------
// s_axis_m_tready - accept new message only when IDLE
// This provides simple flow-control: module accepts a new message only when
// it is not busy processing a previous one.
// -----------------------------------------------------------------------------
assign s_axis_m_tready = (state == IDLE);

// -----------------------------------------------------------------------------
// LPSX instantiations
// -----------------------------------------------------------------------------
// Two independent LPSX instances:
//  1) lpsx_for_key : drives key schedule. When i_valid_key is asserted it
//     consumes i_data_a_key / i_data_b_key and eventually asserts o_valid_key
//     together with o_data_key (the produced key).
//  2) lpsx_for_m   : consumes current m_reg and key_reg to produce next
//     message round result (o_data_m / o_valid_m).
//
// These two units are intended to work in a pipelined fashion: after K1
// is available, lpsx_for_m can start using it while lpsx_for_key computes K2.
// -----------------------------------------------------------------------------

lpsx_transform # (
    .USE_S_RE   (USE_S_RE),
    .USE_PRECALC(USE_PRECALC)
) lpsx_for_key (
    .clk     (clk),
    .rst_n   (rst_n),
    .i_data_a(i_data_a_key),
    .i_data_b(i_data_b_key),
    .i_valid (i_valid_key),
    .o_data  (o_data_key),
    .o_valid (o_valid_key)
);

lpsx_transform # (
    .USE_S_RE   (USE_S_RE),
    .USE_PRECALC(USE_PRECALC)
) lpsx_for_m (
    .clk     (clk),
    .rst_n   (rst_n),
    .i_data_a(m_reg),
    .i_data_b(key_reg),
    .i_valid (i_valid_m),
    .o_data  (o_data_m),
    .o_valid (o_valid_m)
);

// -----------------------------------------------------------------------------
// i_valid signals
// -----------------------------------------------------------------------------
// i_valid_key : request a key operation either when starting (IDLE & s_axis_m_tvalid)
//               or while RUNNING. WAIT keeps asserting i_valid_key until key
//               completes (this supports sequential lpsx_for_key).
//
// i_valid_m   : enable m-transform during RUNNING. The m-transform consumes
//               the last captured key_reg (key_reg is updated on o_valid_key).
// -----------------------------------------------------------------------------
assign i_valid_key = (state == IDLE && s_axis_m_tvalid) || (state == RUNNING);
assign i_valid_m   = (state == RUNNING);

// -----------------------------------------------------------------------------
// i_data_a_key: for first key derivation (in IDLE) use i_h_data; subsequently
//               use the last accepted key (key_reg) to chain keys.
// -----------------------------------------------------------------------------
assign i_data_a_key = (state == IDLE) ? i_h_data : key_reg;

// -----------------------------------------------------------------------------
// Choose B input (for key schedule):
//  - IDLE : use i_N_data for the first key request
//  - RUNNING : for rounds 1..12 use C[round_cnt] (per the module's indexing),
//
// Note: the mapping C[round_cnt] follows original convention used here.
// -----------------------------------------------------------------------------
always_comb begin
    if (state == IDLE) begin
        i_data_b_key = i_N_data;
    end else if (state == RUNNING && round_cnt < 4'd12) begin
        // For rounds 1..12 use table C[round_cnt] (The counter indexes from zero.)
        i_data_b_key = C[round_cnt];
    end else begin
        i_data_b_key = 512'h0;
    end
end

// -----------------------------------------------------------------------------
// End of G Transform
// -----------------------------------------------------------------------------
endmodule : g_transform
