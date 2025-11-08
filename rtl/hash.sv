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
    parameter USE_PRECALC = 1
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
// State machine declaration
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

// -----------------------------------------------------------------------------
// Local helper: popcount(64b)
// -----------------------------------------------------------------------------
function automatic logic [6:0] popcount(input logic [63:0] data);
    logic [6:0] result;
    integer i;
    begin
        result = 0;
        for (i = 0; i < 64; i++) result += data[i];
        return result;
    end
endfunction

// -----------------------------------------------------------------------------
// Internal signals
// -----------------------------------------------------------------------------
logic [511:0] padded_data;   // Padded message block
logic [511:0] i_N_data;      // Current N value fed into g_transform
logic [511:0] o_h_data;      // Output of g_transform
logic         o_h_valid;     // Completion flag from g_transform

logic [511:0] s_axis_m_tdata;
logic         s_axis_m_tvalid;
logic         s_axis_m_tready;

logic [511:0] m_reg;         // Latched padded block
logic [511:0] Sigma_reg;     // Accumulator Σ
logic [508:0] N_reg;         // Accumulator N (bytes)
logic [511:0] h_reg;         // Hash state register

logic [6:0]   weight_m;
logic [6:0]   weight_m_reg;

logic [511:0] N;             // Bit-length (N_reg << 3)
logic [511:0] new_Sigma;
logic [508:0] new_N;

logic block_busy;
logic input_last_seen;
logic input_full_block;



// -----------------------------------------------------------------------------
// Initialization constants
// -----------------------------------------------------------------------------
localparam logic [63:0] KEEP_512 = {64{1'b1}};
localparam logic [63:0] KEEP_256 = {{32{1'b0}}, {32{1'b1}}};

logic [511:0] IV;
assign IV           = (mode == 1) ? 512'h0 : {64{8'h01}};
assign m_axis_tkeep = (mode == 1) ? KEEP_512 : KEEP_256;
assign m_axis_tlast = 1'b1;

// -----------------------------------------------------------------------------
// Input latch (capture padded block)
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (~rst_n) begin
        m_reg <= '0;
    end else if (s_axis_tvalid && s_axis_tready) begin
        m_reg <= padded_data;
    end
end

// -----------------------------------------------------------------------------
// Mod_m (bytes per block)
// -----------------------------------------------------------------------------
assign weight_m = popcount(s_axis_tkeep);

always_ff @(posedge clk) begin
    if (~rst_n) weight_m_reg <= 7'd0;
    else if (s_axis_tvalid && s_axis_tready) begin
        weight_m_reg <= s_axis_tlast ? weight_m : 7'd64;
    end
end

// -----------------------------------------------------------------------------
// Accumulators (Σ, N)
// -----------------------------------------------------------------------------
assign new_N     = N_reg + {502'd0, weight_m_reg};
assign new_Sigma = Sigma_reg + m_reg;
assign N         = N_reg << 3; // Convert bytes → bits

always_ff @(posedge clk) begin
    if (~rst_n || (state == OUTPUT)) begin
        N_reg     <= '0;
        Sigma_reg <= '0;
    end else if (o_h_valid) begin
        if (state == PROCESS) begin
            N_reg     <= new_N;
            Sigma_reg <= new_Sigma;
        end else if (state == PROCESS_CONST1)
            Sigma_reg <= Sigma_reg + 512'h1;
    end
end

// -----------------------------------------------------------------------------
// Padding stage
// -----------------------------------------------------------------------------
padding padding_inst (
    .i_data(s_axis_tdata),
    .i_keep(s_axis_tkeep),
    .o_data(padded_data)
);

// -----------------------------------------------------------------------------
// Block busy logic (g_transform in-flight)
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin : proc_block_busy
    if(~rst_n)
        block_busy <= 1'b0;
    else if (s_axis_m_tvalid)
        block_busy <= 1'b1;
    else if (o_h_valid)
        block_busy <= 1'b0;
end

// -----------------------------------------------------------------------------
// g_transform instance
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
// FSM (control flow)
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (~rst_n)
        state <= IDLE;
    else
        state <= nextstate;
end

always_ff @(posedge clk) begin
    if(~rst_n || (state == OUTPUT)) begin
        input_last_seen  <= 1'b0;
        input_full_block <= 1'b0;
    end else if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
        input_last_seen  <= 1'b1;
        input_full_block <= &s_axis_tkeep;
    end
end

always_comb begin
    unique case (state)
        IDLE: begin
            if (s_axis_tvalid && s_axis_tready)
                nextstate = PROCESS;
            else
                nextstate = IDLE;
        end
        PROCESS: begin
            if (input_last_seen && o_h_valid)
                nextstate = input_full_block ? PROCESS_CONST1 : FINAL_N;
            else
                nextstate = PROCESS;
        end
        PROCESS_CONST1:
            nextstate = o_h_valid ? FINAL_N : PROCESS_CONST1;
        FINAL_N:
            nextstate = o_h_valid ? FINAL_SIG : FINAL_N;
        FINAL_SIG: begin
            if (o_h_valid)
                nextstate = input_last_seen ? OUTPUT : IDLE;
            else
                nextstate = FINAL_SIG;
        end
        OUTPUT:
            nextstate = m_axis_tready ? IDLE : OUTPUT;
        default:
            nextstate = IDLE;
    endcase
end

// -----------------------------------------------------------------------------
// Hash state update (H register)
// -----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (~rst_n || (m_axis_tvalid && m_axis_tready))
        h_reg <= IV;
    else if (state == IDLE)
        h_reg <= IV;
    if (o_h_valid)
        h_reg <= o_h_data;
end

// -----------------------------------------------------------------------------
// AXI-like handshake logic
// -----------------------------------------------------------------------------
assign s_axis_tready   = ~block_busy && (state == IDLE || state == PROCESS);
assign s_axis_m_tvalid = ~block_busy && (s_axis_tvalid || (nextstate > PROCESS));

always_comb begin
    unique case (state)
        PROCESS:        s_axis_m_tdata = padded_data;
        PROCESS_CONST1: s_axis_m_tdata = 512'h1;
        FINAL_N:        s_axis_m_tdata = N;
        FINAL_SIG:      s_axis_m_tdata = Sigma_reg;
        default:        s_axis_m_tdata = padded_data;
    endcase
end

// -----------------------------------------------------------------------------
// Output assignment
// -----------------------------------------------------------------------------
assign m_axis_tdata  = mode ? h_reg : {256'h0, h_reg[511:256]};
assign m_axis_tvalid = (state == OUTPUT);

// -----------------------------------------------------------------------------
// End of Hash
// -----------------------------------------------------------------------------
endmodule : hash
