// ouch_encoder.v
// OUCH 4.x Order Encoder — Nasdaq's order entry protocol
// Encodes BUY/SELL decisions into OUCH Enter Order messages
// Output: AXI stream of bytes ready to send via UDP/TCP

// OUCH Enter Order message format (49 bytes):
// [0]     message type = 'O' (0x4F)
// [1..14] order token (14 bytes ASCII, our unique ID)
// [15]    buy/sell = 'B' or 'S'
// [16..19] shares (4 bytes big endian)
// [20..27] stock (8 bytes space padded)
// [28..31] price (4 bytes, price * 10000)
// [32..35] time in force (4 bytes) 0=day
// [36..43] firm (8 bytes)
// [44]    display = 'Y'
// [45..48] capacity + misc

module ouch_encoder (
    input  wire        clk,
    input  wire        rst_n,

    // Order input from risk engine
    input  wire        order_valid,
    input  wire [1:0]  order_decision,  // 1=BUY 2=SELL
    input  wire [23:0] order_price,
    input  wire [15:0] order_qty,
    input  wire [7:0]  order_type,

    // Stock symbol (configured at startup, 8 bytes)
    input  wire [63:0] stock_symbol,    // e.g. "ZYNE    "

    // Order token counter (incremented per order)
    output reg  [31:0] order_token_count,

    // AXI stream output (bytes of OUCH message)
    output reg         m_tvalid,
    output reg  [7:0]  m_tdata,
    output reg         m_tlast,
    input  wire        m_tready
);

// OUCH message is 49 bytes
localparam MSG_LEN = 49;

reg [7:0]  msg_buf [0:MSG_LEN-1];
reg [5:0]  send_idx;
reg        sending;
reg [31:0] token;

// Build message into buffer
task build_ouch_message;
    integer i;
    reg [7:0] token_str [0:13];
    reg [7:0] firm_str  [0:7];
    begin
        // Token as ASCII decimal (simplified)
        token_str[0]  = 8'h30 + (token[31:28]);
        token_str[1]  = 8'h30 + (token[27:24]);
        token_str[2]  = 8'h30 + (token[23:20]);
        token_str[3]  = 8'h30 + (token[19:16]);
        token_str[4]  = 8'h30 + (token[15:12]);
        token_str[5]  = 8'h30 + (token[11:8]);
        token_str[6]  = 8'h30 + (token[7:4]);
        token_str[7]  = 8'h30 + (token[3:0]);
        token_str[8]  = 8'h30;
        token_str[9]  = 8'h30;
        token_str[10] = 8'h30;
        token_str[11] = 8'h30;
        token_str[12] = 8'h30;
        token_str[13] = 8'h30;

        // Message type
        msg_buf[0] = 8'h4F;  // 'O'

        // Order token (14 bytes)
        for (i = 0; i < 14; i = i + 1)
            msg_buf[1+i] = token_str[i];

        // Buy/Sell indicator
        msg_buf[15] = (order_decision == 2'd1) ? 8'h42 : 8'h53; // 'B' or 'S'

        // Shares (4 bytes big endian)
        msg_buf[16] = {8{1'b0}};
        msg_buf[17] = {8{1'b0}};
        msg_buf[18] = order_qty[15:8];
        msg_buf[19] = order_qty[7:0];

        // Stock symbol (8 bytes)
        msg_buf[20] = stock_symbol[63:56];
        msg_buf[21] = stock_symbol[55:48];
        msg_buf[22] = stock_symbol[47:40];
        msg_buf[23] = stock_symbol[39:32];
        msg_buf[24] = stock_symbol[31:24];
        msg_buf[25] = stock_symbol[23:16];
        msg_buf[26] = stock_symbol[15:8];
        msg_buf[27] = stock_symbol[7:0];

        // Price (4 bytes, already in ticks)
        msg_buf[28] = {8{1'b0}};
        msg_buf[29] = order_price[23:16];
        msg_buf[30] = order_price[15:8];
        msg_buf[31] = order_price[7:0];

        // Time in force = 0 (day order)
        msg_buf[32] = 8'h00;
        msg_buf[33] = 8'h00;
        msg_buf[34] = 8'h00;
        msg_buf[35] = 8'h00;

        // Firm ID "DEMO    "
        msg_buf[36] = 8'h44; // D
        msg_buf[37] = 8'h45; // E
        msg_buf[38] = 8'h4D; // M
        msg_buf[39] = 8'h4F; // O
        msg_buf[40] = 8'h20;
        msg_buf[41] = 8'h20;
        msg_buf[42] = 8'h20;
        msg_buf[43] = 8'h20;

        // Display = 'Y'
        msg_buf[44] = 8'h59;

        // Capacity = 'P' (principal), intermarket sweep = 'N', min qty = 0
        msg_buf[45] = 8'h50; // 'P'
        msg_buf[46] = 8'h4E; // 'N'
        msg_buf[47] = 8'h00;
        msg_buf[48] = 8'h00;
    end
endtask

always @(posedge clk) begin
    if (!rst_n) begin
        m_tvalid          <= 0;
        m_tdata           <= 0;
        m_tlast           <= 0;
        send_idx          <= 0;
        sending           <= 0;
        token             <= 0;
        order_token_count <= 0;
    end else begin
        if (!sending && order_valid) begin
            // New order — build message and start sending
            token   <= order_token_count;
            build_ouch_message;
            sending  <= 1;
            send_idx <= 0;
            order_token_count <= order_token_count + 1;
        end

        if (sending) begin
            m_tvalid <= 1;
            m_tdata  <= msg_buf[send_idx];
            m_tlast  <= (send_idx == MSG_LEN - 1);

            if (m_tready) begin
                if (send_idx == MSG_LEN - 1) begin
                    sending  <= 0;
                    m_tvalid <= 0;
                    m_tlast  <= 0;
                end else begin
                    send_idx <= send_idx + 1;
                end
            end
        end
    end
end

endmodule
