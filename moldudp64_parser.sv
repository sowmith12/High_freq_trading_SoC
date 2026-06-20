// moldudp64_parser.sv - simplified, reliable version
// Strips 20-byte MoldUDP64 header, forwards ITCH message bytes
// BRH Trademaxxer Part 2

module moldudp64_parser (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         s_tvalid,
    input  wire  [7:0]  s_tdata,
    input  wire         s_tlast,
    output reg          s_tready,
    output reg          m_tvalid,
    output reg   [7:0]  m_tdata,
    output reg          m_tlast,
    input  wire         m_tready,
    output reg  [63:0]  sequence_num,
    output reg  [15:0]  msg_count
);

// We use a single global byte counter to track position in the packet
// Bytes 0-9:   Session ID (drop)
// Bytes 10-17: Sequence number (capture)
// Bytes 18-19: Message count (capture)
// Byte  20-21: First message length (2 bytes)
// Bytes 22+:   First message payload (forward)
// Then repeat: 2-byte length + N-byte payload for each message

localparam S_HEADER  = 2'd0;  // consuming MoldUDP64 header (bytes 0-19)
localparam S_LEN_HI  = 2'd1;  // reading message length high byte
localparam S_LEN_LO  = 2'd2;  // reading message length low byte
localparam S_PAYLOAD = 2'd3;  // forwarding message payload bytes

reg [1:0]  state;
reg [7:0]  hdr_count;    // counts 0..19 for header
reg [15:0] msg_len_reg;  // current message length
reg [15:0] fwd_count;    // how many payload bytes forwarded so far
reg [63:0] seq_tmp;
reg [15:0] cnt_tmp;

always @(posedge clk) begin
    if (!rst_n) begin
        state        <= S_HEADER;
        hdr_count    <= 0;
        msg_len_reg  <= 0;
        fwd_count    <= 0;
        seq_tmp      <= 0;
        cnt_tmp      <= 0;
        sequence_num <= 0;
        msg_count    <= 0;
        s_tready     <= 1;
        m_tvalid     <= 0;
        m_tdata      <= 0;
        m_tlast      <= 0;
    end else begin
        // Default output deasserts
        m_tvalid <= 0;
        m_tlast  <= 0;
        s_tready <= 1;

        if (s_tvalid && s_tready) begin
            case (state)

                S_HEADER: begin
                    // Capture sequence number bytes 10-17
                    if (hdr_count >= 8'd10 && hdr_count <= 8'd17)
                        seq_tmp <= {seq_tmp[55:0], s_tdata};
                    // Capture message count bytes 18-19
                    if (hdr_count == 8'd18)
                        cnt_tmp[15:8] <= s_tdata;
                    if (hdr_count == 8'd19) begin
                        cnt_tmp[7:0] <= s_tdata;
                        sequence_num <= {seq_tmp[55:0], seq_tmp[7:0]}; // latch seq
                        msg_count    <= {cnt_tmp[15:8], s_tdata};
                    end

                    if (hdr_count == 8'd19) begin
                        hdr_count <= 0;
                        state     <= S_LEN_HI;
                    end else begin
                        hdr_count <= hdr_count + 1;
                    end
                end

                S_LEN_HI: begin
                    msg_len_reg[15:8] <= s_tdata;
                    state <= S_LEN_LO;
                end

                S_LEN_LO: begin
                    msg_len_reg[7:0] <= s_tdata;
                    fwd_count <= 0;
                    state <= S_PAYLOAD;
                end

                S_PAYLOAD: begin
                    // Forward this byte downstream
                    m_tvalid <= 1;
                    m_tdata  <= s_tdata;
                    s_tready <= m_tready;

                    if (fwd_count == msg_len_reg - 1) begin
                        // Last byte of this ITCH message
                        m_tlast <= 1;
                        fwd_count <= 0;
                        if (s_tlast)
                            state <= S_HEADER; // end of ethernet frame
                        else
                            state <= S_LEN_HI; // more messages in packet
                    end else begin
                        fwd_count <= fwd_count + 1;
                    end
                end

                default: state <= S_HEADER;
            endcase

            // If ethernet frame ends unexpectedly, reset
            if (s_tlast && state != S_PAYLOAD)
                state <= S_HEADER;
        end
    end
end

endmodule
