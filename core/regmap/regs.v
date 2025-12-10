// Created with Corsair v1.0.4

module regs #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter STRB_W = DATA_W / 8
)(
    // System
    input clk,
    input rst,
    // MODE.MODE_BIT
    output  csr_mode_mode_bit_out,

    // TOTAL_NUM_TRANS.NUM_TRANS_VAL
    output [31:0] csr_total_num_trans_num_trans_val_out,

    // RECV_NUM_TRANS.NUM_TRANS_RECV
    input [31:0] csr_recv_num_trans_num_trans_recv_in,
    output [31:0] csr_recv_num_trans_num_trans_recv_out,

    // AXI
    input  [ADDR_W-1:0] axil_awaddr,
    input  [2:0]        axil_awprot,
    input               axil_awvalid,
    output              axil_awready,
    input  [DATA_W-1:0] axil_wdata,
    input  [STRB_W-1:0] axil_wstrb,
    input               axil_wvalid,
    output              axil_wready,
    output [1:0]        axil_bresp,
    output              axil_bvalid,
    input               axil_bready,

    input  [ADDR_W-1:0] axil_araddr,
    input  [2:0]        axil_arprot,
    input               axil_arvalid,
    output              axil_arready,
    output [DATA_W-1:0] axil_rdata,
    output [1:0]        axil_rresp,
    output              axil_rvalid,
    input               axil_rready
);
wire              wready;
wire [ADDR_W-1:0] waddr;
wire [DATA_W-1:0] wdata;
wire              wen;
wire [STRB_W-1:0] wstrb;
wire [DATA_W-1:0] rdata;
wire              rvalid;
wire [ADDR_W-1:0] raddr;
wire              ren;
    reg [ADDR_W-1:0] waddr_int;
    reg [ADDR_W-1:0] raddr_int;
    reg [DATA_W-1:0] wdata_int;
    reg [STRB_W-1:0] strb_int;
    reg              awflag;
    reg              wflag;
    reg              arflag;
    reg              rflag;

    reg              axil_bvalid_int;
    reg [DATA_W-1:0] axil_rdata_int;
    reg              axil_rvalid_int;

    assign axil_awready = ~awflag;
    assign axil_wready  = ~wflag;
    assign axil_bvalid  = axil_bvalid_int;
    assign waddr        = waddr_int;
    assign wdata        = wdata_int;
    assign wstrb        = strb_int;
    assign wen          = awflag && wflag;
    assign axil_bresp   = 'd0; // always okay

    always @(posedge clk) begin
        if (rst == 1'b1) begin
            waddr_int       <= 'd0;
            wdata_int       <= 'd0;
            strb_int        <= 'd0;
            awflag          <= 1'b0;
            wflag           <= 1'b0;
            axil_bvalid_int <= 1'b0;
        end else begin
            if (axil_awvalid == 1'b1 && awflag == 1'b0) begin
                awflag    <= 1'b1;
                waddr_int <= axil_awaddr;
            end else if (wen == 1'b1 && wready == 1'b1) begin
                awflag    <= 1'b0;
            end

            if (axil_wvalid == 1'b1 && wflag == 1'b0) begin
                wflag     <= 1'b1;
                wdata_int <= axil_wdata;
                strb_int  <= axil_wstrb;
            end else if (wen == 1'b1 && wready == 1'b1) begin
                wflag     <= 1'b0;
            end

            if (axil_bvalid_int == 1'b1 && axil_bready == 1'b1) begin
                axil_bvalid_int <= 1'b0;
            end else if ((axil_wvalid == 1'b1 && awflag == 1'b1) || (axil_awvalid == 1'b1 && wflag == 1'b1) || (wflag == 1'b1 && awflag == 1'b1)) begin
                axil_bvalid_int <= wready;
            end
        end
    end

    assign axil_arready = ~arflag;
    assign axil_rdata   = axil_rdata_int;
    assign axil_rvalid  = axil_rvalid_int;
    assign raddr        = raddr_int;
    assign ren          = arflag && ~rflag;
    assign axil_rresp   = 'd0; // always okay

    always @(posedge clk) begin
        if (rst == 1'b1) begin
            raddr_int       <= 'd0;
            arflag          <= 1'b0;
            rflag           <= 1'b0;
            axil_rdata_int  <= 'd0;
            axil_rvalid_int <= 1'b0;
        end else begin
            if (axil_arvalid == 1'b1 && arflag == 1'b0) begin
                arflag    <= 1'b1;
                raddr_int <= axil_araddr;
            end else if (axil_rvalid_int == 1'b1 && axil_rready == 1'b1) begin
                arflag    <= 1'b0;
            end

            if (rvalid == 1'b1 && ren == 1'b1 && rflag == 1'b0) begin
                rflag <= 1'b1;
            end else if (axil_rvalid_int == 1'b1 && axil_rready == 1'b1) begin
                rflag <= 1'b0;
            end

            if (rvalid == 1'b1 && axil_rvalid_int == 1'b0) begin
                axil_rdata_int  <= rdata;
                axil_rvalid_int <= 1'b1;
            end else if (axil_rvalid_int == 1'b1 && axil_rready == 1'b1) begin
                axil_rvalid_int <= 1'b0;
            end
        end
    end

//------------------------------------------------------------------------------
// CSR:
// [0x0] - MODE - Определяет размер выходного хеша (256/512 бит)
//------------------------------------------------------------------------------
wire [31:0] csr_mode_rdata;
assign csr_mode_rdata[31:1] = 31'h0;

wire csr_mode_wen;
assign csr_mode_wen = wen && (waddr == 32'h0);

wire csr_mode_ren;
assign csr_mode_ren = ren && (raddr == 32'h0);
reg csr_mode_ren_ff;
always @(posedge clk) begin
    if (rst) begin
        csr_mode_ren_ff <= 1'b0;
    end else begin
        csr_mode_ren_ff <= csr_mode_ren;
    end
end
//---------------------
// Bit field:
// MODE[0] - MODE_BIT - Бит режима (1=512, 0=256)
// access: rw, hardware: o
//---------------------
reg  csr_mode_mode_bit_ff;

assign csr_mode_rdata[0] = csr_mode_mode_bit_ff;

assign csr_mode_mode_bit_out = csr_mode_mode_bit_ff;

always @(posedge clk) begin
    if (rst) begin
        csr_mode_mode_bit_ff <= 1'b1;
    end else  begin
     if (csr_mode_wen) begin
            if (wstrb[0]) begin
                csr_mode_mode_bit_ff <= wdata[0];
            end
        end else begin
            csr_mode_mode_bit_ff <= csr_mode_mode_bit_ff;
        end
    end
end


//------------------------------------------------------------------------------
// CSR:
// [0x4] - TOTAL_NUM_TRANS - Defines num of tlast asserts from xdma
//------------------------------------------------------------------------------
wire [31:0] csr_total_num_trans_rdata;

wire csr_total_num_trans_wen;
assign csr_total_num_trans_wen = wen && (waddr == 32'h4);

//---------------------
// Bit field:
// TOTAL_NUM_TRANS[31:0] - NUM_TRANS_VAL - Value from host
// access: wo, hardware: o
//---------------------
reg [31:0] csr_total_num_trans_num_trans_val_ff;

assign csr_total_num_trans_rdata[31:0] = 32'h0;

assign csr_total_num_trans_num_trans_val_out = csr_total_num_trans_num_trans_val_ff;

always @(posedge clk) begin
    if (rst) begin
        csr_total_num_trans_num_trans_val_ff <= 32'h0;
    end else  begin
     if (csr_total_num_trans_wen) begin
            if (wstrb[0]) begin
                csr_total_num_trans_num_trans_val_ff[7:0] <= wdata[7:0];
            end
            if (wstrb[1]) begin
                csr_total_num_trans_num_trans_val_ff[15:8] <= wdata[15:8];
            end
            if (wstrb[2]) begin
                csr_total_num_trans_num_trans_val_ff[23:16] <= wdata[23:16];
            end
            if (wstrb[3]) begin
                csr_total_num_trans_num_trans_val_ff[31:24] <= wdata[31:24];
            end
        end else begin
            csr_total_num_trans_num_trans_val_ff <= csr_total_num_trans_num_trans_val_ff;
        end
    end
end


//------------------------------------------------------------------------------
// CSR:
// [0x8] - RECV_NUM_TRANS - Tlast assert counter
//------------------------------------------------------------------------------
wire [31:0] csr_recv_num_trans_rdata;


wire csr_recv_num_trans_ren;
assign csr_recv_num_trans_ren = ren && (raddr == 32'h8);
reg csr_recv_num_trans_ren_ff;
always @(posedge clk) begin
    if (rst) begin
        csr_recv_num_trans_ren_ff <= 1'b0;
    end else begin
        csr_recv_num_trans_ren_ff <= csr_recv_num_trans_ren;
    end
end
//---------------------
// Bit field:
// RECV_NUM_TRANS[31:0] - NUM_TRANS_RECV - Keep num of received transactions
// access: ro, hardware: io
//---------------------
reg [31:0] csr_recv_num_trans_num_trans_recv_ff;

assign csr_recv_num_trans_rdata[31:0] = csr_recv_num_trans_num_trans_recv_ff;

assign csr_recv_num_trans_num_trans_recv_out = csr_recv_num_trans_num_trans_recv_ff;

always @(posedge clk) begin
    if (rst) begin
        csr_recv_num_trans_num_trans_recv_ff <= 32'h0;
    end else  begin
              begin            csr_recv_num_trans_num_trans_recv_ff <= csr_recv_num_trans_num_trans_recv_in;
        end
    end
end


//------------------------------------------------------------------------------
// Write ready
//------------------------------------------------------------------------------
assign wready = 1'b1;

//------------------------------------------------------------------------------
// Read address decoder
//------------------------------------------------------------------------------
reg [31:0] rdata_ff;
always @(posedge clk) begin
    if (rst) begin
        rdata_ff <= 32'h0;
    end else if (ren) begin
        case (raddr)
            32'h0: rdata_ff <= csr_mode_rdata;
            32'h4: rdata_ff <= csr_total_num_trans_rdata;
            32'h8: rdata_ff <= csr_recv_num_trans_rdata;
            default: rdata_ff <= 32'h0;
        endcase
    end else begin
        rdata_ff <= 32'h0;
    end
end
assign rdata = rdata_ff;

//------------------------------------------------------------------------------
// Read data valid
//------------------------------------------------------------------------------
reg rvalid_ff;
always @(posedge clk) begin
    if (rst) begin
        rvalid_ff <= 1'b0;
    end else if (ren && rvalid) begin
        rvalid_ff <= 1'b0;
    end else if (ren) begin
        rvalid_ff <= 1'b1;
    end
end

assign rvalid = rvalid_ff;

endmodule