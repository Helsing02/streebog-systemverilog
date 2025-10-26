`resetall
`timescale 1ns / 1ps

module tb_lpsx_transform # (
    parameter ROUNDS = 100
);

// Import DPI functions - "load" C functions into SV
import "DPI-C" function void stribog_S_transform(inout byte unsigned block[64]);
import "DPI-C" function void stribog_P_transform(inout byte unsigned block[64]);
import "DPI-C" function void stribog_L_transform(inout byte unsigned block[64]);

logic [511:0] i_data_a;
logic [511:0] i_data_b;
logic [511:0] o_data;
logic [511:0] expected_o_data;

function logic [511:0] do_lpsx (input logic [511:0] input_a, input logic [511:0] input_b);
    byte unsigned expected_o_data [64];
    logic [511:0] result;
    begin
        for (int i = 0; i < 64; i++) begin
            expected_o_data[i] = input_a[8*i +: 8] ^ input_b[8*i +: 8];
        end
        stribog_S_transform(expected_o_data);
        stribog_P_transform(expected_o_data);
        stribog_L_transform(expected_o_data);
        for (int i = 0; i < 64; i++) begin
            result[i*8 +: 8] = expected_o_data[i];
        end
        return result;
    end
endfunction

// Initialize DUT
lpsx_transform dut (
    .i_data_a(i_data_a),
    .i_data_b(i_data_b),
    .o_data  (o_data)
);

initial begin
    int i;
    // Test random vectors
    for (i = 0; i < ROUNDS; i++) begin : random_vectors_loop
        i_data_a = {
            $urandom, $urandom, $urandom, $urandom,
            $urandom, $urandom, $urandom, $urandom,
            $urandom, $urandom, $urandom, $urandom,
            $urandom, $urandom, $urandom, $urandom
        };
        i_data_b = {
            $urandom, $urandom, $urandom, $urandom,
            $urandom, $urandom, $urandom, $urandom,
            $urandom, $urandom, $urandom, $urandom,
            $urandom, $urandom, $urandom, $urandom
        };
        expected_o_data = do_lpsx(i_data_a, i_data_b);
        #10;

        assert (o_data == expected_o_data) else begin
            $display("Input data_a:  %h", i_data_a);
            $display("Input data_b:  %h", i_data_b);
            $error("ASSERTION FAILED:\n dut_output = %h\n expected = %h", o_data, expected_o_data);
            $stop;
        end
    end
    $stop;

end

endmodule : tb_lpsx_transform
