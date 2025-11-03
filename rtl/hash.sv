module hash (
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

// Function for calculating the number of bits equal to 1 in a signal
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

// Connections
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


// ======= Message block processing FSM =======
typedef enum logic [1:0] {
    BLOCK_IDLE, T1, T2, T3
} block_hash_state_t;

block_hash_state_t block_hash_state, block_hash_nextstate;

always_ff @(posedge clk) begin : proc_block_hash_state
    if(~rst_n) begin
        block_hash_state <= BLOCK_IDLE;
    end else begin
        block_hash_state <= block_hash_nextstate;
    end
end

// Next state logic
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


// ========== Main FSM ==========
typedef enum logic [3:0] {
    INITIAL, IDLE, S2, S3,
    S4,      S5,   S6, S7,
    S8,      S9,   S10
} main_state_t;

main_state_t main_state, main_nextstate;

always_ff @(posedge clk) begin : proc_main_state
    if(~rst_n) begin
        main_state <= INITIAL;
    end else begin
        main_state <= main_nextstate;
    end
end

// Extracted big state logic following IDLE
main_state_t hard_decision;
assign hard_decision = (~s_axis_tvalid) ? IDLE :
                       (~s_axis_tlast)  ? S2   :
                       (&s_axis_tkeep)  ? S3   :
                                          S5;
// Next state logic
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
        S9:      main_nextstate = (o_h_valid) ? S10 : S9;
        S10:     main_nextstate = (m_axis_tready) ? INITIAL : S10;
        default: main_nextstate = INITIAL;
    endcase
end

// Outputs
assign M = (main_state == S2) || (main_state == S3) ||
           (main_state == S4) || (main_state == S5);
assign s_axis_tready   = main_state == IDLE;
assign main_m_tvalid = (main_state == S6) || (main_state == S8);
assign m_axis_tvalid   = main_state == S10;


// =========== Sigma calculations ===========

// Signals
logic [511:0] new_Sigma;

// Registers
logic [511:0] m_reg;
logic [511:0] Sigma_reg;

// +++++++++ Input message block reg +++++++++
// Used to calculate the new Sigma value after block has been processed
always_ff @(posedge clk) begin : proc_m_reg
    if(~rst_n) begin
        m_reg <= '0;
    end else if (s_axis_tvalid) begin
        m_reg <= padded_data;
    end
end

// Should be DSP
assign new_Sigma = m_reg + Sigma_reg;

// +++++++++ Sigma reg +++++++++
always_ff @(posedge clk) begin : proc_Sigma_reg
    if(~rst_n || main_state == INITIAL) begin
        Sigma_reg <= '0;
    end else if (block_hash_state == T3) begin
        Sigma_reg <= new_Sigma;
    end
end



// =========== N calculations ===========

// Signals
logic [511:0] new_N;
logic [6:0]   module_m;

// Registers
logic [6:0]   mod_m_reg;
logic [511:0] N_reg;

assign module_m = popcount(s_axis_tkeep);

// +++++++++ Input message block length reg +++++++++
// Used to calculate the new N value after block has been processed
always_ff @(posedge clk) begin : proc_mod_m_reg
    if(~rst_n) begin
        mod_m_reg <= '0;
    end else if (s_axis_tvalid) begin
        if (s_axis_tlast) begin
            mod_m_reg <= module_m;
        end else begin
            mod_m_reg <= 7'd64;
        end
    end
end

// Should be DSP
assign new_N = (mod_m_reg << 3) + N_reg;

// +++++++++ N reg +++++++++
always_ff @(posedge clk) begin : proc_N_reg
    if(~rst_n || main_state == INITIAL) begin
        N_reg <= '0;
    end else if (block_hash_state == T3) begin
        N_reg <= new_N;
    end
end



// ======= h register prosessing logic =======
// Registers
logic [511:0] h_reg;

assign IV = (mode == 1) ? 512'h0 : {64{8'h01}};

// +++++++++ Hash reg +++++++++
// Used to store hash value before and after block is processed
always_ff @(posedge clk) begin : proc_h_reg
    if(~rst_n) begin
        h_reg <= '0;
    end else if (main_state == INITIAL) begin
        h_reg <= IV;
    end else if (o_h_valid) begin
        h_reg <= o_h_data;
    end
end



// ========= Submodules =========
// --------- Padding submodule ---------

padding padding_instance (
    .i_data(s_axis_tdata),
    .i_keep(s_axis_tkeep),
    .o_data(padded_data)
);

// --------- G transform submodule ---------

logic [511:0] s_axis_m_tdata;
logic         s_axis_m_tvalid;
logic         s_axis_m_tready;

g_transform g_instance (
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

assign i_N_data = (main_state >= S6) ? 512'h0 : N_reg;
assign s_axis_m_tdata = (main_state == S4) ? 512'h1    :
                        (main_state == S6) ? N_reg     :
                        (main_state == S8) ? Sigma_reg :
                                             padded_data;
assign s_axis_m_tvalid = main_m_tvalid || block_hash_m_tvalid;


assign m_axis_tdata = mode ? h_reg : h_reg >> 256;
assign m_axis_tlast = 1;
assign m_axis_tkeep = (mode == 1) ? {64{1'b1}} : ({32{1'b0}} << 32) | {32{1'b1}};;

endmodule : hash