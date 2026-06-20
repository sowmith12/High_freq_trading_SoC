// axi_mgmt_slave.v
// AXI4-Lite management slave
// CPU/management plane reads SoC status and writes config
//
// Address map:
// 0x0000 RO  best_bid[23:0]
// 0x0004 RO  best_ask[23:0]
// 0x0008 RO  spread[23:0]
// 0x000C RO  net_position[31:0]
// 0x0010 RO  total_bid_qty[31:0]
// 0x0014 RO  total_ask_qty[31:0]
// 0x0018 RO  last_latency_cycles
// 0x001C RO  min_latency_cycles
// 0x0020 RO  max_latency_cycles
// 0x0024 RO  total_orders
// 0x0028 RO  risk_reject_count
// 0x002C RO  reject_reason (last)
// 0x0030 RW  kill_switch (bit 0)
// 0x0034 RW  stock_symbol_hi (upper 32 bits)
// 0x0038 RW  stock_symbol_lo (lower 32 bits)

module axi_mgmt_slave (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite slave
    input  wire [7:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [7:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // Status inputs from SoC
    input  wire [23:0] best_bid,
    input  wire [23:0] best_ask,
    input  wire [23:0] spread,
    input  wire signed [31:0] net_position,
    input  wire [31:0] total_bid_qty,
    input  wire [31:0] total_ask_qty,
    input  wire [31:0] last_latency_cycles,
    input  wire [31:0] min_latency_cycles,
    input  wire [31:0] max_latency_cycles,
    input  wire [31:0] total_orders,
    input  wire [31:0] risk_reject_count,
    input  wire [7:0]  reject_reason,

    // Config outputs to SoC
    output reg         kill_switch,
    output reg  [63:0] stock_symbol
);

// Write channel
reg [7:0] awaddr_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        s_axi_awready <= 1;
        s_axi_wready  <= 1;
        s_axi_bvalid  <= 0;
        s_axi_bresp   <= 0;
        kill_switch   <= 0;
        stock_symbol  <= 64'h5A594E4520202020; // "ZYNE    "
        awaddr_reg    <= 0;
    end else begin
        if (s_axi_awvalid && s_axi_awready) begin
            awaddr_reg    <= s_axi_awaddr;
            s_axi_awready <= 0;
        end

        if (s_axi_wvalid && s_axi_wready) begin
            s_axi_wready <= 0;
            case (awaddr_reg)
                8'h30: kill_switch       <= s_axi_wdata[0];
                8'h34: stock_symbol[63:32] <= s_axi_wdata;
                8'h38: stock_symbol[31:0]  <= s_axi_wdata;
                default: ;
            endcase
            s_axi_bvalid  <= 1;
            s_axi_bresp   <= 2'b00;
            s_axi_awready <= 1;
            s_axi_wready  <= 1;
        end

        if (s_axi_bvalid && s_axi_bready)
            s_axi_bvalid <= 0;
    end
end

// Read channel
always @(posedge clk) begin
    if (!rst_n) begin
        s_axi_arready <= 1;
        s_axi_rvalid  <= 0;
        s_axi_rdata   <= 0;
        s_axi_rresp   <= 0;
    end else begin
        if (s_axi_arvalid && s_axi_arready) begin
            s_axi_arready <= 0;
            s_axi_rvalid  <= 1;
            s_axi_rresp   <= 2'b00;
            case (s_axi_araddr)
                8'h00: s_axi_rdata <= {8'b0, best_bid};
                8'h04: s_axi_rdata <= {8'b0, best_ask};
                8'h08: s_axi_rdata <= {8'b0, spread};
                8'h0C: s_axi_rdata <= net_position;
                8'h10: s_axi_rdata <= total_bid_qty;
                8'h14: s_axi_rdata <= total_ask_qty;
                8'h18: s_axi_rdata <= last_latency_cycles;
                8'h1C: s_axi_rdata <= min_latency_cycles;
                8'h20: s_axi_rdata <= max_latency_cycles;
                8'h24: s_axi_rdata <= total_orders;
                8'h28: s_axi_rdata <= risk_reject_count;
                8'h2C: s_axi_rdata <= {24'b0, reject_reason};
                8'h30: s_axi_rdata <= {31'b0, kill_switch};
                8'h34: s_axi_rdata <= stock_symbol[63:32];
                8'h38: s_axi_rdata <= stock_symbol[31:0];
                default: s_axi_rdata <= 32'hDEADBEEF;
            endcase
        end

        if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid  <= 0;
            s_axi_arready <= 1;
        end
    end
end

endmodule
