// Implementing SBox using reverse engineering
module s_transform_re (
    input  logic [7:0] i_data,
    output logic [7:0] o_data
);
    // Tables of 4-bit functions as constants
    logic [3:0] nu0 [0:15] =       '{4'h2,4'h5,4'h3,4'hb,4'h6,4'h9,4'he,4'ha,4'h0,4'h4,4'hf,4'h1,4'h8,4'hd,4'hc,4'h7};
    logic [3:0] nu1 [0:15] =       '{4'h7,4'h6,4'hc,4'h9,4'h0,4'hf,4'h8,4'h1,4'h4,4'h5,4'hb,4'he,4'hd,4'h2,4'h3,4'ha};
    logic [3:0] sigma [0:15] =     '{4'hc,4'hd,4'h0,4'h4,4'h8,4'hb,4'ha,4'he,4'h3,4'h9,4'h5,4'h2,4'hf,4'h1,4'h6,4'h7};
    logic [3:0] phi [0:15] =       '{4'hb,4'h2,4'hb,4'h8,4'hc,4'h4,4'h1,4'hc,4'h6,4'h3,4'h5,4'h8,4'he,4'h3,4'h6,4'hb};
    logic [3:0] inv_field [0:15] = '{4'h0,4'h1,4'hc,4'h8,4'h6,4'hf,4'h4,4'he,4'h3,4'hd,4'hb,4'ha,4'h2,4'h9,4'h7,4'h5};

    // Precalculated lookup table for raising to the 14th power in GF(16)
    logic [3:0] pow14_lut [0:15] = '{
        4'h0,
        4'h1,
        4'hC,
        4'h8,
        4'h6,
        4'hF,
        4'h4,
        4'hE,
        4'h3,
        4'hD,
        4'hB,
        4'hA,
        4'h2,
        4'h9,
        4'h7,
        4'h5
    };

    // Matrix
    logic [7:0] alpha_matrix[0:7] = {
        8'b00011000,
        8'b01110100,
        8'b00010001,
        8'b00000010,
        8'b10011010,
        8'b00010100,
        8'b00111010,
        8'b01110000
    };

    logic [7:0] omega_matrix[0:7] = {
        8'b00010010,
        8'b00000100,
        8'b00100000,
        8'b00010000,
        8'b10011000,
        8'b01000100,
        8'b10010010,
        8'b00000001
    };

    function logic [7:0] matmul8x8(input logic [7:0] x, input logic [7:0] matrix [7:0]);
        logic [7:0] res;
        integer i;
        begin
            res = 8'b0;
            for (i = 0; i < 8; i++) begin
                if(x[i]) begin
                    res ^= matrix[i];
                end
            end
            return res;
        end
    endfunction


    // Умножение в поле F_{2^4} с примитивным полиномом X^4 + X^3 + 1
    function logic [3:0] gf16_mul(input logic [3:0] a, input logic [3:0] b);
        // Реализация умножения в поле, например, сдвиг и редукция
        logic [7:0] p;
        int i;
        p = 0;
        for (i = 0; i < 4; i++) begin
            if (b[i]) p ^= (a << i);
        end
        // Редукция по X^4+X^3+1
        for (i = 7; i >= 4; i--) begin
            if (p[i]) p ^= (9 << (i - 4)); // 9 = 1001b соответствует X^4 + X^3 + 1
        end
        gf16_mul = p[3:0];
    endfunction


    logic [3:0] l, r, l_new, r_new;

    always_comb begin
        logic [7:0] tmp;
        // 1
        tmp = matmul8x8(i_data, alpha_matrix);
        l = tmp[7:4];
        r = tmp[3:0];
        // 2
        if (r == 4'b0000) begin
            l_new = nu0[l];
        end else begin
            // l_new = nu1(l * r^14)
            l_new = nu1[gf16_mul(l, pow14_lut[r])];
        end

        // 3
        // r_new = sigma(r * phi(l_new))
        r_new = sigma[gf16_mul(r, phi[l_new])];

        // 4
        o_data = matmul8x8({l_new, r_new}, omega_matrix);
    end

endmodule : s_transform_re
