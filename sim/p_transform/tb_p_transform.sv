`resetall
`timescale 1ns / 1ps

module tb_p_transform;

logic [511:0] i_data;
logic [511:0] o_data;
logic [511:0] expected_o_data = {
    8'h0,  8'h8,  8'h16, 8'h24, 8'h32, 8'h40, 8'h48, 8'h56,
    8'h1,  8'h9,  8'h17, 8'h25, 8'h33, 8'h41, 8'h49, 8'h57,
    8'h2,  8'h10, 8'h18, 8'h26, 8'h34, 8'h42, 8'h50, 8'h58,
    8'h3,  8'h11, 8'h19, 8'h27, 8'h35, 8'h43, 8'h51, 8'h59,
    8'h4,  8'h12, 8'h20, 8'h28, 8'h36, 8'h44, 8'h52, 8'h60,
    8'h5,  8'h13, 8'h21, 8'h29, 8'h37, 8'h45, 8'h53, 8'h61,
    8'h6,  8'h14, 8'h22, 8'h30, 8'h38, 8'h46, 8'h54, 8'h62,
    8'h7,  8'h15, 8'h23, 8'h31, 8'h39, 8'h47, 8'h55, 8'h63
};

// Initialize DUT
p_transform dut (
    .i_data(i_data),
    .o_data(o_data)
);

initial begin
    i_data = {
        8'h0,  8'h1,  8'h2,  8'h3,  8'h4,  8'h5,  8'h6,  8'h7,
        8'h8,  8'h9,  8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15,
        8'h16, 8'h17, 8'h18, 8'h19, 8'h20, 8'h21, 8'h22, 8'h23,
        8'h24, 8'h25, 8'h26, 8'h27, 8'h28, 8'h29, 8'h30, 8'h31,
        8'h32, 8'h33, 8'h34, 8'h35, 8'h36, 8'h37, 8'h38, 8'h39,
        8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46, 8'h47,
        8'h48, 8'h49, 8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55,
        8'h56, 8'h57, 8'h58, 8'h59, 8'h60, 8'h61, 8'h62, 8'h63
    };
    #10;
    assert (o_data == expected_o_data) else begin
        $display("Input:  %h", i_data);
        $error("ASSERTION FAILED: dut_output = %h, expected %h", o_data, expected_o_data);
        $stop;
    end
    $stop;
end

endmodule
