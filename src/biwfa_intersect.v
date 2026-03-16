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
    
    // Streamed offset values directly from L3 logic
    input  wire [OFFSET_WIDTH-1:0] wf_fwd_next_x, // O^fwd(s, k_proc)
    input  wire [OFFSET_WIDTH-1:0] bwd_cross_curr_x, // O^bwd(s-1, mapped_k_bwd)
    
    input  wire [OFFSET_WIDTH-1:0] wf_bwd_next_x, // O^bwd(s, k_proc)
    input  wire [OFFSET_WIDTH-1:0] fwd_cross_curr_x, // O^fwd(s-1, mapped_k_fwd)
    
    input  wire check_valid, // Asserted when streams are valid for current_k_proc
    
    // Outputs mapped diagonal requests back up to top wrapper
    output wire signed [K_WIDTH-1:0] req_cross_bwd_k,
    output wire signed [K_WIDTH-1:0] req_cross_fwd_k,
    
    // Control
    input  wire start_new_iteration, // Clears intersection state
    
    // Output
    output reg intersection_found,
    output reg [SCORE_WIDTH-1:0] intersect_s,
    output reg signed [K_WIDTH-1:0] intersect_k_fwd,
    output reg [OFFSET_WIDTH-1:0] intersect_x_fwd
);

    wire signed [K_WIDTH-1:0] delta = sub_q_len - sub_r_len;
    
    // The opposite diagonals to check (k_f + k_b = N - M)
    assign req_cross_bwd_k = delta - current_k_fwd; // bwd reads this
    assign req_cross_fwd_k = delta - current_k_fwd; // fwd reads this
    
    // Mathematics: Overlap occurs if FWD distance + BWD distance >= total Length N
    // Cond 1: FWD just advanced. Check if it hit BWD's previous wavefront.
    wire cond1_hit = (wf_fwd_next_x != NULL_OFFSET) && (bwd_cross_curr_x != NULL_OFFSET) && 
                     ((wf_fwd_next_x + bwd_cross_curr_x) >= sub_q_len);
                     
    // Cond 2: BWD just advanced. Check if it hit FWD's previous wavefront.                 
    wire cond2_hit = (wf_bwd_next_x != NULL_OFFSET) && (fwd_cross_curr_x != NULL_OFFSET) && 
                     ((fwd_cross_curr_x + wf_bwd_next_x) >= sub_q_len);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            intersection_found <= 0;
            intersect_s <= 0;
            intersect_k_fwd <= 0;
            intersect_x_fwd <= 0;
        end else begin
            if (start_new_iteration) begin
                intersection_found <= 0;
            end else if (!intersection_found && check_valid) begin
                // Optional debug print (disabled by default to keep Tcl output clean)
                // `ifdef BIWFA_DEBUG_INTERSECT
                // $display("[INTERSECT SCORE %0d] check_valid=1, fwd_x=%0d, bwd_curr=%0d, bwd_x=%0d, fwd_curr=%0d, q_len=%0d, cond1=%b, cond2=%b",
                //          current_s, wf_fwd_next_x, bwd_cross_curr_x, wf_bwd_next_x, fwd_cross_curr_x, sub_q_len, cond1_hit, cond2_hit);
                // `endif
                if (cond1_hit) begin
                    intersection_found <= 1;
                    intersect_s <= current_s; // Score where they met
                    intersect_k_fwd <= current_k_fwd;
                    // FWD dictates coordinate
                    intersect_x_fwd <= (wf_fwd_next_x > sub_q_len) ? sub_q_len : wf_fwd_next_x;
                end else if (cond2_hit) begin
                    intersection_found <= 1;
                    intersect_s <= current_s; // Score where they met
                    // FWD diagonal corresponding to BWD current_k_proc
                    intersect_k_fwd <= req_cross_fwd_k; 
                    // FWD mapping mapped it to this coordinate
                    intersect_x_fwd <= (fwd_cross_curr_x > sub_q_len) ? sub_q_len : fwd_cross_curr_x;
                end
            end
        end
    end

endmodule
