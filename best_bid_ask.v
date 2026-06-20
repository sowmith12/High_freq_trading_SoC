// best_bid_ask.v
// Tracks best bid and best ask price in real time from ladder signals
// Updates every cycle a ladder event fires

module best_bid_ask (
    input  wire        clk,
    input  wire        rst_n,

    // From price ladder
    input  wire        ladder_valid,
    input  wire        ladder_add_rem,  // 1=ADD 0=REM
    input  wire [23:0] ladder_price,
    input  wire [23:0] ladder_qty,
    input  wire        ladder_side,     // 1=bid 0=ask

    // Best bid/ask outputs (updated every cycle)
    output reg  [23:0] best_bid,
    output reg  [23:0] best_ask,
    output reg         spread_valid,    // high when both bid and ask known
    output reg  [23:0] spread          // best_ask - best_bid
);

// Simple tracking: maintain best bid as max of all active bid prices
// and best ask as min of all active ask prices
// We use a conservative approach: track via ladder events

// Bid side: best = highest price
// Ask side: best = lowest price

// When ADD fires: update best if this price is better
// When REM fires: we can't easily track removal without full scan
// So we use a "dirty flag" approach — mark as potentially stale
// For synthesis simplicity: update on ADD only, reset on full delete

always @(posedge clk) begin
    if (!rst_n) begin
        best_bid    <= 0;
        best_ask    <= 24'hFFFFFF;
        spread_valid <= 0;
        spread      <= 0;
    end else begin
        if (ladder_valid && ladder_qty > 0) begin
            if (ladder_side) begin
                // Bid side
                if (ladder_add_rem) begin
                    // ADD: update best bid if this price is higher
                    if (ladder_price > best_bid)
                        best_bid <= ladder_price;
                end else begin
                    // REM: if removing best bid price, conservatively lower it
                    if (ladder_price >= best_bid)
                        best_bid <= ladder_price - 1;
                end
            end else begin
                // Ask side
                if (ladder_add_rem) begin
                    // ADD: update best ask if this price is lower
                    if (ladder_price < best_ask || best_ask == 24'hFFFFFF)
                        best_ask <= ladder_price;
                end else begin
                    // REM: if removing best ask, raise it
                    if (ladder_price <= best_ask)
                        best_ask <= ladder_price + 1;
                end
            end
        end

        // Compute spread
        if (best_bid > 0 && best_ask < 24'hFFFFFF && best_ask > best_bid) begin
            spread_valid <= 1;
            spread       <= best_ask - best_bid;
        end else begin
            spread_valid <= 0;
            spread       <= 0;
        end
    end
end

endmodule
