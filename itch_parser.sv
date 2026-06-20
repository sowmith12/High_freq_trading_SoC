// itch_parser.sv
// Parses ITCH 5.0 messages, generates commit signals
// Supported: R, A, F, E, C, X, D, U
// BRH Trademaxxer Part 3

module itch_parser (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         s_tvalid,
    input  wire  [7:0]  s_tdata,
    input  wire         s_tlast,
    output reg          s_tready,

    output reg  [1:0]   opcode,
    output reg  [63:0]  order_ref,
    output reg  [63:0]  new_ref,
    output reg  [31:0]  price,
    output reg  [31:0]  qty,
    output reg          side,
    output reg          commit_valid,
    output reg  [15:0]  zyne_locate
);

localparam OP_ADD     = 2'd0;
localparam OP_EXEC    = 2'd1;
localparam OP_DELETE  = 2'd2;
localparam OP_REPLACE = 2'd3;

// States as parameters
localparam [6:0]
    IDLE         = 7'd0,
    HDR_LOC_HI   = 7'd1,
    HDR_LOC_LO   = 7'd2,
    HDR_TRK_HI   = 7'd3,
    HDR_TRK_LO   = 7'd4,
    HDR_TS0      = 7'd5,
    HDR_TS1      = 7'd6,
    HDR_TS2      = 7'd7,
    HDR_TS3      = 7'd8,
    HDR_TS4      = 7'd9,
    HDR_TS5      = 7'd10,
    ADD_REF0     = 7'd11,
    ADD_REF1     = 7'd12,
    ADD_REF2     = 7'd13,
    ADD_REF3     = 7'd14,
    ADD_REF4     = 7'd15,
    ADD_REF5     = 7'd16,
    ADD_REF6     = 7'd17,
    ADD_REF7     = 7'd18,
    ADD_SIDE     = 7'd19,
    ADD_QTY0     = 7'd20,
    ADD_QTY1     = 7'd21,
    ADD_QTY2     = 7'd22,
    ADD_QTY3     = 7'd23,
    ADD_STK0     = 7'd24,
    ADD_STK1     = 7'd25,
    ADD_STK2     = 7'd26,
    ADD_STK3     = 7'd27,
    ADD_STK4     = 7'd28,
    ADD_STK5     = 7'd29,
    ADD_STK6     = 7'd30,
    ADD_STK7     = 7'd31,
    ADD_PX0      = 7'd32,
    ADD_PX1      = 7'd33,
    ADD_PX2      = 7'd34,
    ADD_PX3      = 7'd35,
    EXEC_REF0    = 7'd36,
    EXEC_REF1    = 7'd37,
    EXEC_REF2    = 7'd38,
    EXEC_REF3    = 7'd39,
    EXEC_REF4    = 7'd40,
    EXEC_REF5    = 7'd41,
    EXEC_REF6    = 7'd42,
    EXEC_REF7    = 7'd43,
    EXEC_QTY0    = 7'd44,
    EXEC_QTY1    = 7'd45,
    EXEC_QTY2    = 7'd46,
    EXEC_QTY3    = 7'd47,
    DEL_REF0     = 7'd48,
    DEL_REF1     = 7'd49,
    DEL_REF2     = 7'd50,
    DEL_REF3     = 7'd51,
    DEL_REF4     = 7'd52,
    DEL_REF5     = 7'd53,
    DEL_REF6     = 7'd54,
    DEL_REF7     = 7'd55,
    REP_OREF0    = 7'd56,
    REP_OREF1    = 7'd57,
    REP_OREF2    = 7'd58,
    REP_OREF3    = 7'd59,
    REP_OREF4    = 7'd60,
    REP_OREF5    = 7'd61,
    REP_OREF6    = 7'd62,
    REP_OREF7    = 7'd63,
    REP_NREF0    = 7'd64,
    REP_NREF1    = 7'd65,
    REP_NREF2    = 7'd66,
    REP_NREF3    = 7'd67,
    REP_NREF4    = 7'd68,
    REP_NREF5    = 7'd69,
    REP_NREF6    = 7'd70,
    REP_NREF7    = 7'd71,
    REP_QTY0     = 7'd72,
    REP_QTY1     = 7'd73,
    REP_QTY2     = 7'd74,
    REP_QTY3     = 7'd75,
    REP_PX0      = 7'd76,
    REP_PX1      = 7'd77,
    REP_PX2      = 7'd78,
    REP_PX3      = 7'd79,
    R_STK0       = 7'd80,
    R_STK1       = 7'd81,
    R_STK2       = 7'd82,
    R_STK3       = 7'd83,
    R_STK4       = 7'd84,
    R_STK5       = 7'd85,
    R_STK6       = 7'd86,
    R_STK7       = 7'd87,
    COMMIT       = 7'd88,
    DRAIN        = 7'd89;

reg [6:0] state, next_state;
reg        tlast_seen;

reg [7:0]  msg_type;
reg [15:0] loc_tmp;
reg [63:0] ref_reg, nref_reg;
reg [31:0] qty_reg, px_reg;
reg        side_reg;
reg [63:0] stk_reg;
reg [15:0] loc_reg;

// Sequential: capture fields
always @(posedge clk) begin
    if (!rst_n) begin
        state        <= IDLE;
        commit_valid <= 0;
        opcode       <= 0;
        order_ref    <= 0;
        new_ref      <= 0;
        price        <= 0;
        qty          <= 0;
        side         <= 0;
        tlast_seen   <= 0;
        msg_type     <= 0;
        loc_tmp      <= 0;
        loc_reg      <= 0;
        ref_reg      <= 0;
        nref_reg     <= 0;
        qty_reg      <= 0;
        px_reg       <= 0;
        side_reg     <= 0;
        stk_reg      <= 0;
        zyne_locate  <= 0;
    end else begin
        state        <= next_state;
        commit_valid <= 0;

        // Track if tlast arrives on the last data byte (just before COMMIT)
        if (s_tvalid && s_tready && s_tlast)
            tlast_seen <= 1;
        else if (state == COMMIT || state == IDLE)
            tlast_seen <= 0;

        if (s_tvalid && s_tready) begin
            case (state)
                IDLE:       msg_type <= s_tdata;
                HDR_LOC_HI: loc_tmp[15:8] <= s_tdata;
                HDR_LOC_LO: loc_reg <= {loc_tmp[15:8], s_tdata};

                ADD_REF0: ref_reg[63:56] <= s_tdata;
                ADD_REF1: ref_reg[55:48] <= s_tdata;
                ADD_REF2: ref_reg[47:40] <= s_tdata;
                ADD_REF3: ref_reg[39:32] <= s_tdata;
                ADD_REF4: ref_reg[31:24] <= s_tdata;
                ADD_REF5: ref_reg[23:16] <= s_tdata;
                ADD_REF6: ref_reg[15:8]  <= s_tdata;
                ADD_REF7: ref_reg[7:0]   <= s_tdata;
                ADD_SIDE: side_reg <= (s_tdata == 8'h42);
                ADD_QTY0: qty_reg[31:24] <= s_tdata;
                ADD_QTY1: qty_reg[23:16] <= s_tdata;
                ADD_QTY2: qty_reg[15:8]  <= s_tdata;
                ADD_QTY3: qty_reg[7:0]   <= s_tdata;
                ADD_PX0:  px_reg[31:24]  <= s_tdata;
                ADD_PX1:  px_reg[23:16]  <= s_tdata;
                ADD_PX2:  px_reg[15:8]   <= s_tdata;
                ADD_PX3:  px_reg[7:0]    <= s_tdata;

                EXEC_REF0: ref_reg[63:56] <= s_tdata;
                EXEC_REF1: ref_reg[55:48] <= s_tdata;
                EXEC_REF2: ref_reg[47:40] <= s_tdata;
                EXEC_REF3: ref_reg[39:32] <= s_tdata;
                EXEC_REF4: ref_reg[31:24] <= s_tdata;
                EXEC_REF5: ref_reg[23:16] <= s_tdata;
                EXEC_REF6: ref_reg[15:8]  <= s_tdata;
                EXEC_REF7: ref_reg[7:0]   <= s_tdata;
                EXEC_QTY0: qty_reg[31:24] <= s_tdata;
                EXEC_QTY1: qty_reg[23:16] <= s_tdata;
                EXEC_QTY2: qty_reg[15:8]  <= s_tdata;
                EXEC_QTY3: qty_reg[7:0]   <= s_tdata;

                DEL_REF0: ref_reg[63:56] <= s_tdata;
                DEL_REF1: ref_reg[55:48] <= s_tdata;
                DEL_REF2: ref_reg[47:40] <= s_tdata;
                DEL_REF3: ref_reg[39:32] <= s_tdata;
                DEL_REF4: ref_reg[31:24] <= s_tdata;
                DEL_REF5: ref_reg[23:16] <= s_tdata;
                DEL_REF6: ref_reg[15:8]  <= s_tdata;
                DEL_REF7: ref_reg[7:0]   <= s_tdata;

                REP_OREF0: ref_reg[63:56]  <= s_tdata;
                REP_OREF1: ref_reg[55:48]  <= s_tdata;
                REP_OREF2: ref_reg[47:40]  <= s_tdata;
                REP_OREF3: ref_reg[39:32]  <= s_tdata;
                REP_OREF4: ref_reg[31:24]  <= s_tdata;
                REP_OREF5: ref_reg[23:16]  <= s_tdata;
                REP_OREF6: ref_reg[15:8]   <= s_tdata;
                REP_OREF7: ref_reg[7:0]    <= s_tdata;
                REP_NREF0: nref_reg[63:56] <= s_tdata;
                REP_NREF1: nref_reg[55:48] <= s_tdata;
                REP_NREF2: nref_reg[47:40] <= s_tdata;
                REP_NREF3: nref_reg[39:32] <= s_tdata;
                REP_NREF4: nref_reg[31:24] <= s_tdata;
                REP_NREF5: nref_reg[23:16] <= s_tdata;
                REP_NREF6: nref_reg[15:8]  <= s_tdata;
                REP_NREF7: nref_reg[7:0]   <= s_tdata;
                REP_QTY0:  qty_reg[31:24]  <= s_tdata;
                REP_QTY1:  qty_reg[23:16]  <= s_tdata;
                REP_QTY2:  qty_reg[15:8]   <= s_tdata;
                REP_QTY3:  qty_reg[7:0]    <= s_tdata;
                REP_PX0:   px_reg[31:24]   <= s_tdata;
                REP_PX1:   px_reg[23:16]   <= s_tdata;
                REP_PX2:   px_reg[15:8]    <= s_tdata;
                REP_PX3:   px_reg[7:0]     <= s_tdata;

                R_STK0: stk_reg[63:56] <= s_tdata;
                R_STK1: stk_reg[55:48] <= s_tdata;
                R_STK2: stk_reg[47:40] <= s_tdata;
                R_STK3: stk_reg[39:32] <= s_tdata;
                R_STK4: stk_reg[31:24] <= s_tdata;
                R_STK5: stk_reg[23:16] <= s_tdata;
                R_STK6: stk_reg[15:8]  <= s_tdata;
                R_STK7: begin
                    stk_reg[7:0] <= s_tdata;
                    // "ZYNE    " = 0x5A594E4520202020
                    if ({stk_reg[63:8], s_tdata} == 64'h5A594E4520202020)
                        zyne_locate <= loc_reg;
                end
                default: ;
            endcase
        end

        // COMMIT: pulse outputs for 1 cycle
        if (state == COMMIT) begin
            commit_valid <= 1;
            order_ref    <= ref_reg;
            new_ref      <= nref_reg;
            price        <= px_reg;
            qty          <= qty_reg;
            side         <= side_reg;
            case (msg_type)
                8'h41, 8'h46: opcode <= OP_ADD;
                8'h44:        opcode <= OP_DELETE;
                8'h55:        opcode <= OP_REPLACE;
                default:      opcode <= OP_EXEC;
            endcase
        end
    end
end

// Combinational next state
always @(*) begin
    next_state = state;
    s_tready   = 1;

    case (state)
        IDLE: begin
            if (s_tvalid) begin
                case (s_tdata)
                    8'h41, 8'h46,
                    8'h45, 8'h43, 8'h58,
                    8'h44,
                    8'h55,
                    8'h52:      next_state = HDR_LOC_HI;
                    default:    next_state = DRAIN;
                endcase
            end
        end

        HDR_LOC_HI: if (s_tvalid) next_state = HDR_LOC_LO;
        HDR_LOC_LO: if (s_tvalid) next_state = HDR_TRK_HI;
        HDR_TRK_HI: if (s_tvalid) next_state = HDR_TRK_LO;
        HDR_TRK_LO: if (s_tvalid) next_state = HDR_TS0;
        HDR_TS0:    if (s_tvalid) next_state = HDR_TS1;
        HDR_TS1:    if (s_tvalid) next_state = HDR_TS2;
        HDR_TS2:    if (s_tvalid) next_state = HDR_TS3;
        HDR_TS3:    if (s_tvalid) next_state = HDR_TS4;
        HDR_TS4:    if (s_tvalid) next_state = HDR_TS5;
        HDR_TS5: begin
            if (s_tvalid) begin
                case (msg_type)
                    8'h41, 8'h46:        next_state = ADD_REF0;
                    8'h45, 8'h43, 8'h58: next_state = EXEC_REF0;
                    8'h44:               next_state = DEL_REF0;
                    8'h55:               next_state = REP_OREF0;
                    8'h52:               next_state = R_STK0;
                    default:             next_state = DRAIN;
                endcase
            end
        end

        // Add order
        ADD_REF0: if (s_tvalid) next_state = ADD_REF1;
        ADD_REF1: if (s_tvalid) next_state = ADD_REF2;
        ADD_REF2: if (s_tvalid) next_state = ADD_REF3;
        ADD_REF3: if (s_tvalid) next_state = ADD_REF4;
        ADD_REF4: if (s_tvalid) next_state = ADD_REF5;
        ADD_REF5: if (s_tvalid) next_state = ADD_REF6;
        ADD_REF6: if (s_tvalid) next_state = ADD_REF7;
        ADD_REF7: if (s_tvalid) next_state = ADD_SIDE;
        ADD_SIDE: if (s_tvalid) next_state = ADD_QTY0;
        ADD_QTY0: if (s_tvalid) next_state = ADD_QTY1;
        ADD_QTY1: if (s_tvalid) next_state = ADD_QTY2;
        ADD_QTY2: if (s_tvalid) next_state = ADD_QTY3;
        ADD_QTY3: if (s_tvalid) next_state = ADD_STK0;
        ADD_STK0: if (s_tvalid) next_state = ADD_STK1;
        ADD_STK1: if (s_tvalid) next_state = ADD_STK2;
        ADD_STK2: if (s_tvalid) next_state = ADD_STK3;
        ADD_STK3: if (s_tvalid) next_state = ADD_STK4;
        ADD_STK4: if (s_tvalid) next_state = ADD_STK5;
        ADD_STK5: if (s_tvalid) next_state = ADD_STK6;
        ADD_STK6: if (s_tvalid) next_state = ADD_STK7;
        ADD_STK7: if (s_tvalid) next_state = ADD_PX0;
        ADD_PX0:  if (s_tvalid) next_state = ADD_PX1;
        ADD_PX1:  if (s_tvalid) next_state = ADD_PX2;
        ADD_PX2:  if (s_tvalid) next_state = ADD_PX3;
        ADD_PX3:  if (s_tvalid) next_state = COMMIT;  // A msg ends here exactly

        // Execute — after qty, drain match_num (8 bytes) then commit
        EXEC_REF0: if (s_tvalid) next_state = EXEC_REF1;
        EXEC_REF1: if (s_tvalid) next_state = EXEC_REF2;
        EXEC_REF2: if (s_tvalid) next_state = EXEC_REF3;
        EXEC_REF3: if (s_tvalid) next_state = EXEC_REF4;
        EXEC_REF4: if (s_tvalid) next_state = EXEC_REF5;
        EXEC_REF5: if (s_tvalid) next_state = EXEC_REF6;
        EXEC_REF6: if (s_tvalid) next_state = EXEC_REF7;
        EXEC_REF7: if (s_tvalid) next_state = EXEC_QTY0;
        EXEC_QTY0: if (s_tvalid) next_state = EXEC_QTY1;
        EXEC_QTY1: if (s_tvalid) next_state = EXEC_QTY2;
        EXEC_QTY2: if (s_tvalid) next_state = EXEC_QTY3;
        // After qty: commit now, drain will consume match_num + anything else
        EXEC_QTY3: if (s_tvalid) next_state = COMMIT;

        // Delete — ends exactly at REF7
        DEL_REF0: if (s_tvalid) next_state = DEL_REF1;
        DEL_REF1: if (s_tvalid) next_state = DEL_REF2;
        DEL_REF2: if (s_tvalid) next_state = DEL_REF3;
        DEL_REF3: if (s_tvalid) next_state = DEL_REF4;
        DEL_REF4: if (s_tvalid) next_state = DEL_REF5;
        DEL_REF5: if (s_tvalid) next_state = DEL_REF6;
        DEL_REF6: if (s_tvalid) next_state = DEL_REF7;
        DEL_REF7: if (s_tvalid) next_state = COMMIT;

        // Replace
        REP_OREF0: if (s_tvalid) next_state = REP_OREF1;
        REP_OREF1: if (s_tvalid) next_state = REP_OREF2;
        REP_OREF2: if (s_tvalid) next_state = REP_OREF3;
        REP_OREF3: if (s_tvalid) next_state = REP_OREF4;
        REP_OREF4: if (s_tvalid) next_state = REP_OREF5;
        REP_OREF5: if (s_tvalid) next_state = REP_OREF6;
        REP_OREF6: if (s_tvalid) next_state = REP_OREF7;
        REP_OREF7: if (s_tvalid) next_state = REP_NREF0;
        REP_NREF0: if (s_tvalid) next_state = REP_NREF1;
        REP_NREF1: if (s_tvalid) next_state = REP_NREF2;
        REP_NREF2: if (s_tvalid) next_state = REP_NREF3;
        REP_NREF3: if (s_tvalid) next_state = REP_NREF4;
        REP_NREF4: if (s_tvalid) next_state = REP_NREF5;
        REP_NREF5: if (s_tvalid) next_state = REP_NREF6;
        REP_NREF6: if (s_tvalid) next_state = REP_NREF7;
        REP_NREF7: if (s_tvalid) next_state = REP_QTY0;
        REP_QTY0:  if (s_tvalid) next_state = REP_QTY1;
        REP_QTY1:  if (s_tvalid) next_state = REP_QTY2;
        REP_QTY2:  if (s_tvalid) next_state = REP_QTY3;
        REP_QTY3:  if (s_tvalid) next_state = REP_PX0;
        REP_PX0:   if (s_tvalid) next_state = REP_PX1;
        REP_PX1:   if (s_tvalid) next_state = REP_PX2;
        REP_PX2:   if (s_tvalid) next_state = REP_PX3;
        REP_PX3:   if (s_tvalid) next_state = COMMIT;

        // Stock directory
        R_STK0: if (s_tvalid) next_state = R_STK1;
        R_STK1: if (s_tvalid) next_state = R_STK2;
        R_STK2: if (s_tvalid) next_state = R_STK3;
        R_STK3: if (s_tvalid) next_state = R_STK4;
        R_STK4: if (s_tvalid) next_state = R_STK5;
        R_STK5: if (s_tvalid) next_state = R_STK6;
        R_STK6: if (s_tvalid) next_state = R_STK7;
        R_STK7: if (s_tvalid) next_state = DRAIN; // drain rest of R message

        // COMMIT: output valid for 1 cycle, keep tready high
        // If tlast was seen on the last data byte, skip DRAIN -> go IDLE
        // Otherwise DRAIN remaining bytes until tlast
        COMMIT: begin
            s_tready   = 1;
            next_state = tlast_seen ? IDLE : DRAIN;
        end

        // DRAIN: consume bytes until tlast
        DRAIN: begin
            s_tready = 1;
            if (s_tvalid && s_tlast) next_state = IDLE;
        end

        default: next_state = IDLE;
    endcase
end

endmodule
