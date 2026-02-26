`timescale 1ns / 1ps

module biwfa_intersect #(
    parameter K_WIDTH = 10,
    parameter OFFSET_WIDTH = 14,
    parameter SCORE_WIDTH = 10,
    parameter NULL_OFFSET = 14'h3FFF
)(
    input  wire clk,
    input  wire rst_n,
    
    // Iteration params
    input  wire [SCORE_WIDTH-1:0] current_s,
    input  wire signed [K_WIDTH-1:0] current_k_fwd,
    input  wire [OFFSET_WIDTH-1:0] sub_q_len,
    input  wire [OFFSET_WIDTH-1:0] sub_r_len,
    
    // Streamed offset values from both matrices
    // FWD: O(s, k_fwd)
    // BWD: O(s, k_bwd) where k_bwd = (sub_q_len - sub_r_len) - k_fwd
    input  wire [OFFSET_WIDTH-1:0] wf_fwd_x,
    input  wire [OFFSET_WIDTH-1:0] wf_bwd_x,
    input  wire check_valid, // Asserted when both wf_fwd_x and wf_bwd_x are valid for current_k_fwd
    
    // Control
    input  wire start_new_iteration, // Clears intersection state
    
    // Output
    output reg intersection_found,
    output reg [SCORE_WIDTH-1:0] intersect_s,
    output reg signed [K_WIDTH-1:0] intersect_k_fwd,
    output reg [OFFSET_WIDTH-1:0] intersect_x_fwd
);

    // Mathematics: Overlap occurs if FWD distance + BWD distance >= total Length N
    wire overlap_condition = (wf_fwd_x != NULL_OFFSET) && (wf_bwd_x != NULL_OFFSET) && 
                             ((wf_fwd_x + wf_bwd_x) >= sub_q_len);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            intersection_found <= 0;
            intersect_s <= 0;
            intersect_k_fwd <= 0;
            intersect_x_fwd <= 0;
        end else begin
            if (start_new_iteration) begin
                intersection_found <= 0;
            end else if (!intersection_found && check_valid && overlap_condition) begin
                // Hit! Latch the highest coordinates
                intersection_found <= 1;
                intersect_s <= current_s;
                intersect_k_fwd <= current_k_fwd;
                
                // If it overlapped by extending past the boundary, 
                // the true intersection is bounded by max reach.
                // We trust wf_fwd_x as the split coordinate for the sequence break.
                intersect_x_fwd <= (wf_fwd_x > sub_q_len) ? sub_q_len : wf_fwd_x; 
            end
        end
    end

endmodule
