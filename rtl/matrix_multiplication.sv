module matrix_multiplication (
    input  logic [63:0] i_data,     // Input data for matrix multiplication
    output logic [63:0] o_data      // Output result of multiplication
);

// Matrix
const logic [63:0] L_MATRIX [63:0] = {
    64'h8e20faa72ba0b470, 64'h47107ddd9b505a38, 64'had08b0e0c3282d1c, 64'hd8045870ef14980e,
    64'h6c022c38f90a4c07, 64'h3601161cf205268d, 64'h1b8e0b0e798c13c8, 64'h83478b07b2468764,
    64'ha011d380818e8f40, 64'h5086e740ce47c920, 64'h2843fd2067adea10, 64'h14aff010bdd87508,
    64'h0ad97808d06cb404, 64'h05e23c0468365a02, 64'h8c711e02341b2d01, 64'h46b60f011a83988e,
    64'h90dab52a387ae76f, 64'h486dd4151c3dfdb9, 64'h24b86a840e90f0d2, 64'h125c354207487869,
    64'h092e94218d243cba, 64'h8a174a9ec8121e5d, 64'h4585254f64090fa0, 64'haccc9ca9328a8950,
    64'h9d4df05d5f661451, 64'hc0a878a0a1330aa6, 64'h60543c50de970553, 64'h302a1e286fc58ca7,
    64'h18150f14b9ec46dd, 64'h0c84890ad27623e0, 64'h0642ca05693b9f70, 64'h0321658cba93c138,
    64'h86275df09ce8aaa8, 64'h439da0784e745554, 64'hafc0503c273aa42a, 64'hd960281e9d1d5215,
    64'he230140fc0802984, 64'h71180a8960409a42, 64'hb60c05ca30204d21, 64'h5b068c651810a89e,
    64'h456c34887a3805b9, 64'hac361a443d1c8cd2, 64'h561b0d22900e4669, 64'h2b838811480723ba,
    64'h9bcf4486248d9f5d, 64'hc3e9224312c8c1a0, 64'heffa11af0964ee50, 64'hf97d86d98a327728,
    64'he4fa2054a80b329c, 64'h727d102a548b194e, 64'h39b008152acb8227, 64'h9258048415eb419d,
    64'h492c024284fbaec0, 64'haa16012142f35760, 64'h550b8e9e21f7a530, 64'ha48b474f9ef5dc18,
    64'h70a6a56e2440598e, 64'h3853dc371220a247, 64'h1ca76e95091051ad, 64'h0edd37c48a08a6d8,
    64'h07e095624504536c, 64'h8d70c431ac02a736, 64'hc83862965601dd1b, 64'h641c314b2b8ee083
};

integer i;
always_comb begin
    o_data = 64'b0;                 // Initialze rezult
    for (i = 0; i < 64; i++) begin : matr_mult_loop
        if (i_data[i])              // If current bit equals 1
            o_data ^= L_MATRIX[i];  // Include matrix row into result
    end
end

endmodule : matrix_multiplication
