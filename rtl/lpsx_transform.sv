module lpsx_transform (
    input  logic [511:0] i_data_a,  // Input data block A
    input  logic [511:0] i_data_b,  // Input data block B
    output logic [511:0] o_data     // Output transformed data block
);

logic [511:0] xor_res;
logic [511:0] o_substitution;
logic [511:0] o_permutation;

// Perform bitwise XOR on input data blocks
assign xor_res = i_data_a ^ i_data_b;

// Instantiate substitution transform module
s_transform S_instance (
    .i_data(xor_res),
    .o_data(o_substitution)
);

// Instantiate permutation transform module
p_transform P_instance (
    .i_data(o_substitution),
    .o_data(o_permutation)
);

// Instantiate linear transform module
l_transform L_instance (
    .i_data(o_permutation),
    .o_data(o_data)
);

endmodule : lpsx_transform
