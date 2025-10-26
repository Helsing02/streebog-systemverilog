module padding (
    input  logic [511:0] i_data,    // Input data block for padding
    input  logic [63:0]  i_keep,    // Input keep information
    output logic [511:0] o_data     // Output padded data block
);

assign o_data[0 +: 8] = (i_keep[0] == 1) ? i_data[0 +: 8] : 8'b1;

genvar i;
generate
    for (i = 1; i < 64; i++) begin : padding_loop
        assign o_data[i*8 +: 8] = (i_keep[i] == 1) ? i_data[i*8 +: 8] : ((i_keep[i-1] == 1) ? 8'b1 : 8'b0);
    end
endgenerate

endmodule : padding
