`resetall
`timescale 1ns / 1ps

module tb_g_transform # (
    parameter ROUNDS = 100
);

// Import DPI functions - "load" C functions into SV
import "DPI-C" function void stribog_g_transform(
    input  byte unsigned N[64],
    input  byte unsigned h[64],
    input  byte unsigned m[64],
    output byte unsigned res[64]
);

logic         clk;    // Clock
logic         rst_n;  // Synchronous reset active low

logic [511:0] i_h_data;
logic [511:0] i_N_data;

logic [511:0] s_axis_m_tdata;
logic         s_axis_m_tvalid;
logic         s_axis_m_tready;

logic [511:0] o_h_data;
logic         o_h_valid;

// Initialize DUT
g_transform dut (
    .clk            (clk),
    .rst_n          (rst_n),

    .i_h_data       (i_h_data),
    .i_N_data       (i_N_data),

    .s_axis_m_tdata (s_axis_m_tdata),
    .s_axis_m_tvalid(s_axis_m_tvalid),
    .s_axis_m_tready(s_axis_m_tready),

    .o_h_data       (o_h_data),
    .o_h_valid      (o_h_valid)
);

// Expected data signals
logic [511:0] expected_o_h_data;

function logic [511:0] call_g_transform (
    input logic [511:0] input_N,
    input logic [511:0] input_h,
    input logic [511:0] input_m
);
    byte unsigned N [64];
    byte unsigned h [64];
    byte unsigned m [64];
    byte unsigned call_result [64];
    logic [511:0] result;
    begin
        for (int i = 0; i < 64; i++) begin
            N[i] = input_N[i*8 +: 8];
            h[i] = input_h[i*8 +: 8];
            m[i] = input_m[i*8 +: 8];
        end
        stribog_g_transform(N, h, m, call_result);
        for (int i = 0; i < 64; i++) begin
            result[i*8 +: 8] = call_result[i];
        end
        return result;
    end
endfunction

initial begin
    // Initialize signals
    clk = 1'b0;
    rst_n = 1'b1;
    i_h_data = 512'b0;
    i_N_data = 512'b0;
    s_axis_m_tdata = 512'b0;
    s_axis_m_tvalid = 1'b0;

    #3;
    rst_n = 0;
    #10;
    rst_n = 1;
    // Test random vectors
    for (int i = 0; i < ROUNDS; i++) begin : random_vectors_loop
        while (~s_axis_m_tready) #10;

        // i_h_data = {
        //     $urandom, $urandom, $urandom, $urandom,
        //     $urandom, $urandom, $urandom, $urandom,
        //     $urandom, $urandom, $urandom, $urandom,
        //     $urandom, $urandom, $urandom, $urandom
        // };
        // i_N_data = {
        //     $urandom, $urandom, $urandom, $urandom,
        //     $urandom, $urandom, $urandom, $urandom,
        //     $urandom, $urandom, $urandom, $urandom,
        //     $urandom, $urandom, $urandom, $urandom
        // };
        // s_axis_m_tdata = {
        //     $urandom, $urandom, $urandom, $urandom,
        //     $urandom, $urandom, $urandom, $urandom,
        //     $urandom, $urandom, $urandom, $urandom,
        //     $urandom, $urandom, $urandom, $urandom
        // };
        i_h_data = '0;
        i_N_data = '0;
        s_axis_m_tdata = 512'h01323130393837363534333231303938373635343332313039383736353433323130393837363534333231303938373635343332313039383736353433323130;

        expected_o_h_data = call_g_transform(i_N_data, i_h_data, s_axis_m_tdata);

        s_axis_m_tvalid = 1;
        #10;
        s_axis_m_tvalid = 0;

        while (o_h_valid != 1) #10;

        assert (o_h_data == expected_o_h_data) else begin
            $error("ASSERTION FAILED:\n dut_output = %h\n expected = %h", o_h_data, expected_o_h_data);
            $stop;
        end
        #10;
    end
    $stop;

end

always begin
    #5; clk = ~clk;
end

endmodule : tb_g_transform
