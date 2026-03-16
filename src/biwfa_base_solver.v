`timescale 1ns / 1ps

// Base-case solver (leaf) using Needleman–Wunsch global alignment DP.
// Scoring model:
// - match    = +1
// - mismatch = -1
// - gap      = -1
//
// Emits a full edit script using op codes:
// 0: M, 1: I, 2: D, 3: X
//
// Note: Designed for small leaf segments (<= MAX_LEAF_LEN). For longer segments,
// it falls back to a simple diagonal walk (legacy behavior).

module biwfa_base_solver #(
    parameter OFFSET_WIDTH = 14,
    parameter MAX_LEAF_LEN = 32,
    parameter SCORE_WIDTH  = 8
)(
    input  wire clk,
    input  wire rst_n,
    
    // Trigger from Master
    input  wire start,
    input  wire [OFFSET_WIDTH-1:0] q_start,
    input  wire [OFFSET_WIDTH-1:0] q_end,
    input  wire [OFFSET_WIDTH-1:0] r_start,
    input  wire [OFFSET_WIDTH-1:0] r_end,
    
    // Handshake back to Master
    output reg  done,
    
    // Fetch interface to Layer 1 (Sequence RAMs)
    output reg  fetch_req,
    output reg  [OFFSET_WIDTH-1:0] fetch_q_addr,
    output reg  [OFFSET_WIDTH-1:0] fetch_r_addr,
    input  wire fetch_valid,
    input  wire [7:0] fetch_q_char,
    input  wire [7:0] fetch_r_char,
    
    // Output Interface to CIGAR Encoder
    output reg  cigar_valid,
    output reg  [1:0] cigar_op, // 0: Match, 1: Ins (Q>R), 2: Del (R>Q), 3: Mismatch
    output reg  [OFFSET_WIDTH-1:0] cigar_len
);

    localparam BP_DIAG = 2'd0;
    // In DP coordinates (i over Q, j over R):
    // - UP   (i-1,j) -> (i,j): consume Q, gap in R => Insertion (I)
    // - LEFT (i,j-1) -> (i,j): consume R, gap in Q => Deletion  (D)
    localparam BP_UP   = 2'd1;
    localparam BP_LEFT = 2'd2;

    localparam S_IDLE      = 3'd0;
    localparam S_LOAD      = 3'd1;
    localparam S_DP_INIT   = 3'd2;
    localparam S_DP_FILL   = 3'd3;
    localparam S_TRACEBACK = 3'd4;
    localparam S_EMIT      = 3'd5;

    reg [2:0] state;

    wire [OFFSET_WIDTH-1:0] len_q_w = q_end - q_start;
    wire [OFFSET_WIDTH-1:0] len_r_w = r_end - r_start;

    reg [5:0] len_q, len_r;

    reg fallback_mode;
    reg [OFFSET_WIDTH-1:0] fb_q, fb_r;

    // local buffers
    reg [7:0] q_buf [0:MAX_LEAF_LEN-1];
    reg [7:0] r_buf [0:MAX_LEAF_LEN-1];
    reg [5:0] load_idx;

    // dp and backpointers
    reg signed [SCORE_WIDTH-1:0] dp [0:MAX_LEAF_LEN][0:MAX_LEAF_LEN];
    reg [1:0] bp [0:MAX_LEAF_LEN][0:MAX_LEAF_LEN];

    reg [5:0] i_idx, j_idx;

    // traceback op stack
    reg [1:0] op_stack [0:(2*MAX_LEAF_LEN)-1];
    reg [6:0] op_sp;
    reg [6:0] emit_idx;
    reg has_gap;
    reg direct_emit_mode;
    reg [5:0] direct_emit_idx;

    reg signed [SCORE_WIDTH-1:0] score_diag, score_up, score_left;
    reg signed [SCORE_WIDTH-1:0] best_score;
    reg [1:0] best_bp;

    integer x, y;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done <= 0;
            fetch_req <= 0;
            cigar_valid <= 0;
            cigar_len <= 0;
            cigar_op <= 0;
            len_q <= 0;
            len_r <= 0;
            load_idx <= 0;
            i_idx <= 0;
            j_idx <= 0;
            op_sp <= 0;
            emit_idx <= 0;
            has_gap <= 0;
            direct_emit_mode <= 0;
            direct_emit_idx <= 0;
            fallback_mode <= 0;
            fb_q <= 0;
            fb_r <= 0;
        end else begin
            done <= 0;
            fetch_req <= 0;
            cigar_valid <= 0;
            cigar_len <= 0;
            
            case (state)
                S_IDLE: begin
                    if (start) begin
                        len_q <= (len_q_w > MAX_LEAF_LEN) ? MAX_LEAF_LEN[5:0] : len_q_w[5:0];
                        len_r <= (len_r_w > MAX_LEAF_LEN) ? MAX_LEAF_LEN[5:0] : len_r_w[5:0];
                        fallback_mode <= (len_q_w > MAX_LEAF_LEN) || (len_r_w > MAX_LEAF_LEN);

                        load_idx <= 0;
                        op_sp <= 0;
                        emit_idx <= 0;
                        has_gap <= 0;
                        direct_emit_mode <= 0;
                        direct_emit_idx <= 0;
                        fb_q <= q_start;
                        fb_r <= r_start;
                        state <= S_LOAD;
                    end
                end
                
                S_LOAD: begin
                    if (fallback_mode) begin
                        // Legacy diagonal walker fallback
                        if (fb_q >= q_end && fb_r >= r_end) begin
                            done <= 1;
                            state <= S_IDLE;
                        end else if (fb_q >= q_end) begin
                            cigar_valid <= 1;
                            cigar_op <= 2'd2; // Del
                            cigar_len <= r_end - fb_r;
                            fb_r <= r_end;
                        end else if (fb_r >= r_end) begin
                            cigar_valid <= 1;
                            cigar_op <= 2'd1; // Ins
                            cigar_len <= q_end - fb_q;
                            fb_q <= q_end;
                        end else begin
                            fetch_req <= 1;
                            fetch_q_addr <= fb_q;
                            fetch_r_addr <= fb_r;
                            if (fetch_valid) begin
                                cigar_valid <= 1;
                                cigar_len <= 1;
                                cigar_op <= (fetch_q_char == fetch_r_char) ? 2'd0 : 2'd3;
                                fb_q <= fb_q + 1;
                                fb_r <= fb_r + 1;
                            end
                        end
                    end else begin
                        // Load buffers; one fetch per index (both Q and R)
                        if (load_idx < len_q || load_idx < len_r) begin
                            fetch_req <= 1;
                            fetch_q_addr <= q_start + load_idx;
                            fetch_r_addr <= r_start + load_idx;
                            if (fetch_valid) begin
                                if (load_idx < len_q) q_buf[load_idx] <= fetch_q_char;
                                if (load_idx < len_r) r_buf[load_idx] <= fetch_r_char;
                                load_idx <= load_idx + 1;
                            end
                        end else begin
                            state <= S_DP_INIT;
                        end
                    end
                end

                S_DP_INIT: begin
                    dp[0][0] <= 0;
                    bp[0][0] <= BP_DIAG;

                    for (x = 1; x <= MAX_LEAF_LEN; x = x + 1) begin
                        if (x <= len_q) begin
                            dp[x][0] <= -x;
                            bp[x][0] <= BP_UP;
                        end else begin
                            dp[x][0] <= 0;
                            bp[x][0] <= BP_DIAG;
                        end
                    end

                    for (y = 1; y <= MAX_LEAF_LEN; y = y + 1) begin
                        if (y <= len_r) begin
                            dp[0][y] <= -y;
                            bp[0][y] <= BP_LEFT;
                        end else begin
                            dp[0][y] <= 0;
                            bp[0][y] <= BP_DIAG;
                        end
                    end

                    i_idx <= 1;
                    j_idx <= 1;
                    state <= S_DP_FILL;
                end

                S_DP_FILL: begin
                    if (i_idx <= len_q && j_idx <= len_r) begin
                        score_diag = dp[i_idx-1][j_idx-1] + ((q_buf[i_idx-1] == r_buf[j_idx-1]) ? 1 : -1);
                        score_up   = dp[i_idx-1][j_idx] - 1;
                        score_left = dp[i_idx][j_idx-1] - 1;

                        // prefer diag on ties, then up, then left
                        best_score = score_diag;
                        best_bp    = BP_DIAG;
                        if (score_up > best_score) begin
                            best_score = score_up;
                            best_bp    = BP_UP;
                        end
                        if (score_left > best_score) begin
                            best_score = score_left;
                            best_bp    = BP_LEFT;
                        end

                        dp[i_idx][j_idx] <= best_score;
                        bp[i_idx][j_idx] <= best_bp;

                        if (j_idx < len_r) begin
                            j_idx <= j_idx + 1;
                        end else begin
                            j_idx <= 1;
                            i_idx <= i_idx + 1;
                        end
                    end else begin
                        i_idx <= len_q;
                        j_idx <= len_r;
                        op_sp <= 0;
                        has_gap <= 0;
                        state <= S_TRACEBACK;
                    end
                end

                S_TRACEBACK: begin
                    if (i_idx > 0 || j_idx > 0) begin
                        if (i_idx > 0 && j_idx > 0 && bp[i_idx][j_idx] == BP_DIAG) begin
                            op_stack[op_sp] <= (q_buf[i_idx-1] == r_buf[j_idx-1]) ? 2'd0 : 2'd3;
                            op_sp <= op_sp + 1;
                            i_idx <= i_idx - 1;
                            j_idx <= j_idx - 1;
                        end else if (i_idx > 0 && (j_idx == 0 || bp[i_idx][j_idx] == BP_UP)) begin
                            // consume Q only -> gap in R => 'I'
                            op_stack[op_sp] <= 2'd1;
                            op_sp <= op_sp + 1;
                            i_idx <= i_idx - 1;
                            has_gap <= 1;
                        end else begin
                            // consume R only -> gap in Q => 'D'
                            op_stack[op_sp] <= 2'd2;
                            op_sp <= op_sp + 1;
                            j_idx <= j_idx - 1;
                            has_gap <= 1;
                        end
                    end else begin
                        if (op_sp == 0) begin
                            done <= 1;
                            state <= S_IDLE;
                        end else begin
                            // If traceback has no gaps and lengths match, emit directly from buffers
                            // to guarantee correct M/X placement for pure diagonal alignments.
                            if (!has_gap && (len_q == len_r)) begin
                                direct_emit_mode <= 1;
                                direct_emit_idx  <= 0;
                            end else begin
                                direct_emit_mode <= 0;
                                emit_idx <= op_sp - 1;
                            end
                            state <= S_EMIT;
                        end
                    end
                end

                S_EMIT: begin
                    cigar_valid <= 1;
                    cigar_len <= 1;
                    if (direct_emit_mode) begin
                        cigar_op <= (q_buf[direct_emit_idx] == r_buf[direct_emit_idx]) ? 2'd0 : 2'd3;
                        if (direct_emit_idx + 1 < len_q) begin
                            direct_emit_idx <= direct_emit_idx + 1;
                        end else begin
                            done <= 1;
                            state <= S_IDLE;
                        end
                    end else begin
                        cigar_op <= op_stack[emit_idx];
                        if (emit_idx > 0) begin
                            emit_idx <= emit_idx - 1;
                        end else begin
                            done <= 1;
                            state <= S_IDLE;
                        end
                    end
                    if (!direct_emit_mode && emit_idx == 0) begin
                        done <= 1;
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
