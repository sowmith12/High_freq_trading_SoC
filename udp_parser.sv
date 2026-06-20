// udp_parser.sv
// Strips 14-byte Ethernet header + 20-byte IPv4 header + 8-byte UDP header
// then forwards the payload (MoldUDP64+) over AXI stream.
// BRH Trademaxxer Part 1 (fixed: add ETH+IP stripping)

module udp_parser (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       s_tvalid,
    input  logic [7:0] s_tdata,
    input  logic       s_tlast,
    output logic       s_tready,
    output logic       m_tvalid,
    output logic [7:0] m_tdata,
    output logic       m_tlast,
    input  logic       m_tready
);

// ETH header = 14 bytes, IPv4 header = 20 bytes, UDP header = 8 bytes
// Total bytes to strip = 42. We count 0..41 then forward.
// bytes_counter tracks position within the current frame.

typedef enum logic [2:0] {
    IDLE,
    STRIP,      // consuming ETH(14) + IP(20) + UDP(8) = 42 bytes
    FORWARDING,
    WAIT_LAST   // absorb rest of frame if m_tready backpressure stalls us past tlast
} state_t;

state_t     state;
logic [5:0] strip_cnt;   // counts 0..41

always_ff @(posedge clk) begin
    if (~rst_n) begin
        state     <= IDLE;
        strip_cnt <= 0;
    end else begin
        case (state)
            IDLE: begin
                if (s_tvalid) begin
                    // First byte (byte 0 of ETH header) - start counting
                    strip_cnt <= 1;
                    state     <= STRIP;
                end
            end

            STRIP: begin
                if (s_tvalid) begin
                    if (strip_cnt == 41) begin
                        // Just consumed byte index 41 (last UDP header byte)
                        strip_cnt <= 0;
                        state     <= FORWARDING;
                    end else begin
                        strip_cnt <= strip_cnt + 1;
                    end
                end
                // If frame ends prematurely, go back to IDLE
                if (s_tvalid && s_tlast) begin
                    state     <= IDLE;
                    strip_cnt <= 0;
                end
            end

            FORWARDING: begin
                // Forward bytes; when downstream accepts and we see tlast -> done
                if (s_tvalid && m_tready && s_tlast) begin
                    state <= IDLE;
                end
            end

            default: state <= IDLE;
        endcase
    end
end

always_comb begin
    m_tvalid = 1'b0;
    m_tdata  = 8'b0;
    m_tlast  = 1'b0;
    s_tready = 1'b1;  // default: consume

    case (state)
        IDLE: begin
            s_tready = 1'b1;
        end

        STRIP: begin
            s_tready = 1'b1;
        end

        FORWARDING: begin
            m_tvalid = s_tvalid;
            m_tdata  = s_tdata;
            m_tlast  = s_tlast;
            s_tready = m_tready;
        end

        default: s_tready = 1'b1;
    endcase
end

endmodule
