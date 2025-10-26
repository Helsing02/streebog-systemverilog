module tb_padding;


logic [511:0] i_data;
logic [63:0]  i_keep;
logic [511:0] o_data;
logic [511:0] expected_o_data;

logic [511:0] mask;

// Initialize DUT
padding dut (
    .i_data(i_data),
    .i_keep(i_keep),
    .o_data(o_data)
);

initial begin
    int i;
    // Test all possible states i_keep
    i_keep = '0;
    i_data = {
        $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom,
        $urandom, $urandom, $urandom, $urandom
    };

    expected_o_data = 512'b1;
    #10;

    assert (o_data == expected_o_data) else begin
        $display("Input data:  %h", i_data);
        $display("Input keep:  %h", i_keep);
        $error("ASSERTION FAILED:\n dut_output = %h\n expected = %h", o_data, expected_o_data);
        $stop;
    end

    mask = '0;
    for (i = 0; i < 64; i++) begin
        i_data = {
            $urandom, $urandom, $urandom, $urandom,
            $urandom, $urandom, $urandom, $urandom,
            $urandom, $urandom, $urandom, $urandom,
            $urandom, $urandom, $urandom, $urandom
        };

        i_keep |= 64'b1 << i;
        mask |= 512'hFF << (i*8);

        expected_o_data = i_data & mask;
        expected_o_data |= 8'b1 << ((i + 1) * 8);
        #10;

        assert (o_data == expected_o_data) else begin
            $display("Input data:  %h", i_data);
            $display("Input keep:  %h", i_keep);
            $error("ASSERTION FAILED:\n dut_output = %h\n expected = %h", o_data, expected_o_data);
            $stop;
        end
    end
    $stop;
end

endmodule : tb_padding
