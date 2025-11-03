`resetall
`timescale 1ns / 1ps

module tb_hash # (
    parameter ROUNDS = 100
);

// Import DPI functions - "load" C functions into SV
import "DPI-C" function void stribog_init(
    inout byte unsigned    ctx[280],
    input int              hash_size
);
import "DPI-C" function void stribog_update(
    inout byte unsigned    ctx[280],
    input byte unsigned    data[64],
    input longint unsigned len
);
import "DPI-C" function void stribog_final(
    input  byte unsigned   ctx[280],
    output byte unsigned   hash[64]
);

logic         clk;    // Clock
logic         rst_n;  // Synchronous reset active low

logic         mode;

logic [511:0] s_axis_tdata;
logic         s_axis_tvalid;
logic         s_axis_tready;
logic [63:0]  s_axis_tkeep;
logic         s_axis_tlast;

logic [511:0] m_axis_tdata;
logic         m_axis_tvalid;
logic         m_axis_tready;
logic [63:0]  m_axis_tkeep;
logic         m_axis_tlast;

// Initialize DUT
hash dut (
    .clk          (clk),
    .rst_n        (rst_n),

    .mode         (mode),

    .s_axis_tdata (s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tkeep (s_axis_tkeep),
    .s_axis_tlast (s_axis_tlast),

    .m_axis_tdata (m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tkeep (m_axis_tkeep),
    .m_axis_tlast (m_axis_tlast)
);

// Expected data signals
logic [511:0] expected_m_axis_tdata;
logic [64:0] expected_m_axis_tkeep;
assign expected_m_axis_tkeep = mode ? 512'hFFFFFFFFFFFFFFFF : 512'hFFFFFFFF;

// Context for DPI functions
byte unsigned ctx[280];

// Tasks and functions
task call_init (
    input logic input_mode
);
    int mode_val;
    begin
        mode_val = input_mode ? 512 : 256;
        stribog_init(ctx, mode_val);
    end
endtask

task call_update (
    input logic [511:0] input_data,
    input logic [7:0] input_len
);
    byte unsigned data[64];
    longint unsigned len;
    begin
        len = input_len;
        for (int i = 0; i < 64; i++) begin
            data[i] = input_data[i*8 +: 8];
        end
        stribog_update(ctx, data, len);
    end
endtask

function logic [511:0] call_final ();
    byte unsigned hash [64];
    logic [511:0] result;
    begin
        stribog_final(ctx, hash);
        for (int i = 0; i < 64; i++) begin
            result[i*8 +: 8] = hash[i];
        end
        return result;
    end
endfunction


int total_bytes;
int offset;
int bytes_left;
int block_size;

initial begin
    // Initialize signals
    clk = 0;
    rst_n = 1;
    mode = 0;
    s_axis_tdata = 0;
    s_axis_tvalid = 0;
    s_axis_tlast = 0;
    m_axis_tready = 1;

    #3;
    rst_n = 0;
    #10;
    rst_n = 1;
    // Test random vectors
    for (int i = 0; i < ROUNDS; i++) begin : random_vectors_loop
        mode = $urandom % 2;
        call_init(mode);

        total_bytes  = $urandom % 1024;
        offset = 0;
        while (offset < total_bytes) begin
            bytes_left = total_bytes - offset;
            block_size = (bytes_left > 64) ? 64 : bytes_left;

            while (~s_axis_tready) #10;

            s_axis_tdata = {
                $urandom, $urandom, $urandom, $urandom,
                $urandom, $urandom, $urandom, $urandom,
                $urandom, $urandom, $urandom, $urandom,
                $urandom, $urandom, $urandom, $urandom
            };

            if (block_size == 64) begin
                s_axis_tkeep = 64'hFFFFFFFFFFFFFFFF; // все 64 бита единицы
                s_axis_tlast = 0;
            end else begin
                s_axis_tkeep = (64'h1 << block_size) - 1; // block_size единиц справа
                s_axis_tlast = 1;
            end

            call_update(s_axis_tdata, block_size);

            s_axis_tvalid = 1;
            #10;
            s_axis_tvalid = 0;
            s_axis_tlast = 0;

            offset += block_size;
        end

        while (m_axis_tvalid != 1) #1;

        #3;

        expected_m_axis_tdata = call_final();

        assert (m_axis_tkeep == expected_m_axis_tkeep) else begin
            $error("ASSERTION FAILED:\n dut_output_tkeep = %h\n expected_tkeep = %h", m_axis_tkeep, expected_m_axis_tkeep);
            $stop;
        end

        assert (m_axis_tdata == expected_m_axis_tdata) else begin
            $error("ASSERTION FAILED:\n dut_output = %h\n expected = %h", m_axis_tdata, expected_m_axis_tdata);
            $stop;
        end
        #10;
    end
    $stop;

end

always begin
    #5; clk = ~clk;
end

endmodule : tb_hash
