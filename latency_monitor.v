// latency_monitor.v
// Measures clock cycles from market data arrival to order sent
// Useful for debugging and regulatory audit

module latency_monitor (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        market_data_valid,  // first byte of ITCH message
    input  wire        order_sent,         // tlast of OUCH message

    output reg  [31:0] last_latency_cycles,
    output reg  [31:0] min_latency_cycles,
    output reg  [31:0] max_latency_cycles,
    output reg  [31:0] total_orders
);

reg [31:0] cycle_counter;
reg        measuring;

always @(posedge clk) begin
    if (!rst_n) begin
        last_latency_cycles <= 0;
        min_latency_cycles  <= 32'hFFFFFFFF;
        max_latency_cycles  <= 0;
        total_orders        <= 0;
        cycle_counter       <= 0;
        measuring           <= 0;
    end else begin
        if (market_data_valid && !measuring) begin
            measuring     <= 1;
            cycle_counter <= 0;
        end

        if (measuring) begin
            cycle_counter <= cycle_counter + 1;

            if (order_sent) begin
                measuring           <= 0;
                last_latency_cycles <= cycle_counter;
                total_orders        <= total_orders + 1;

                if (cycle_counter < min_latency_cycles)
                    min_latency_cycles <= cycle_counter;
                if (cycle_counter > max_latency_cycles)
                    max_latency_cycles <= cycle_counter;
            end
        end
    end
end

endmodule
