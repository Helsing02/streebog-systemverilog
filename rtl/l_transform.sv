module l_transform (
    input  logic [511:0] i_data,    // Input data block for 8 matrix multiplication
    output logic [511:0] o_data     // Output result of 8 multiplications
);

genvar i;
generate
    for (i = 0; i < 8; i++) begin : gen_loop
        matrix_multiplication matr_mult_instance (
            .i_data(i_data[i*64 +: 64]),
            .o_data(o_data[i*64 +: 64])
        );
    end
endgenerate

endmodule : l_transform
