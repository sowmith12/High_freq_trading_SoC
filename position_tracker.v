// position_tracker.v
// Tracks current position (net shares held) and P&L
// Updates from order executions

module position_tracker (
    input  wire        clk,
    input  wire        rst_n,

    // From orders bookkeeper execution events
    input  wire        exec_valid,
    input  wire        exec_side,    // 1=buy 0=sell
    input  wire [23:0] exec_qty,
    input  wire [23:0] exec_price,

    // Position outputs
    output reg  signed [31:0] net_position,   // positive=long negative=short
    output reg  [31:0]        total_bought,
    output reg  [31:0]        total_sold,
    output reg  signed [47:0] unrealized_pnl, // vs current price
    output reg                position_limit_breach  // safety flag
);

localparam MAX_POSITION = 32'sd10000;  // max 10000 shares either direction

always @(posedge clk) begin
    if (!rst_n) begin
        net_position         <= 0;
        total_bought         <= 0;
        total_sold           <= 0;
        unrealized_pnl       <= 0;
        position_limit_breach <= 0;
    end else begin
        if (exec_valid) begin
            if (exec_side) begin
                // Buy execution
                net_position <= net_position + $signed({8'b0, exec_qty});
                total_bought <= total_bought + {8'b0, exec_qty};
            end else begin
                // Sell execution
                net_position <= net_position - $signed({8'b0, exec_qty});
                total_sold   <= total_sold + {8'b0, exec_qty};
            end
        end

        // Position limit breach check
        if (net_position > MAX_POSITION || net_position < -MAX_POSITION)
            position_limit_breach <= 1;
        else
            position_limit_breach <= 0;
    end
end

endmodule
