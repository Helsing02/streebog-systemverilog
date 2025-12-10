// -----------------------------------------------------------------------------
// HASH top-level controller
// Orchestrates padding, block processing (G transform), accumulation of N and Sigma,
// and final output formatting (256/512-bit modes).
//
// Behaviour summary:
//  - Accepts AXIS-like message blocks (s_axis_*). Each packet is processed as a
//    sequence of chunks (0..64 bytes per beat). The module accepts a new packet
//    only while in IDLE state (simple flow-control).
//  - For each accepted block the controller drives g_transform multiple times:
//      * first: process message block rounds (PROCESS)
//      * optionally: PROCESS_CONST1 (inject constant 1) for full final block
//      * FINAL_N : inject N (message length in bits) as a block
//      * FINAL_SIG : inject Sigma accumulator as a block
//  - Uses `last_req` to remember what request was sent to g_transform so that
//    when g_transform asserts o_h_valid we update accumulators deterministically.
//
// Notes:
//  - RESET is synchronous active-low (rst_n).
//  - mode==1 => 512-bit output; mode==0 => 256-bit output.
// -----------------------------------------------------------------------------

module hash # (
    parameter USE_S_RE = 1,
    parameter USE_PRECALC = 1,
    parameter USE_DSP = 1
)(
    input  logic         clk,
    input  logic         rst_n,

    input  logic         mode,                   // 1 => 512-bit output, 0 => 256-bit output

    // AXI-Stream-like input (message blocks)
    input  logic [511:0] s_axis_tdata,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic [63:0]  s_axis_tkeep,
    input  logic         s_axis_tlast,

    // AXI-Stream-like output (hash result)
    output logic [511:0] m_axis_tdata,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,
    output logic [63:0]  m_axis_tkeep,
    output logic         m_axis_tlast
);

// -----------------------------------------------------------------------------
// Constants and Type Definitions
// -----------------------------------------------------------------------------
localparam logic [63:0] KEEP_512 = {64{1'b1}};
localparam logic [63:0] KEEP_256 = {{32{1'b0}}, {32{1'b1}}};

// -----------------------------------------------------------------------------
// State and Control Signals
// -----------------------------------------------------------------------------
typedef enum logic [2:0] {
    IDLE,
    PROCESS,
    PROCESS_CONST1,
    FINAL_N,
    FINAL_SIG,
    OUTPUT
} state_t;

state_t state, nextstate;

logic transform_in_progress;
logic last_block_received;
logic is_complete_block;

// -----------------------------------------------------------------------------
// Data Path Registers
// -----------------------------------------------------------------------------
logic [511:0] h_reg;         // Hash state register
logic [511:0] m_reg;         // Latched padded block
logic [511:0] Sigma_reg;     // Accumulator Σ
logic [508:0] N_reg;         // Accumulator N (bytes)
logic [6:0]   weight_m_reg;  // Byte weight of current block

// -----------------------------------------------------------------------------
// Intermediate Calculations
// -----------------------------------------------------------------------------
logic [511:0] N;             // Bit-length (N_reg << 3)
logic [511:0] next_Sigma_value;
logic [508:0] next_N_value;
logic [6:0]   weight_m;

// -----------------------------------------------------------------------------
// AXI Stream Interface Signals
// -----------------------------------------------------------------------------
logic [511:0] s_axis_tdata_reg;
logic         s_axis_tvalid_reg;
logic         s_axis_tready_reg;
logic [63:0]  s_axis_tkeep_reg;
logic         s_axis_tlast_reg;

logic input_handshake;
logic output_handshake;
logic input_valid_gated;
logic internal_input_ready;

// -----------------------------------------------------------------------------
// g_transform Interface Signals
// -----------------------------------------------------------------------------
logic [511:0] padded_data;   // Padded message block
logic [511:0] i_N_data;      // Current N value fed into g_transform
logic [511:0] o_h_data;      // Output of g_transform
logic         o_h_valid;     // Completion flag from g_transform

logic [511:0] s_axis_m_tdata;
logic         s_axis_m_tvalid;
logic         s_axis_m_tready;

// -----------------------------------------------------------------------------
// Initialization Constants
// -----------------------------------------------------------------------------
logic [511:0] IV;
assign IV           = (mode == 1) ? 512'h0 : {64{8'h01}};
assign m_axis_tkeep = (mode == 1) ? KEEP_512 : KEEP_256;
assign m_axis_tlast = 1'b1;

// -----------------------------------------------------------------------------
// Helper Functions
// -----------------------------------------------------------------------------
function automatic logic [6:0] popcount(input logic [63:0] data);
    return $countones(data);
endfunction

// -----------------------------------------------------------------------------
// Input Pipeline Stage
// -----------------------------------------------------------------------------
assign input_valid_gated = s_axis_tvalid && !last_block_received;
assign s_axis_tready = internal_input_ready && !last_block_received;

axis_register #(
    .DATA_WIDTH (512),
    .USER_ENABLE(0),
    .REG_TYPE   (1)
) axis_reg_inst (
    .clk(clk),
    .rst(~rst_n),

    .s_axis_tdata (padded_data),
    .s_axis_tvalid(input_valid_gated),
    .s_axis_tready(internal_input_ready),
    .s_axis_tkeep (s_axis_tkeep),
    .s_axis_tlast (s_axis_tlast),

    .m_axis_tdata (s_axis_tdata_reg),
    .m_axis_tvalid(s_axis_tvalid_reg),
    .m_axis_tready(s_axis_tready_reg),
    .m_axis_tkeep (s_axis_tkeep_reg),
    .m_axis_tlast (s_axis_tlast_reg)
);

assign input_handshake  = s_axis_tvalid_reg && s_axis_tready_reg;
assign output_handshake = m_axis_tvalid && m_axis_tready;

// -----------------------------------------------------------------------------
// Padding Stage
// -----------------------------------------------------------------------------
padding padding_inst (
    .i_data(s_axis_tdata),
    .i_keep(s_axis_tkeep),
    .o_data(padded_data)
);

// -----------------------------------------------------------------------------
// Input Data Capture
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (~rst_n) begin
        m_reg <= '0;
    end else if (input_handshake) begin
        m_reg <= s_axis_tdata_reg;
    end
end

// -----------------------------------------------------------------------------
// Byte Weight Calculation
// -----------------------------------------------------------------------------
assign weight_m = popcount(s_axis_tkeep_reg);

always_ff @(posedge clk) begin
    if (~rst_n) begin
        weight_m_reg <= 7'd0;
    end else if (input_handshake) begin
        weight_m_reg <= weight_m;
    end
end

// -----------------------------------------------------------------------------
// Accumulators (N and Sigma)
// -----------------------------------------------------------------------------
assign N = N_reg << 3; // Convert bytes → bits

// N accumulator: total bytes processed
adder_512bit #(
    .USE_DSP(USE_DSP)
) N_adder (
    .clk  (clk),
    .rst_n(rst_n),

    .valid_in(state == PROCESS && transform_in_progress),

    .operand_a    ({3'd0, N_reg}),
    .operand_b    ({505'd0, weight_m_reg}),
    .sum_out  (next_N_value)
);

// Sigma accumulator: sum of all message blocks
adder_512bit #(
    .USE_DSP(USE_DSP)
) Sigma_adder (
    .clk  (clk),
    .rst_n(rst_n),

    .valid_in(state == PROCESS && transform_in_progress),

    .operand_a    (Sigma_reg),
    .operand_b    (m_reg),
    .sum_out  (next_Sigma_value)
);

logic [511:0] next_Sigma_value_check;
assign next_Sigma_value_check = Sigma_reg + m_reg - next_Sigma_value;

always_ff @(posedge clk) begin
    if (~rst_n || (state == OUTPUT)) begin
        N_reg     <= '0;
        Sigma_reg <= '0;
    end else if (o_h_valid) begin
        if (state == PROCESS && o_h_valid) begin
            N_reg     <= next_N_value;
            Sigma_reg <= next_Sigma_value;
        end else if (state == PROCESS_CONST1) begin
            Sigma_reg <= Sigma_reg + 512'h1;
        end
    end
end

// -----------------------------------------------------------------------------
// Hash State Management
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (~rst_n || (state == IDLE && s_axis_tvalid && s_axis_tready)) begin
        h_reg <= IV;
    end else if (o_h_valid) begin
        h_reg <= o_h_data;
    end
end

// -----------------------------------------------------------------------------
// g_transform Instance
// -----------------------------------------------------------------------------
g_transform #(
    .USE_S_RE   (USE_S_RE),
    .USE_PRECALC(USE_PRECALC)
) g_inst (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_h_data       (h_reg),
    .i_N_data       (i_N_data),
    .s_axis_m_tdata (s_axis_m_tdata),
    .s_axis_m_tvalid(s_axis_m_tvalid),
    .s_axis_m_tready(s_axis_m_tready),
    .o_h_data       (o_h_data),
    .o_h_valid      (o_h_valid)
);

assign i_N_data = (state == PROCESS || state == PROCESS_CONST1) ? N : 512'h0;

// -----------------------------------------------------------------------------
// Transform Busy Logic
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin : proc_transform_in_progress
    if(~rst_n) begin
        transform_in_progress <= 1'b0;
    end else if (s_axis_m_tvalid) begin
        transform_in_progress <= 1'b1;
    end else if (o_h_valid) begin
        transform_in_progress <= 1'b0;
    end
end

// -----------------------------------------------------------------------------
// Input Status Tracking
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if(~rst_n || (state == OUTPUT)) begin
        last_block_received  <= 1'b0;
    end else if (input_handshake && s_axis_tlast_reg) begin
        last_block_received  <= 1'b1;
    end
end

always_ff @(posedge clk) begin
    if(~rst_n) begin
        is_complete_block <= 1'b0;
    end else if (input_handshake && |s_axis_tkeep_reg) begin
        is_complete_block <= &s_axis_tkeep_reg;
    end
end

// -----------------------------------------------------------------------------
// FSM State Transition
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (~rst_n) begin
        state <= IDLE;
    end else begin
        state <= nextstate;
    end
end

// -----------------------------------------------------------------------------
// FSM Next State Logic
// -----------------------------------------------------------------------------
always_comb begin
    unique case (state)
        IDLE: begin
            if (s_axis_tvalid && s_axis_tready) begin
                nextstate = PROCESS;
            end else begin
                nextstate = IDLE;
            end
        end

        PROCESS: begin
            if ((last_block_received && o_h_valid) || (s_axis_tlast_reg && !(|s_axis_tkeep_reg))) begin
                nextstate = is_complete_block ? PROCESS_CONST1 : FINAL_N;
            end else begin
                nextstate = PROCESS;
            end
        end

        PROCESS_CONST1: begin
            nextstate = o_h_valid ? FINAL_N : PROCESS_CONST1;
        end

        FINAL_N: begin
            nextstate = o_h_valid ? FINAL_SIG : FINAL_N;
        end

        FINAL_SIG: begin
            if (o_h_valid) begin
                nextstate = last_block_received ? OUTPUT : IDLE;
            end else begin
                nextstate = FINAL_SIG;
            end
        end

        OUTPUT: begin
            nextstate = m_axis_tready ? IDLE : OUTPUT;
        end

        default: begin
            nextstate = IDLE;
        end
    endcase
end

// -----------------------------------------------------------------------------
// g_transform Control Signals
// -----------------------------------------------------------------------------
assign s_axis_tready_reg   = rst_n && (state == IDLE || ~transform_in_progress && state == PROCESS);
assign s_axis_m_tvalid = ~transform_in_progress && ((input_handshake && |s_axis_tkeep_reg) || (state > PROCESS && state < OUTPUT));

always_comb begin
    unique case (state)
        PROCESS:        s_axis_m_tdata = s_axis_tdata_reg;
        PROCESS_CONST1: s_axis_m_tdata = 512'h1;
        FINAL_N:        s_axis_m_tdata = N;
        FINAL_SIG:      s_axis_m_tdata = Sigma_reg;
        default:        s_axis_m_tdata = s_axis_tdata_reg;
    endcase
end

// -----------------------------------------------------------------------------
// Output Interface
// -----------------------------------------------------------------------------
assign m_axis_tdata  = mode ? h_reg : {256'h0, h_reg[511:256]};
assign m_axis_tvalid = (state == OUTPUT);

// -----------------------------------------------------------------------------
// End of Hash
// -----------------------------------------------------------------------------
endmodule : hash
