`timescale 1ns / 1ps

module biwfa_base_solver #(
    parameter OFFSET_WIDTH = 14
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

    // Determines small deterministic paths.
    // Given the segmentation divide & conquer, leaf nodes are either:
    // A. Perfect Match (length Q == length R, characters identical)
    // B. Small edit block containing a pure mismatch, insertion, or deletion.

    localparam IDLE = 3'd0;
    localparam EVALUATE = 3'd1;
    localparam WAIT_FETCH = 3'd2;
    localparam EMIT = 3'd3;
    
    reg [2:0] state;
    
    wire [OFFSET_WIDTH-1:0] len_q = q_end - q_start;
    wire [OFFSET_WIDTH-1:0] len_r = r_end - r_start;
    
    reg [OFFSET_WIDTH-1:0] cur_q;
    reg [OFFSET_WIDTH-1:0] cur_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 0;
            fetch_req <= 0;
            cigar_valid <= 0;
            cigar_len <= 0;
            cigar_op <= 0;
        end else begin
            done <= 0;
            fetch_req <= 0;
            cigar_valid <= 0;
            cigar_len <= 0;
            
            case (state)
                IDLE: begin
                    if (start) begin
                        cur_q <= q_start;
                        cur_r <= r_start;
                        state <= EVALUATE;
                    end
                end
                
                EVALUATE: begin
                    if (cur_q >= q_end && cur_r >= r_end) begin
                        // Reached bounds
                        done <= 1;
                        state <= IDLE;
                    end else if (cur_q >= q_end) begin
                        // Q exhausted, remaining are insertions into R (or vice versa based on perspective)
                        // If R is longer => Deletion from Q
                        cigar_valid <= 1;
                        cigar_op <= 2'd2; // Del
                        cigar_len <= r_end - cur_r;
                        cur_r <= r_end;
                    end else if (cur_r >= r_end) begin
                        // R exhausted
                        cigar_valid <= 1;
                        cigar_op <= 2'd1; // Ins
                        cigar_len <= q_end - cur_q;
                        cur_q <= q_end;
                    end else begin
                        // Both valid, fetch chars
                        fetch_req <= 1;
                        fetch_q_addr <= cur_q;
                        fetch_r_addr <= cur_r;
                        state <= WAIT_FETCH;
                    end
                end
                
                WAIT_FETCH: begin
                    if (fetch_valid) begin
                        cigar_valid <= 1;
                        cigar_len <= 1; // Emit 1 base at a time to coalescer
                        
                        if (fetch_q_char == fetch_r_char) begin
                            cigar_op <= 2'd0; // Match
                        end else begin
                            cigar_op <= 2'd3; // Mismatch
                        end
                        cur_q <= cur_q + 1;
                        cur_r <= cur_r + 1;
                        state <= EVALUATE;
                    end
                end
            endcase
        end
    end

endmodule
