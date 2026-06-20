// hft_soc_top.v
// Full HFT SoC Top Level
// Integrates: RX pipeline + market state + strategy + risk + TX encoder
// Target: OpenLane / SKY130
// BRH Trademaxxer — Full SoC

module hft_soc_top (
    input  wire        clk,
    input  wire        rst_n,

    // ── RX: Market data in (AXI stream from MAC) ──────────────
    input  wire        rx_tvalid,
    input  wire [7:0]  rx_tdata,
    input  wire        rx_tlast,
    output wire        rx_tready,

    // ── TX: Order out (AXI stream to MAC) ─────────────────────
    output wire        tx_tvalid,
    output wire [7:0]  tx_tdata,
    output wire        tx_tlast,
    input  wire        tx_tready,

    // ── AXI4-Lite Management interface (CPU/debug) ─────────────
    input  wire [7:0]  mgmt_awaddr,
    input  wire        mgmt_awvalid,
    output wire        mgmt_awready,
    input  wire [31:0] mgmt_wdata,
    input  wire        mgmt_wvalid,
    output wire        mgmt_wready,
    output wire [1:0]  mgmt_bresp,
    output wire        mgmt_bvalid,
    input  wire        mgmt_bready,
    input  wire [7:0]  mgmt_araddr,
    input  wire        mgmt_arvalid,
    output wire        mgmt_arready,
    output wire [31:0] mgmt_rdata,
    output wire [1:0]  mgmt_rresp,
    output wire        mgmt_rvalid,
    input  wire        mgmt_rready,

    // ── Debug/status outputs ───────────────────────────────────
    output wire        commit_valid,
    output wire [1:0]  commit_opcode,
    output wire        decision_valid,
    output wire [1:0]  decision,
    output wire        risk_reject,
    output wire [7:0]  reject_reason,
    output wire [23:0] best_bid,
    output wire [23:0] best_ask,
    output wire        spread_valid,
    output wire [23:0] spread,
    output wire signed [31:0] net_position,
    output wire [31:0] last_latency_cycles,
    output wire [31:0] min_latency_cycles,
    output wire [31:0] max_latency_cycles,
    output wire [31:0] total_orders
);

// ── Internal wires ─────────────────────────────────────────────

// UDP → MoldUDP64
wire udp_m_tvalid, udp_m_tlast, udp_m_tready;
wire [7:0] udp_m_tdata;

// MoldUDP64 → ITCH
wire mold_m_tvalid, mold_m_tlast, mold_m_tready;
wire [7:0] mold_m_tdata;
wire [63:0] sequence_num;
wire [15:0] msg_count;

// ITCH → Orders bookkeeper
wire [1:0]  itch_opcode;
wire [63:0] itch_order_ref, itch_new_ref;
wire [31:0] itch_price, itch_qty;
wire        itch_side;
wire [15:0] zyne_locate;

// Orders bookkeeper → Price ladder + Strategy
wire        ladder_valid;
wire        ladder_add_rem;
wire [23:0] ladder_price, ladder_qty;
wire        ladder_side;

// Ladder aggregator
wire [31:0] total_bid_qty, total_ask_qty;

// Exec passthrough for position tracker
wire        exec_valid_w;
wire        exec_side_w;
wire [23:0] exec_qty_w, exec_price_w;

// Strategy → Risk
wire        strat_decision_valid;
wire [1:0]  strat_decision;
wire [23:0] strat_order_price;
wire [15:0] strat_order_qty;
wire [7:0]  strat_order_type;

// Risk → OUCH encoder
wire        risk_order_valid;
wire [1:0]  risk_order_decision;
wire [23:0] risk_order_price;
wire [15:0] risk_order_qty;
wire [7:0]  risk_order_type;

// Management config
wire        kill_switch;
wire [63:0] stock_symbol;

// Risk reject counter
reg [31:0] risk_reject_count_r;

// Latency monitor signals
wire order_sent_w;

// AXI ladder read (unused in this top — ladder accessible via price_ladder module)
wire [15:0] ladder_axi_araddr  = 16'b0;
wire        ladder_axi_arvalid = 1'b0;
wire        ladder_axi_arready;
wire [31:0] ladder_axi_rdata;
wire        ladder_axi_rvalid;
wire        ladder_axi_rready  = 1'b1;

// ── RX Pipeline ───────────────────────────────────────────────

udp_parser u_udp (
    .clk      (clk),     .rst_n    (rst_n),
    .s_tvalid (rx_tvalid), .s_tdata (rx_tdata),
    .s_tlast  (rx_tlast),  .s_tready(rx_tready),
    .m_tvalid (udp_m_tvalid), .m_tdata (udp_m_tdata),
    .m_tlast  (udp_m_tlast),  .m_tready(udp_m_tready)
);

moldudp64_parser u_mold (
    .clk      (clk),     .rst_n    (rst_n),
    .s_tvalid (udp_m_tvalid), .s_tdata (udp_m_tdata),
    .s_tlast  (udp_m_tlast),  .s_tready(udp_m_tready),
    .m_tvalid (mold_m_tvalid), .m_tdata (mold_m_tdata),
    .m_tlast  (mold_m_tlast),  .m_tready(mold_m_tready),
    .sequence_num(sequence_num), .msg_count(msg_count)
);

itch_parser u_itch (
    .clk      (clk),     .rst_n    (rst_n),
    .s_tvalid (mold_m_tvalid), .s_tdata (mold_m_tdata),
    .s_tlast  (mold_m_tlast),  .s_tready(mold_m_tready),
    .opcode      (itch_opcode),
    .order_ref   (itch_order_ref),
    .new_ref     (itch_new_ref),
    .price       (itch_price),
    .qty         (itch_qty),
    .side        (itch_side),
    .commit_valid(commit_valid),
    .zyne_locate (zyne_locate)
);

assign commit_opcode = itch_opcode;

// ── Market State ──────────────────────────────────────────────

orders_bookkeeper u_orders (
    .clk          (clk),     .rst_n       (rst_n),
    .commit_valid (commit_valid),
    .opcode       (itch_opcode),
    .order_ref    (itch_order_ref),
    .new_ref      (itch_new_ref),
    .price        (itch_price),
    .qty          (itch_qty),
    .side         (itch_side),
    .ladder_valid   (ladder_valid),
    .ladder_add_rem (ladder_add_rem),
    .ladder_price   (ladder_price),
    .ladder_qty     (ladder_qty),
    .ladder_side    (ladder_side)
);

price_ladder u_ladder (
    .clk          (clk),     .rst_n       (rst_n),
    .ladder_valid   (ladder_valid),
    .ladder_add_rem (ladder_add_rem),
    .ladder_price   (ladder_price),
    .ladder_qty     (ladder_qty),
    .ladder_side    (ladder_side),
    .s_axi_araddr  (ladder_axi_araddr),
    .s_axi_arvalid (ladder_axi_arvalid),
    .s_axi_arready (ladder_axi_arready),
    .s_axi_rdata   (ladder_axi_rdata),
    .s_axi_rvalid  (ladder_axi_rvalid),
    .s_axi_rready  (ladder_axi_rready)
);

ladder_aggregator u_agg (
    .clk          (clk),     .rst_n       (rst_n),
    .ladder_valid   (ladder_valid),
    .ladder_add_rem (ladder_add_rem),
    .ladder_qty     (ladder_qty),
    .ladder_side    (ladder_side),
    .total_bid_qty  (total_bid_qty),
    .total_ask_qty  (total_ask_qty)
);

best_bid_ask u_bba (
    .clk          (clk),     .rst_n       (rst_n),
    .ladder_valid   (ladder_valid),
    .ladder_add_rem (ladder_add_rem),
    .ladder_price   (ladder_price),
    .ladder_qty     (ladder_qty),
    .ladder_side    (ladder_side),
    .best_bid       (best_bid),
    .best_ask       (best_ask),
    .spread_valid   (spread_valid),
    .spread         (spread)
);

// Exec events for position tracker
// EXEC opcode = 2'd1, DELETE = 2'd2
assign exec_valid_w = commit_valid && (itch_opcode == 2'd1);
assign exec_side_w  = itch_side;
assign exec_qty_w   = itch_qty[23:0];
assign exec_price_w = itch_price[23:0];

position_tracker u_pos (
    .clk          (clk),     .rst_n       (rst_n),
    .exec_valid   (exec_valid_w),
    .exec_side    (exec_side_w),
    .exec_qty     (exec_qty_w),
    .exec_price   (exec_price_w),
    .net_position (net_position),
    .total_bought (),
    .total_sold   (),
    .unrealized_pnl(),
    .position_limit_breach()
);

// ── Strategy Engine ───────────────────────────────────────────

strategy_engine u_strat (
    .clk          (clk),     .rst_n       (rst_n),
    .best_bid     (best_bid),
    .best_ask     (best_ask),
    .spread_valid (spread_valid),
    .spread       (spread),
    .total_bid_qty(total_bid_qty),
    .total_ask_qty(total_ask_qty),
    .net_position (net_position),
    .position_limit_breach(1'b0),
    .kill_switch  (kill_switch),
    .decision_valid(strat_decision_valid),
    .decision     (strat_decision),
    .order_price  (strat_order_price),
    .order_qty    (strat_order_qty),
    .order_type   (strat_order_type)
);

assign decision_valid = strat_decision_valid;
assign decision       = strat_decision;

// ── Risk Engine ───────────────────────────────────────────────

risk_engine u_risk (
    .clk          (clk),     .rst_n       (rst_n),
    .order_in_valid   (strat_decision_valid),
    .order_in_decision(strat_decision),
    .order_in_price   (strat_order_price),
    .order_in_qty     (strat_order_qty),
    .order_in_type    (strat_order_type),
    .best_bid         (best_bid),
    .best_ask         (best_ask),
    .net_position     (net_position),
    .order_out_valid  (risk_order_valid),
    .order_out_decision(risk_order_decision),
    .order_out_price  (risk_order_price),
    .order_out_qty    (risk_order_qty),
    .order_out_type   (risk_order_type),
    .risk_reject      (risk_reject),
    .reject_reason    (reject_reason)
);

// Risk reject counter
always @(posedge clk) begin
    if (!rst_n)
        risk_reject_count_r <= 0;
    else if (risk_reject)
        risk_reject_count_r <= risk_reject_count_r + 1;
end

// ── OUCH Encoder (TX path) ────────────────────────────────────

ouch_encoder u_ouch (
    .clk          (clk),     .rst_n       (rst_n),
    .order_valid  (risk_order_valid),
    .order_decision(risk_order_decision),
    .order_price  (risk_order_price),
    .order_qty    (risk_order_qty),
    .order_type   (risk_order_type),
    .stock_symbol (stock_symbol),
    .order_token_count(),
    .m_tvalid     (tx_tvalid),
    .m_tdata      (tx_tdata),
    .m_tlast      (tx_tlast),
    .m_tready     (tx_tready)
);

assign order_sent_w = tx_tlast && tx_tvalid && tx_tready;

// ── Latency Monitor ───────────────────────────────────────────

latency_monitor u_lat (
    .clk                (clk),
    .rst_n              (rst_n),
    .market_data_valid  (rx_tvalid),
    .order_sent         (order_sent_w),
    .last_latency_cycles(last_latency_cycles),
    .min_latency_cycles (min_latency_cycles),
    .max_latency_cycles (max_latency_cycles),
    .total_orders       (total_orders)
);

// ── Management Slave ──────────────────────────────────────────

axi_mgmt_slave u_mgmt (
    .clk          (clk),     .rst_n       (rst_n),
    .s_axi_awaddr (mgmt_awaddr),  .s_axi_awvalid(mgmt_awvalid),
    .s_axi_awready(mgmt_awready),
    .s_axi_wdata  (mgmt_wdata),   .s_axi_wvalid (mgmt_wvalid),
    .s_axi_wready (mgmt_wready),
    .s_axi_bresp  (mgmt_bresp),   .s_axi_bvalid (mgmt_bvalid),
    .s_axi_bready (mgmt_bready),
    .s_axi_araddr (mgmt_araddr),  .s_axi_arvalid(mgmt_arvalid),
    .s_axi_arready(mgmt_arready),
    .s_axi_rdata  (mgmt_rdata),   .s_axi_rresp  (mgmt_rresp),
    .s_axi_rvalid (mgmt_rvalid),  .s_axi_rready (mgmt_rready),
    .best_bid           (best_bid),
    .best_ask           (best_ask),
    .spread             (spread),
    .net_position       (net_position),
    .total_bid_qty      (total_bid_qty),
    .total_ask_qty      (total_ask_qty),
    .last_latency_cycles(last_latency_cycles),
    .min_latency_cycles (min_latency_cycles),
    .max_latency_cycles (max_latency_cycles),
    .total_orders       (total_orders),
    .risk_reject_count  (risk_reject_count_r),
    .reject_reason      (reject_reason),
    .kill_switch        (kill_switch),
    .stock_symbol       (stock_symbol)
);

endmodule
