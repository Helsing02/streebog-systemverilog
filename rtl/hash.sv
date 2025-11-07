// -----------------------------------------------------------------------------
// HASH top-level controller (refactored)
// Orchestrates padding, block processing (G transform), accumulation of N and Sigma,
// and final output formatting (256/512-bit modes).
//
// Key responsibilities:
//  - Receive streamed input blocks (s_axis_*), apply padding and feed blocks to G.
//  - Maintain running counters: N (total processed bits) and Sigma (sum of message blocks).
//  - Drive g_transform submodule and react to its o_h_valid to update h_reg.
//  - Produce final hash on m_axis_* when processing completes.
//
// Notes:
//  - RESET is synchronous active-low (rst_n).
//  - mode==1 => 512-bit output; mode==0 => 256-bit output (lower 256 bits returned).
//  - Top-level keeps a single-block input buffer (m_reg). If you need higher throughput,
//    consider adding a small FIFO for input blocks and decoupling block acceptance.
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

typedef enum logic [2:0] {MAIN_IDLE, MAIN_PROC, MAIN_PROC_CONST1, MAIN_FINAL_N, MAIN_FINAL_SIG, MAIN_OUTPUT} state_t;
state_t state, nextstate;

// ---------------------------- helper functions -----------------------------
// Count set bits (0..64)
function automatic logic [6:0] popcount(input logic [63:0] data);
    logic [6:0] result;
    integer i;
    begin
        result = 0;
        for (i = 0; i < 64; i++) result += data[i];
        return result;
    end
endfunction

// ---------------------------- internal signals -----------------------------
logic [511:0] padded_data;   // padded block produced by padding module
logic [511:0] i_N_data;      // forwarded to g_transform as N
logic [511:0] o_h_data;      // from g_transform
logic         o_h_valid;

// single-block buffer (canonical message block used in Sigma/N updates)
logic [511:0] m_reg;

// accumulators
logic [511:0] Sigma_reg;
logic [508:0] N_reg;
logic [511:0] h_reg;

// constants: IV selection
logic [511:0] IV;
assign IV = (mode == 1) ? 512'h0 : {64{8'h01}};

// ----------------------------- small constants -----------------------------
localparam logic [63:0] KEEP_512 = {64{1'b1}};
localparam logic [63:0] KEEP_256 = {32'h0, {32{1'b1}}};
assign m_axis_tkeep = (mode == 1) ? KEEP_512 : KEEP_256;
assign m_axis_tlast = 1'b1; // single-beat hash output


// When we accept s_axis_tdata (s_axis_tvalid & s_axis_tready), latch padded_data into m_reg
always_ff @(posedge clk) begin
    if (~rst_n) begin
        m_reg <= '0;
    end else if (s_axis_tvalid && s_axis_tready) begin
        m_reg <= padded_data;
    end
end



// ----------------------------- accumulators --------------------------------
// Update Sigma and N when g_transform signals completion (o_h_valid)
// This is safer than updating based on FSM states.
logic [511:0] new_Sigma;
logic [508:0] new_N;
logic [6:0]   module_m;

// When block accepted, mod_m_reg = module_m (if tlast) else 64
logic [6:0] mod_m_reg;
always_ff @(posedge clk) begin
    if (~rst_n) mod_m_reg <= 7'd0;
    else if (s_axis_tvalid && s_axis_tready) begin
        mod_m_reg <= s_axis_tlast ? module_m : 7'd64;
    end
end

always_ff @(posedge clk) begin
    if (~rst_n || (state == MAIN_OUTPUT)) begin
        N_reg <= '0;
        Sigma_reg <= '0;
    end else if (o_h_valid) begin
        if (state == MAIN_PROC) begin
            // update when block processing completed
            N_reg <= new_N;
            Sigma_reg <= new_Sigma;
        end else if (state == MAIN_PROC_CONST1)
            Sigma_reg <= Sigma_reg + 1;
    end
end

assign module_m = popcount(s_axis_tkeep);
assign new_N = N_reg + {502'd0, mod_m_reg};
assign new_Sigma = Sigma_reg + m_reg;

logic [511:0] N;
assign N = N_reg << 3; // Bytes to bits

padding padding_inst (
    .i_data (s_axis_tdata),
    .i_keep (s_axis_tkeep),
    .o_data (padded_data)
);

logic [511:0] s_axis_m_tdata;
logic         s_axis_m_tvalid;
logic         s_axis_m_tready;

logic block_busy;

always_ff @(posedge clk) begin : proc_block_busy
    if(~rst_n) begin
        block_busy <= 1'b0;
    end else if (s_axis_m_tvalid) begin
        block_busy <= 1'b1;
    end else if (o_h_valid) begin
        block_busy <= 1'b0;
    end
end


// instantiate g_transform (unchanged interface)
g_transform #(
    .USE_S_RE    (USE_S_RE),
    .USE_PRECALC (USE_PRECALC)
) g_inst (
    .clk             (clk),
    .rst_n           (rst_n),
    .i_h_data        (h_reg),
    .i_N_data        (i_N_data),
    .s_axis_m_tdata  (s_axis_m_tdata),
    .s_axis_m_tvalid (s_axis_m_tvalid),
    .s_axis_m_tready (s_axis_m_tready),
    .o_h_data        (o_h_data),
    .o_h_valid       (o_h_valid)
);


assign i_N_data = (state == MAIN_PROC || state == MAIN_PROC_CONST1) ? N : 512'h0;

// ------------------------------- main FSM ---------------------------------
// The high-level main FSM sequences:
//  IDLE -> accept input blocks (via AXIS) -> for each accepted block:
//      - start block FSM which will drive g_transform with GM_MSG
//      - after completion update accumulators (done in o_h_valid handler)
//  After the whole message (s_axis_tlast) the FSM runs finalization phases:
//      - process constant 1
//      - process N
//      - process Sigma
//  Then produce output and wait for m_axis_tready.


// High level control signals:
logic input_last_seen;
logic input_full_block;

always_ff @(posedge clk) begin
    if (~rst_n) begin
        state <= MAIN_IDLE;
        input_last_seen <= 1'b0;
    end else begin
        state <= nextstate;
    end
end

always_ff @(posedge clk) begin
    if(~rst_n || state == MAIN_OUTPUT) begin
        input_last_seen  <= 1'b0;
        input_full_block <= 1'b0;
    end else if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
        input_last_seen  <= 1'b1;
        input_full_block <= &s_axis_tkeep;
    end
end

always_comb begin
    unique case (state)
        MAIN_IDLE: begin
            // wait for first block (we use s_axis_tready to accept a new frame)
            if (s_axis_tvalid && s_axis_tready) begin
                // accept block -> start block FSM
                nextstate = MAIN_PROC;
            end
            else
                nextstate = MAIN_IDLE;
        end

        MAIN_PROC: begin
            if (input_last_seen && o_h_valid) begin
                if (input_full_block)
                    nextstate = MAIN_PROC_CONST1;
                else
                    nextstate = MAIN_FINAL_N;
            end
            else
                nextstate = MAIN_PROC;
        end

        MAIN_PROC_CONST1: begin
            if (o_h_valid)
                nextstate = MAIN_FINAL_N;
            else
                nextstate = MAIN_PROC_CONST1;
        end

        MAIN_FINAL_N: begin
            if (o_h_valid)
                nextstate = MAIN_FINAL_SIG;
            else
                nextstate = MAIN_FINAL_N;
        end

        MAIN_FINAL_SIG: begin
            if (o_h_valid)
                if (input_last_seen)
                    nextstate = MAIN_OUTPUT;
                else
                    nextstate = MAIN_IDLE;
            else
                nextstate = MAIN_FINAL_SIG;
        end

        MAIN_OUTPUT: begin
            if (m_axis_tready) nextstate = MAIN_IDLE;
            else nextstate = MAIN_OUTPUT;
        end

        default: nextstate = MAIN_IDLE;
    endcase
end

always_ff @(posedge clk) begin
    if (~rst_n || (m_axis_tvalid && m_axis_tready)) begin
        h_reg <= IV;
    end else if (state == MAIN_IDLE) begin
        h_reg <= IV;
    end if (o_h_valid) begin
        h_reg <= o_h_data;
    end
end


// For the simple per-block flow we need to assert block_start_req for exactly one cycle and let
// block FSM drive s_axis_m_tvalid via BLOCK_START state. We already set block_start_req as
// a one-cycle pulse on acceptance of s_axis_tdata.

// ------------------------------- output stage --------------------------------
// present the hash value (lower 256 if mode==0)
assign m_axis_tdata = (mode == 1) ? h_reg : {256'd0, h_reg[511:256]};
assign m_axis_tvalid = (state == MAIN_OUTPUT);

assign s_axis_tready = !block_busy && (state == MAIN_IDLE || state == MAIN_PROC);
assign s_axis_m_tvalid = !block_busy && (s_axis_tvalid || (nextstate > MAIN_PROC));

always_comb begin
    unique case (state)
        MAIN_PROC:         s_axis_m_tdata = padded_data;
        MAIN_PROC_CONST1: s_axis_m_tdata = 512'h1;
        MAIN_FINAL_N:      s_axis_m_tdata = N;
        MAIN_FINAL_SIG:    s_axis_m_tdata = Sigma_reg;
        default:           s_axis_m_tdata = padded_data;
    endcase
end

endmodule : hash
