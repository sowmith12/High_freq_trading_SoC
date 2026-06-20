// ladder_aggregator.v
// Accumulates total bid and ask quantities across all price levels
// Used by strategy engine for order imbalance detection

module ladder_aggregator (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        ladder_valid,
    input  wire        ladder_add_rem,
    input  wire [23:0] ladder_qty,
    input  wire        ladder_side,

    output reg  [31:0] total_bid_qty,
    output reg  [31:0] total_ask_qty
);

always @(posedge clk) begin
    if (!rst_n) begin
        total_bid_qty <= 0;
        total_ask_qty <= 0;
    end else begin
        if (ladder_valid) begin
            if (ladder_side) begin
                if (ladder_add_rem)
                    total_bid_qty <= total_bid_qty + {8'b0, ladder_qty};
                else begin
                    if (total_bid_qty >= {8'b0, ladder_qty})
                        total_bid_qty <= total_bid_qty - {8'b0, ladder_qty};
                    else
                        total_bid_qty <= 0;
                end
            end else begin
                if (ladder_add_rem)
                    total_ask_qty <= total_ask_qty + {8'b0, ladder_qty};
                else begin
                    if (total_ask_qty >= {8'b0, ladder_qty})
                        total_ask_qty <= total_ask_qty - {8'b0, ladder_qty};
                    else
                        total_ask_qty <= 0;
                end
            end
        end
    end
end

endmodule
