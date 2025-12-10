// -----------------------------------------------------------------------------
// Matrix Multiplication
// Performs 64×64 binary matrix multiplication in GF(2) arithmetic.
//
// Operation:
//   o_data = i_data × L_MATRIX
// where L_MATRIX is a fixed 64×64 transformation matrix used in the L stage.
//
// Implementation details:
//  - Each bit of i_data selects one row of L_MATRIX.
//  - Rows are XORed together when the corresponding bit in i_data is '1'.
//  - Fully combinational; latency = 0 cycles.
//
// Interface:
//  - i_data : 64-bit input vector
//  - o_data : 64-bit output vector
// -----------------------------------------------------------------------------

module matrix_multiplication (
    input  logic [63:0] i_data,     // Input data for matrix multiplication
    output logic [63:0] o_data      // Output result of multiplication
);

// -----------------------------------------------------------------------------
// Transformation matrix definition
// Each 64-bit constant represents one row of the 64×64 binary matrix.
// The matrix provides linear diffusion in the L transformation.
// -----------------------------------------------------------------------------
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

// -----------------------------------------------------------------------------
// Combinational matrix multiplication logic
// XOR selected rows of L_MATRIX based on which
// bits in i_data are set to '1'.
// -----------------------------------------------------------------------------
assign o_data = (i_data[0]  ? L_MATRIX[0]  : 64'h0) ^
                (i_data[1]  ? L_MATRIX[1]  : 64'h0) ^
                (i_data[2]  ? L_MATRIX[2]  : 64'h0) ^
                (i_data[3]  ? L_MATRIX[3]  : 64'h0) ^
                (i_data[4]  ? L_MATRIX[4]  : 64'h0) ^
                (i_data[5]  ? L_MATRIX[5]  : 64'h0) ^
                (i_data[6]  ? L_MATRIX[6]  : 64'h0) ^
                (i_data[7]  ? L_MATRIX[7]  : 64'h0) ^
                (i_data[8]  ? L_MATRIX[8]  : 64'h0) ^
                (i_data[9]  ? L_MATRIX[9]  : 64'h0) ^
                (i_data[10] ? L_MATRIX[10] : 64'h0) ^
                (i_data[11] ? L_MATRIX[11] : 64'h0) ^
                (i_data[12] ? L_MATRIX[12] : 64'h0) ^
                (i_data[13] ? L_MATRIX[13] : 64'h0) ^
                (i_data[14] ? L_MATRIX[14] : 64'h0) ^
                (i_data[15] ? L_MATRIX[15] : 64'h0) ^
                (i_data[16] ? L_MATRIX[16] : 64'h0) ^
                (i_data[17] ? L_MATRIX[17] : 64'h0) ^
                (i_data[18] ? L_MATRIX[18] : 64'h0) ^
                (i_data[19] ? L_MATRIX[19] : 64'h0) ^
                (i_data[20] ? L_MATRIX[20] : 64'h0) ^
                (i_data[21] ? L_MATRIX[21] : 64'h0) ^
                (i_data[22] ? L_MATRIX[22] : 64'h0) ^
                (i_data[23] ? L_MATRIX[23] : 64'h0) ^
                (i_data[24] ? L_MATRIX[24] : 64'h0) ^
                (i_data[25] ? L_MATRIX[25] : 64'h0) ^
                (i_data[26] ? L_MATRIX[26] : 64'h0) ^
                (i_data[27] ? L_MATRIX[27] : 64'h0) ^
                (i_data[28] ? L_MATRIX[28] : 64'h0) ^
                (i_data[29] ? L_MATRIX[29] : 64'h0) ^
                (i_data[30] ? L_MATRIX[30] : 64'h0) ^
                (i_data[31] ? L_MATRIX[31] : 64'h0) ^
                (i_data[32] ? L_MATRIX[32] : 64'h0) ^
                (i_data[33] ? L_MATRIX[33] : 64'h0) ^
                (i_data[34] ? L_MATRIX[34] : 64'h0) ^
                (i_data[35] ? L_MATRIX[35] : 64'h0) ^
                (i_data[36] ? L_MATRIX[36] : 64'h0) ^
                (i_data[37] ? L_MATRIX[37] : 64'h0) ^
                (i_data[38] ? L_MATRIX[38] : 64'h0) ^
                (i_data[39] ? L_MATRIX[39] : 64'h0) ^
                (i_data[40] ? L_MATRIX[40] : 64'h0) ^
                (i_data[41] ? L_MATRIX[41] : 64'h0) ^
                (i_data[42] ? L_MATRIX[42] : 64'h0) ^
                (i_data[43] ? L_MATRIX[43] : 64'h0) ^
                (i_data[44] ? L_MATRIX[44] : 64'h0) ^
                (i_data[45] ? L_MATRIX[45] : 64'h0) ^
                (i_data[46] ? L_MATRIX[46] : 64'h0) ^
                (i_data[47] ? L_MATRIX[47] : 64'h0) ^
                (i_data[48] ? L_MATRIX[48] : 64'h0) ^
                (i_data[49] ? L_MATRIX[49] : 64'h0) ^
                (i_data[50] ? L_MATRIX[50] : 64'h0) ^
                (i_data[51] ? L_MATRIX[51] : 64'h0) ^
                (i_data[52] ? L_MATRIX[52] : 64'h0) ^
                (i_data[53] ? L_MATRIX[53] : 64'h0) ^
                (i_data[54] ? L_MATRIX[54] : 64'h0) ^
                (i_data[55] ? L_MATRIX[55] : 64'h0) ^
                (i_data[56] ? L_MATRIX[56] : 64'h0) ^
                (i_data[57] ? L_MATRIX[57] : 64'h0) ^
                (i_data[58] ? L_MATRIX[58] : 64'h0) ^
                (i_data[59] ? L_MATRIX[59] : 64'h0) ^
                (i_data[60] ? L_MATRIX[60] : 64'h0) ^
                (i_data[61] ? L_MATRIX[61] : 64'h0) ^
                (i_data[62] ? L_MATRIX[62] : 64'h0) ^
                (i_data[63] ? L_MATRIX[63] : 64'h0);

// -----------------------------------------------------------------------------
// End of Matrix Multiplication
// -----------------------------------------------------------------------------
endmodule : matrix_multiplication
