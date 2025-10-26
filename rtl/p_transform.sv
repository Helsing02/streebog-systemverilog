
module p_transform (
    input  logic [511:0] i_data,    // Input data block for permutation
    output logic [511:0] o_data     // Output permuted block
);

genvar i;
generate
    for (i = 0; i < 64; i++) begin : perm_loop
        // Index to choose byte from i_data
        localparam int idx = (i * 8 + i / 8) % 64;
        assign o_data[i*8 +: 8] = i_data[idx*8 +: 8];
    end
endgenerate

endmodule : p_transform
