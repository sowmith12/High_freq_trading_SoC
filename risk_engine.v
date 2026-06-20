// risk_engine.v
// Pre-trade Risk Engine — mandatory by law
// Checks every order before it goes out
// Runs in 1 clock cycle (fully combinational checks)

module risk_engine (
    input  wire        clk,
    input  wire        rst_n,

    // Order from strategy engine
    input  wire        order_in_valid,
    input  wire [1:0]  order_in_decision,   // BUY/SELL
    input  wire [23:0] order_in_price,
    input  wire [15:0] order_in_qty,
    input  wire [7:0]  order_in_type,

    // Market state for sanity checks
    input  wire [23:0] best_bid,
    input  wire [23:0] best_ask,
    input  wire signed [31:0] net_position,

    // Risk parameters (would be AXI-settable in full design)
    // Hardcoded here for synthesis

    // Order output (passed or blocked)
    output reg         order_out_valid,
    output reg [1:0]   order_out_decision,
    output reg [23:0]  order_out_price,
    output reg [15:0]  order_out_qty,
    output reg [7:0]   order_out_type,

    // Risk violation flags
    output reg         risk_reject,
    output reg [7:0]   reject_reason   // bitmask of violated checks
);

// Risk limits
localparam MAX_ORDER_QTY      = 16'd1000;    // fat finger: max 1000 shares
localparam MAX_POSITION_LONG  = 32'sd8000;
localparam MAX_POSITION_SHORT = -32'sd8000;
localparam PRICE_BAND_TICKS   = 24'd500;     // order price must be within 500 ticks of market

// Reject reason bits
localparam R_FAT_FINGER   = 8'h01;  // order too large
localparam R_POSITION     = 8'h02;  // would breach position limit
localparam R_PRICE_BAND   = 8'h04;  // price too far from market
localparam R_ZERO_PRICE   = 8'h08;  // price is zero
localparam R_ZERO_QTY     = 8'h10;  // qty is zero
localparam R_NO_MARKET    = 8'h20;  // no valid market (bid/ask = 0)

// Combinational risk checks
reg [7:0] violations;
reg       market_ok;
reg [23:0] mid_price;
reg [23:0] price_diff;

always @(*) begin
    violations = 8'h00;
    market_ok  = (best_bid > 0 && best_ask > 0);
    mid_price  = (best_bid + best_ask) >> 1;

    // Check 1: Fat finger
    if (order_in_qty > MAX_ORDER_QTY)
        violations = violations | R_FAT_FINGER;

    // Check 2: Zero qty
    if (order_in_qty == 0)
        violations = violations | R_ZERO_QTY;

    // Check 3: Zero price (for limit orders)
    if (order_in_type == 8'd0 && order_in_price == 0)
        violations = violations | R_ZERO_PRICE;

    // Check 4: No market
    if (!market_ok)
        violations = violations | R_NO_MARKET;

    // Check 5: Price band (limit orders only)
    if (order_in_type == 8'd0 && market_ok) begin
        if (order_in_price > mid_price)
            price_diff = order_in_price - mid_price;
        else
            price_diff = mid_price - order_in_price;
        if (price_diff > PRICE_BAND_TICKS)
            violations = violations | R_PRICE_BAND;
    end else begin
        price_diff = 0;
    end

    // Check 6: Position limits
    if (order_in_decision == 2'd1) begin // BUY
        if (net_position + $signed({16'b0, order_in_qty}) > MAX_POSITION_LONG)
            violations = violations | R_POSITION;
    end else if (order_in_decision == 2'd2) begin // SELL
        if (net_position - $signed({16'b0, order_in_qty}) < MAX_POSITION_SHORT)
            violations = violations | R_POSITION;
    end
end

// Register outputs
always @(posedge clk) begin
    if (!rst_n) begin
        order_out_valid    <= 0;
        order_out_decision <= 0;
        order_out_price    <= 0;
        order_out_qty      <= 0;
        order_out_type     <= 0;
        risk_reject        <= 0;
        reject_reason      <= 0;
    end else begin
        if (order_in_valid) begin
            if (violations == 8'h00) begin
                // PASS — forward order
                order_out_valid    <= 1;
                order_out_decision <= order_in_decision;
                order_out_price    <= order_in_price;
                order_out_qty      <= order_in_qty;
                order_out_type     <= order_in_type;
                risk_reject        <= 0;
                reject_reason      <= 0;
            end else begin
                // REJECT
                order_out_valid    <= 0;
                order_out_decision <= 0;
                order_out_price    <= 0;
                order_out_qty      <= 0;
                order_out_type     <= 0;
                risk_reject        <= 1;
                reject_reason      <= violations;
            end
        end else begin
            order_out_valid <= 0;
            risk_reject     <= 0;
        end
    end
end

endmodule
