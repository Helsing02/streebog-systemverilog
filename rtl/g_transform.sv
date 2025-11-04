// -----------------------------------------------------------------------------
// G Transform (g_N(h, m))
// Performs 13 internal rounds using LPSX transformations to update the hash
// state. This block represents the core round function in the hash algorithm.
//
// Each round combines message data, round constants (C), and current hash state.
// FSM controls round progression and output validity.
//
// NOTE: Constants C[0..11] are used for S1..S12 rounds; S13 uses zero default.
// -----------------------------------------------------------------------------

module g_transform # (
    parameter USE_S_RE = 1                  // 1 -> use s_transform_rc module, 0 -> use naive method
)(
    input logic clk,                        // Clock
    input logic rst_n,                      // Synchronous reset active low

    input logic [511:0] i_h_data,           // Input h signal in gN(h, m)
    input logic [511:0] i_N_data,           // Input N signal in gN(h, m)

    input  logic [511:0] s_axis_m_tdata,    // Input m signal in gN(h, m) (message block)
    input  logic         s_axis_m_tvalid,   // Input signal indicating the validity of a message
    output logic         s_axis_m_tready,   // Output signal indicating the module's readiness to receive a message

    output logic [511:0] o_h_data,          // Output signal of the calculation result gN(h, m)
    output logic o_h_valid                  // Output signal about the validity of the calculation result
);

// ================================= Constants =================================
// Round constants table (used for 12 rounds).
// Each 512-bit entry corresponds to one iteration's constant.
// Indexing: C[0] for S1, C[11] for S12.
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


logic [511:0] key_reg;
logic [511:0] m_reg;
logic [511:0] m_xor_h_reg;

logic [511:0] i_data_a_key;
logic [511:0] i_data_b_key;
logic         i_valid_key;

logic [511:0] o_data_key;
logic         o_valid_key;

logic [511:0] o_data_m;

logic i_valid_m;
logic o_valid_m;

// ======================== G transform calculation FSM ========================
// FSM state encoding:
//  - IDLE: Wait for valid message input.
//  - S1..S13: Execute 13 internal rounds (one per clock).
//  - READY: Output valid hash value, then return to IDLE.
typedef enum logic [4:0] {
    IDLE, S1,  S2,  S3,
    S4,   S5,  S6,  S7,
    S8,   S9,  S10, S11,
    S12,  S13, READY,
    S1_WAIT, S2_WAIT, S3_WAIT, S4_WAIT, S5_WAIT, S6_WAIT, S7_WAIT, S8_WAIT, S9_WAIT, S10_WAIT, S11_WAIT, S12_WAIT, S13_WAIT
} statetype;

statetype state, nextstate;

// Main FSM: controls round progression
// - Transitions from IDLE -> S1 when new message valid
// - Increments state each cycle until S13
// - Asserts output at READY and returns to IDLE
always_ff @(posedge clk) begin : proc_state
    if(~rst_n) begin
        state <= IDLE;
    end else begin
        state <= nextstate;
    end
end

// FSM next-state logic
// Determines next state based on current state and handshaking signals.
always_comb begin
    case (state)
        IDLE:     nextstate = (s_axis_m_tvalid == 1) ? S1 : IDLE;
        S1:       nextstate = o_valid_key ? S2 : S1_WAIT;
        S1_WAIT:  nextstate = o_valid_key ? S2 : S1_WAIT;
        S2:       nextstate = o_valid_key ? S3 : S2_WAIT;
        S2_WAIT:  nextstate = o_valid_key ? S3 : S2_WAIT;
        S3:       nextstate = o_valid_key ? S4 : S3_WAIT;
        S3_WAIT:  nextstate = o_valid_key ? S4 : S3_WAIT;
        S4:       nextstate = o_valid_key ? S5 : S4_WAIT;
        S4_WAIT:  nextstate = o_valid_key ? S5 : S4_WAIT;
        S5:       nextstate = o_valid_key ? S6 : S5_WAIT;
        S5_WAIT:  nextstate = o_valid_key ? S6 : S5_WAIT;
        S6:       nextstate = o_valid_key ? S7 : S6_WAIT;
        S6_WAIT:  nextstate = o_valid_key ? S7 : S6_WAIT;
        S7:       nextstate = o_valid_key ? S8 : S7_WAIT;
        S7_WAIT:  nextstate = o_valid_key ? S8 : S7_WAIT;
        S8:       nextstate = o_valid_key ? S9 : S8_WAIT;
        S8_WAIT:  nextstate = o_valid_key ? S9 : S8_WAIT;
        S9:       nextstate = o_valid_key ? S10 : S9_WAIT;
        S9_WAIT:  nextstate = o_valid_key ? S10 : S9_WAIT;
        S10:      nextstate = o_valid_key ? S11 : S10_WAIT;
        S10_WAIT: nextstate = o_valid_key ? S11 : S10_WAIT;
        S11:      nextstate = o_valid_key ? S12 : S11_WAIT;
        S11_WAIT: nextstate = o_valid_key ? S12 : S11_WAIT;
        S12:      nextstate = o_valid_key ? S13 : S12_WAIT;
        S12_WAIT: nextstate = o_valid_key ? S13 : S12_WAIT;
        S13:      nextstate = o_valid_key ? READY : S13_WAIT;
        S13_WAIT: nextstate = o_valid_key ? READY : S13_WAIT;
        READY:    nextstate = IDLE;
        default:  nextstate = IDLE;
    endcase
end

// Store current key value
// Obtained from output of LSPX for key
always_ff @(posedge clk) begin : proc_key_reg
    if(~rst_n) begin
        key_reg <= '0;
    end else if (o_valid_key) begin
        key_reg <= o_data_key;
    end
end

// Capture input message block when entering S1
// (Message block is XORed with hash in the first LPSX stage)
always_ff @(posedge clk) begin : proc_m_reg
    if(~rst_n) begin
        m_reg <= '0;
    end else if (state == IDLE) begin
        m_reg <= s_axis_m_tdata;
    end else if (o_valid_m) begin
        m_reg <= o_data_m;
    end
end

// Store XOR of current hash (h) and message block.
// Used to store this value until S13 state
always_ff @(posedge clk) begin : proc_m_xor_h_reg
    if(~rst_n) begin
        m_xor_h_reg <= '0;
    end else if (state == IDLE) begin
        m_xor_h_reg <= s_axis_m_tdata ^ i_h_data;
    end
end

// Latch final output hash value when FSM enters READY.
// o_h_valid asserted only during READY.
always_ff @(posedge clk) begin : proc_o_h_data
    if(~rst_n) begin
        o_h_data <= '0;
    end else if (state == S13 || state == S13_WAIT) begin
        o_h_data <= key_reg ^ m_reg ^ m_xor_h_reg;
    end
end

// Instantite two LPSX
lpsx_transform # (
    .USE_S_RE(USE_S_RE)
) lpsx_for_key (
    .clk     (clk),
    .rst_n   (rst_n),

    .i_data_a(i_data_a_key),
    .i_data_b(i_data_b_key),
    .i_valid (i_valid_key),

    .o_data  (o_data_key),
    .o_valid (o_valid_key)
);

assign i_valid_key = (state >= S1) && (state <= S13);

lpsx_transform # (
    .USE_S_RE(USE_S_RE)
) lpsx_for_m (
    .clk     (clk),
    .rst_n   (rst_n),

    .i_data_a(m_reg),
    .i_data_b(key_reg),
    .i_valid (i_valid_m),

    .o_data  (o_data_m),
    .o_valid (o_valid_m)
);

assign i_valid_m = (state >= S2) && (state <= S12);

assign i_data_a_key = (state == IDLE) ? i_h_data : key_reg;

// Select B input (key schedule):
// - Use N_data during IDLE
// - Use round constant C[state-1] for S1..S12
// NOTICE: Protected against out-of-range index (S13/READY)
logic [511:0] C_sel;
always_comb begin
    if (state == IDLE) begin
        C_sel = i_N_data;
    end else if ((state >= S2) && (state <= S13)) begin
        C_sel = C[state - 2];
    end else begin
        C_sel = 512'h0; // or appropriate value for S13/READY
    end
end
assign i_data_b_key = C_sel;

// Handshake and output assignments:
// - s_axis_m_tready is high only in IDLE
// - o_h_valid asserted in READY
// - Output data latched from internal o_h_data register
assign o_h_valid = (state == READY);
assign s_axis_m_tready = (state == IDLE);


// -----------------------------------------------------------------------------
// End of g_transform
// -----------------------------------------------------------------------------
endmodule : g_transform
