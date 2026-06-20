// strategy_engine.v
// HFT Strategy Engine — pure hardware, no CPU
// Implements:
//   1. Order imbalance detector (bid qty >> ask qty = price going up)
//   2. Spread analyser (tight spread = good liquidity)
//   3. Momentum detector (price moving in one direction)
//   4. Simple market making signal
// Output: BUY / SELL / HOLD decision with price and quantity

module strategy_engine (
    input  wire        clk,
    input  wire        rst_n,

    // Market state inputs
    input  wire [23:0] best_bid,
    input  wire [23:0] best_ask,
    input  wire        spread_valid,
    input  wire [23:0] spread,

    // Ladder aggregate inputs (from price ladder)
    input  wire [31:0] total_bid_qty,   // total bid quantity across all levels
    input  wire [31:0] total_ask_qty,   // total ask quantity across all levels

    // Position state
    input  wire signed [31:0] net_position,
    input  wire               position_limit_breach,

    // Kill switch from management
    input  wire        kill_switch,

    // Strategy decision outputs
    output reg         decision_valid,
    output reg  [1:0]  decision,        // 00=HOLD 01=BUY 10=SELL
    output reg  [23:0] order_price,
    output reg  [15:0] order_qty,
    output reg  [7:0]  order_type       // 0=LIMIT 1=MARKET
);

// Decision encoding
localparam HOLD = 2'd0;
localparam BUY  = 2'd1;
localparam SELL = 2'd2;

// Strategy parameters (hardcoded for synthesis, would be AXI-configurable in full design)
localparam IMBALANCE_THRESHOLD  = 32'd3;    // bid_qty > ask_qty * 3 = bullish
localparam MAX_SPREAD           = 24'd200;  // don't trade if spread > 200 ticks
localparam BASE_ORDER_QTY       = 16'd100;  // default order size
localparam MAX_LONG_POSITION    = 32'sd5000;
localparam MAX_SHORT_POSITION   = -32'sd5000;

// Internal signals
reg [31:0] imbalance_ratio_bid;
reg [31:0] imbalance_ratio_ask;
reg        bid_heavy;   // more buyers than sellers
reg        ask_heavy;   // more sellers than buyers
reg        spread_ok;   // spread is tradeable

// Momentum tracking — compare best_bid over time
reg [23:0] prev_best_bid;
reg [23:0] prev_best_ask;
reg [2:0]  bid_up_count;    // how many cycles bid has been rising
reg [2:0]  bid_down_count;
reg        momentum_up;
reg        momentum_down;

// Pipeline stage 1: compute imbalance and spread check
always @(posedge clk) begin
    if (!rst_n) begin
        bid_heavy        <= 0;
        ask_heavy        <= 0;
        spread_ok        <= 0;
        prev_best_bid    <= 0;
        prev_best_ask    <= 0;
        bid_up_count     <= 0;
        bid_down_count   <= 0;
        momentum_up      <= 0;
        momentum_down    <= 0;
    end else begin
        // Spread check
        spread_ok <= spread_valid && (spread < MAX_SPREAD) && (spread > 0);

        // Order imbalance: bid_qty > ask_qty * threshold = bullish
        if (total_ask_qty > 0) begin
            bid_heavy <= (total_bid_qty > total_ask_qty * IMBALANCE_THRESHOLD);
            ask_heavy <= (total_ask_qty > total_bid_qty * IMBALANCE_THRESHOLD);
        end else begin
            bid_heavy <= 0;
            ask_heavy <= 0;
        end

        // Momentum: track if best_bid is rising or falling
        prev_best_bid <= best_bid;
        prev_best_ask <= best_ask;

        if (best_bid > prev_best_bid && prev_best_bid > 0) begin
            bid_up_count   <= (bid_up_count < 7) ? bid_up_count + 1 : 7;
            bid_down_count <= 0;
        end else if (best_bid < prev_best_bid && prev_best_bid > 0) begin
            bid_down_count <= (bid_down_count < 7) ? bid_down_count + 1 : 7;
            bid_up_count   <= 0;
        end

        momentum_up   <= (bid_up_count   >= 3'd3);
        momentum_down <= (bid_down_count >= 3'd3);
    end
end

// Pipeline stage 2: make decision
always @(posedge clk) begin
    if (!rst_n || kill_switch || position_limit_breach) begin
        decision_valid <= 0;
        decision       <= HOLD;
        order_price    <= 0;
        order_qty      <= 0;
        order_type     <= 0;
    end else begin
        decision_valid <= 0;
        decision       <= HOLD;

        if (spread_ok && best_bid > 0 && best_ask > 0) begin

            // STRATEGY 1: Order imbalance + momentum = strong buy signal
            if (bid_heavy && momentum_up &&
                net_position < MAX_LONG_POSITION) begin
                decision_valid <= 1;
                decision       <= BUY;
                order_price    <= best_ask;  // buy at ask (aggressive)
                order_qty      <= BASE_ORDER_QTY;
                order_type     <= 8'd1;      // market order for speed
            end

            // STRATEGY 2: Ask heavy + momentum down = sell signal
            else if (ask_heavy && momentum_down &&
                     net_position > MAX_SHORT_POSITION) begin
                decision_valid <= 1;
                decision       <= SELL;
                order_price    <= best_bid;  // sell at bid
                order_qty      <= BASE_ORDER_QTY;
                order_type     <= 8'd1;
            end

            // STRATEGY 3: Market making — post limit orders at spread
            // If spread > 2 ticks and we have no position, provide liquidity
            else if (spread > 24'd2 && net_position == 0 && spread_valid) begin
                decision_valid <= 1;
                decision       <= BUY;
                order_price    <= best_bid + 1;  // join best bid + 1 tick
                order_qty      <= BASE_ORDER_QTY / 2;
                order_type     <= 8'd0;           // limit order
            end
        end
    end
end

endmodule
