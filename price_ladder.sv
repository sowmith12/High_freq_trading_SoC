// price_ladder.sv
// Bid/ask quantity table indexed by XOR-folded price
// 512 slots per side (bid + ask) = 512 x 32 x 2 = 32768 bits total
// XOR folding: 24-bit price -> 9-bit address (512 slots)
// Synthesizable on SKY130 via OpenLane
// AXI4-Lite read slave for CPU readout
// BRH Trademaxxer Part 5 + Part 6

module price_ladder (
    input  wire         clk,
    input  wire         rst_n,

    // From orders bookkeeper
    input  wire         ladder_valid,
    input  wire         ladder_add_rem, // 1=ADD+ 0=REM-
    input  wire [23:0]  ladder_price,
    input  wire [23:0]  ladder_qty,
    input  wire         ladder_side,    // 1=bid 0=ask

    // AXI4-Lite read slave
    // Address: bit[9]=0 -> bid, bit[9]=1 -> ask
    // Lower 9 bits = price slot address
    input  wire [15:0]  s_axi_araddr,
    input  wire         s_axi_arvalid,
    output reg          s_axi_arready,
    output reg  [31:0]  s_axi_rdata,
    output reg          s_axi_rvalid,
    input  wire         s_axi_rready
);

localparam DEPTH = 512;
localparam ABITS = 9;

// Two arrays: bid and ask, each 512 x 32 bits = 16384 bits per side
reg [31:0] bid_bram [0:DEPTH-1];
reg [31:0] ask_bram [0:DEPTH-1];

// XOR folding: 24-bit price -> 9-bit address
// Split into 2 x 9-bit chunks + 6-bit remainder
function [ABITS-1:0] hash_price;
    input [23:0] p;
    begin
        hash_price = p[8:0] ^ p[17:9] ^ {3'b0, p[23:18]};
    end
endfunction

wire [ABITS-1:0] upd_addr = hash_price(ladder_price);

// Update BRAM on ladder event
always @(posedge clk) begin
    if (ladder_valid) begin
        if (ladder_side) begin
            // Bid side
            if (ladder_add_rem)
                bid_bram[upd_addr] <= bid_bram[upd_addr] + {8'b0, ladder_qty};
            else begin
                if (bid_bram[upd_addr] >= {8'b0, ladder_qty})
                    bid_bram[upd_addr] <= bid_bram[upd_addr] - {8'b0, ladder_qty};
                else
                    bid_bram[upd_addr] <= 0;
            end
        end else begin
            // Ask side
            if (ladder_add_rem)
                ask_bram[upd_addr] <= ask_bram[upd_addr] + {8'b0, ladder_qty};
            else begin
                if (ask_bram[upd_addr] >= {8'b0, ladder_qty})
                    ask_bram[upd_addr] <= ask_bram[upd_addr] - {8'b0, ladder_qty};
                else
                    ask_bram[upd_addr] <= 0;
            end
        end
    end
end

// AXI4-Lite read slave FSM
reg [1:0]  axi_state;
reg [ABITS-1:0] axi_addr_reg;
reg        axi_side_reg;

localparam AXI_IDLE  = 2'd0;
localparam AXI_RDATA = 2'd1;

always @(posedge clk) begin
    if (!rst_n) begin
        axi_state     <= AXI_IDLE;
        s_axi_arready <= 1;
        s_axi_rvalid  <= 0;
        s_axi_rdata   <= 0;
        axi_addr_reg  <= 0;
        axi_side_reg  <= 0;
    end else begin
        case (axi_state)
            AXI_IDLE: begin
                s_axi_arready <= 1;
                s_axi_rvalid  <= 0;
                if (s_axi_arvalid) begin
                    // bit 9 selects bid(0) or ask(1)
                    axi_addr_reg  <= s_axi_araddr[ABITS-1:0];
                    axi_side_reg  <= s_axi_araddr[9];
                    axi_state     <= AXI_RDATA;
                    s_axi_arready <= 0;
                end
            end
            AXI_RDATA: begin
                s_axi_rvalid <= 1;
                if (!axi_side_reg)
                    s_axi_rdata <= bid_bram[axi_addr_reg];
                else
                    s_axi_rdata <= ask_bram[axi_addr_reg];
                if (s_axi_rready) begin
                    s_axi_rvalid <= 0;
                    axi_state    <= AXI_IDLE;
                end
            end
            default: axi_state <= AXI_IDLE;
        endcase
    end
end

integer i;
initial begin
    for (i = 0; i < DEPTH; i = i + 1) begin
        bid_bram[i] = 32'b0;
        ask_bram[i] = 32'b0;
    end
end

endmodule
