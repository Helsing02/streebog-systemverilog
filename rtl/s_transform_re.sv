module s_transform_re (
    input  logic [7:0] i_data,
    output logic [7:0] o_data
);

    // Step 1
    logic al_p1, alpha1, alpha2, alpha3, alpha4, alpha5, alpha6, alpha7, alpha8;
    assign al_p1  = i_data[3] ^ i_data[1];
    assign alpha1 = i_data[3];
    assign alpha2 = i_data[6] ^ i_data[0];
    assign alpha3 = alpha2 ^ i_data[1];
    assign alpha4 = alpha2 ^ alpha5 ^ i_data[5] ^ i_data[2];
    assign alpha5 = i_data[7] ^ al_p1;
    assign alpha6 = i_data[6] ^ i_data[2];
    assign alpha7 = i_data[4] ^ al_p1;
    assign alpha8 = i_data[5];

    // Step 2
    logic r_is_zero;
    assign r_is_zero = ~(alpha5 | alpha6 | alpha7 | alpha8);
    logic [3:0] I_of_r;
    I I_inst(
        .x({alpha5, alpha6, alpha7, alpha8}),
        .y(I_of_r)
    );

    logic [3:0] mult_result;
    gf_mult mult_l_ir (
        .x({alpha1, alpha2, alpha3, alpha4}),
        .y(I_of_r),
        .z(mult_result)
    );

    logic [3:0] nu0_of_l;
    nu0 nu0_inst (
        .x({alpha1, alpha2, alpha3, alpha4}),
        .y(nu0_of_l)
    );

    logic [3:0] nu1_of_mult;
    nu1 nu1_inst (
        .x(mult_result),
        .y(nu1_of_mult)
    );

    logic [3:0] l_step2;
    localparam logic [3:0] NU1_OF_ZERO = {1'b0, 1'b1, 1'b1, 1'b1};
    generate
        for (genvar i = 0; i < 4; i++) begin
            assign l_step2[i] = (r_is_zero & (nu0_of_l[i] ^ NU1_OF_ZERO[i])) ^ nu1_of_mult[i];
        end
    endgenerate

    // Step 3
    logic [3:0] phi_of_l;
    phi phi_inst(
        .x(l_step2),
        .y(phi_of_l)
    );

    logic [3:0] mult_result2;
    gf_mult mult_r_phil (
        .x({alpha5, alpha6, alpha7, alpha8}),
        .y(phi_of_l),
        .z(mult_result2)
    );

    logic [3:0] r_step3;
    sigma sigma_inst(
        .x(mult_result2),
        .y(r_step3)
    );

    // Step 4

    logic t1, t2;
    assign t1 = l_step2[0] ^ r_step3[3];
    assign t2 = t1 ^ r_step3[1];

    assign o_data[7] = r_step3[3] ^ r_step3[1];
    assign o_data[6] = r_step3[2];
    assign o_data[5] = l_step2[1];
    assign o_data[4] = l_step2[3] ^ t2;
    assign o_data[3] = r_step3[3];
    assign o_data[2] = l_step2[2] ^ r_step3[2];
    assign o_data[1] = l_step2[3] ^ r_step3[1];
    assign o_data[0] = r_step3[0];

endmodule : s_transform_re


module I (
    input  logic [3:0] x,
    output logic [3:0] y
);
    logic p1, p2;
    assign p1 = x[0] ^ x[2];
    assign p2 = x[2] ^ x[3];

    assign y[0] = (x[0] & ~x[1]) | (((x[0] ^ x[1]) | ~p1) & x[3]);
    assign y[1] = (x[0] & x[2]) ^ (~x[1] & p1 & p2) ^ x[3];
    assign y[2] = ((x[1] ^ x[3]) & ((x[0] | x[2]) ^ x[1])) ^ x[2];
    assign y[3] = (x[1] & ~x[2]) | (((x[1] ^ x[2]) | p2) & x[0]);

endmodule : I

module gf_mult (
    input  logic [3:0] x,
    input  logic [3:0] y,
    output logic [3:0] z
);
    logic p1, p2;
    assign p1 = x[3] ^ x[2];
    assign p2 = p1 ^ x[1];

    assign z[3] = (p2 ^ x[0]) & y[3] ^ p2 & y[2] ^ p1 & y[1] ^ x[3] & y[0];
    assign z[2] = x[3] & y[3] ^ x[0] & y[2] ^ x[1] & y[1] ^ x[2] & y[0];
    assign z[1] = p1 & y[3] ^ x[3] & y[2] ^ x[0] & y[1] ^ x[1] & y[0];
    assign z[0] = p2 & y[3] ^ p1 & y[2] ^ x[3] & y[1] ^ x[0] & y[0];

endmodule : gf_mult

module nu0 (
    input  logic [3:0] x,
    output logic [3:0] y
);

    logic p1;
    assign p1 = x[0] | x[3];

    assign y[0] = (x[1] & ~x[2]) | (((x[1] ^ x[2]) | (~x[1] ^ x[3])) & x[0]);
    assign y[1] = (~((x[0] ^ x[2]) & x[3]) & x[1]) | ~p1;
    assign y[2] = (x[1] & x[3]) ^ (((x[2] ^ x[3]) | ~x[1]) & x[0]) ^ (x[2] & ~x[3]);
    assign y[3] = ((x[1] ^ p1) & x[2]) ^ ((x[0] ^ x[3]) & x[1]);

endmodule : nu0


module nu1 (
    input  logic [3:0] x,
    output logic [3:0] y
);

    logic p1;
    assign p1 = x[0] ^ x[3];

    assign y[0] = ~((x[1] | x[2]) ^ p1);
    assign y[1] = ~(((x[2] | x[3]) ^ (x[0] & x[2])) | x[1]) ^ (x[1] & x[3]);
    assign y[2] = ((x[1] ^ x[2]) & p1) ^ ~x[2];
    assign y[3] = (x[2] & p1) ^ x[1];

endmodule : nu1

module phi (
    input  logic [3:0] x,
    output logic [3:0] y
);

    assign y[0] = (~((x[0] & ~x[1]) | (x[1] ^ x[3])) & x[2]) ^ (~x[1] & x[3]) ^ ~x[0];
    assign y[1] = ~(((x[0] | x[3]) & x[1]) | x[2]) ^ (x[2] & x[3]);
    assign y[2] = (~x[0] & x[3]) | (((x[0] | ~x[1]) ^ (x[0] & x[3])) & x[2]);
    assign y[3] = (x[0] & x[1]) ^ (((x[2] | ~x[3]) ^ (x[1] & x[2])) & ~x[0]);

endmodule : phi

module sigma (
    input  logic [3:0] x,
    output logic [3:0] y
);

    logic p1;
    assign p1 = x[0] ^ x[2];

   assign y[0] = (x[0] & ~x[1]) | (~(x[1] & p1) & x[3]);
   assign y[1] = (((x[2] | x[3]) ^ (x[1] & x[2])) & x[0]) ^ ((x[2] ^ x[3]) & x[1]) ^ x[3];
   assign y[2] = (x[0] & x[1]) ^ (((x[0] & x[3]) ^ ~x[1]) & x[2]) ^ ~x[1] ^ x[3];
   assign y[3] = (x[2] & ~x[3]) | ((~x[3] | p1) & ~x[1]);

endmodule : sigma
