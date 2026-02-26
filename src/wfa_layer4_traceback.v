`timescale 1ns / 1ps

module wfa_layer4_traceback #(
    parameter OFFSET_WIDTH = 14,
    parameter K_WIDTH = 10,
    parameter SCORE_WIDTH = 10,
    parameter MAX_Q_LEN = 1000,
    parameter MAX_R_LEN = 1000,
    parameter NULL_OFFSET = 14'h3FFF
)(
    input  wire clk,
    input  wire rst_n,

    input  wire next_score_step,
    input  wire [SCORE_WIDTH-1:0] current_s,
    
    // Master FSM ranges to limit intercept checking
    input  wire signed [K_WIDTH-1:0] k_min_active,
    input  wire signed [K_WIDTH-1:0] k_max_active,

    // Interfaces mapping to Layer 3 Fwd and hypothetical Bwd sweeps
    // The Master sweeps k across intersecting offsets
    input  wire signed [K_WIDTH-1:0] check_k, 
    input  wire [OFFSET_WIDTH-1:0] wf_fwd_x,
    input  wire [OFFSET_WIDTH-1:0] wf_bwd_x,
    
    // Outputs signaling intersection
    output reg intersection_found,
    output reg signed [K_WIDTH-1:0] intersect_k,
    output reg [OFFSET_WIDTH-1:0] intersect_x,
    output reg [SCORE_WIDTH-1:0] intersect_s,
    
    // Output tracing recursion
    // Output tracing recursion
    output reg trace_segment_valid,
    output reg signed [K_WIDTH-1:0] trace_k,
    output reg [OFFSET_WIDTH-1:0] trace_x_start,
    output reg [OFFSET_WIDTH-1:0] trace_x_end,
    
    // Dynamic Sequence Length from top
    input  wire  [OFFSET_WIDTH-1:0] seq_len
);

    // Sequence properties for BiWFA mapping equation
    wire signed [K_WIDTH-1:0] mapped_bwd_k;
    // Real BiWFA intersection diagonal mapping: k_bwd = (N - M) - k_fwd
    // N = Q Length, M = R Length
    assign mapped_bwd_k = 0 - check_k; // For seq_len = seq_len, N-M is 0

    // Detect Intersection Condition (O^fwd_{s,k} + O^bwd_{s,mapped_k} >= N)
    // where N == seq_len. Ensure neither are NULL.
    wire is_valid_check = (wf_fwd_x != NULL_OFFSET) && (wf_bwd_x != NULL_OFFSET);
    wire overlap_condition = (wf_fwd_x + wf_bwd_x >= seq_len);
    
    // Fallback for Uni-Directional WFA (where wf_bwd_x is stubbed to NULL_OFFSET)
    wire fallback_condition = (wf_fwd_x != NULL_OFFSET) && (wf_fwd_x >= seq_len);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            intersection_found <= 0;
            intersect_k <= 0;
            intersect_x <= 0;
            intersect_s <= 0;
            trace_segment_valid <= 0;
        end else begin
            if (!intersection_found && ( (is_valid_check && overlap_condition) || fallback_condition )) begin
                // Collision Hit!
                intersection_found <= 1;
                intersect_k <= check_k;
                intersect_x <= wf_fwd_x; // The coordinate is safely the forward trace offset x
                intersect_s <= current_s;
                
                // Immediately kick out trace segment logic to reconstructor
                trace_segment_valid <= 1;
                trace_k <= check_k;
                trace_x_start <= wf_fwd_x - 1; // Simplified bounds start
                trace_x_end <= wf_fwd_x;
            end else begin
                trace_segment_valid <= 0;
            end
        end
    end

endmodule
