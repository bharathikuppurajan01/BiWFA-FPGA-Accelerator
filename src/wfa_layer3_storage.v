`timescale 1ns / 1ps

module wfa_layer3_storage #(
    parameter K_MIN = -512,
    parameter K_MAX = 512,
    parameter K_WIDTH = 10,
    parameter OFFSET_WIDTH = 14,
    parameter NULL_OFFSET = 14'h3FFF
)(
    input  wire clk,
    input  wire rst_n,

    // Write Port from Layer 2
    input  wire wf_in_valid,
    input  wire signed [K_WIDTH-1:0] wf_in_k,
    input  wire [OFFSET_WIDTH-1:0] wf_in_x,

    // Iteration Synchronization from Master FSM
    input  wire next_score_step,
    input  wire signed [K_WIDTH-1:0] k_min_active,
    input  wire signed [K_WIDTH-1:0] k_max_active,

    // Read Ports feeding Layer 2 expansion queries
    input  wire req_wf_read,
    input  wire signed [K_WIDTH-1:0] req_k,
    output wire [OFFSET_WIDTH-1:0] wf_out_del, // O(s-1, k+1)
    output wire [OFFSET_WIDTH-1:0] wf_out_ins, // O(s-1, k-1)
    output wire [OFFSET_WIDTH-1:0] wf_out_mis, // O(s-1, k)
    
    // Read Ports feeding Layer 4 BiWFA Intersection logic
    output wire [OFFSET_WIDTH-1:0] current_fwd_x, // O(s, k)
    
    // Cross-check port for the opposite engine
    input  wire signed [K_WIDTH-1:0] cross_k,
    output wire [OFFSET_WIDTH-1:0] cross_wf_curr,
    
    // Clear pipeline for subproblem runs
    input  wire clear_all
);

    localparam ARRAY_SIZE = K_MAX - K_MIN + 1;
    
    // In a full BiWFA we need identical arrays for BWD_curr and BWD_next.
    // For this module structure, we track Forward paths mapping.
    // To complete the hardware integration, a dual-instance or combined Fwd/Bwd memory is used.
    reg [OFFSET_WIDTH-1:0] WF_curr [0:ARRAY_SIZE-1];
    reg [OFFSET_WIDTH-1:0] WF_next [0:ARRAY_SIZE-1];

    wire [K_WIDTH-1:0] addr_in = wf_in_k - K_MIN;
    
    // Base Read Address computation
    wire signed [K_WIDTH-1:0] read_k_del = req_k + 1;
    wire signed [K_WIDTH-1:0] read_k_ins = req_k - 1;
    wire signed [K_WIDTH-1:0] read_k_mis = req_k;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i=0; i<ARRAY_SIZE; i=i+1) begin
                WF_curr[i] <= NULL_OFFSET; // Sentinel out of bounds
                WF_next[i] <= NULL_OFFSET;
            end
        end else begin
            if (clear_all) begin
                for (i=0; i<ARRAY_SIZE; i=i+1) begin
                    WF_curr[i] <= NULL_OFFSET;
                    WF_next[i] <= NULL_OFFSET;
                end
            end else begin
                if (wf_in_valid) begin
                    WF_next[addr_in] <= wf_in_x;
                end
                
                if (next_score_step) begin
                    for (i=0; i<ARRAY_SIZE; i=i+1) begin
                        WF_curr[i] <= WF_next[i];
                    end
                end
            end
        end
    end

    // Combinatorial Read with Sentinel Guarding
    // If request attempts to read outside the Master FSM's valid k boundary, return NULL_OFFSET
    wire del_valid = (read_k_del >= (k_min_active+1) && read_k_del <= (k_max_active-1));
    wire ins_valid = (read_k_ins >= (k_min_active+1) && read_k_ins <= (k_max_active-1));
    wire mis_valid = (read_k_mis >= (k_min_active+1) && read_k_mis <= (k_max_active-1));

    assign wf_out_del = (del_valid) ? WF_curr[read_k_del - K_MIN] : NULL_OFFSET;
    assign wf_out_ins = (ins_valid) ? WF_curr[read_k_ins - K_MIN] : NULL_OFFSET;
    assign wf_out_mis = (mis_valid) ? WF_curr[read_k_mis - K_MIN] : NULL_OFFSET;
    
    assign current_fwd_x = WF_next[req_k - K_MIN]; // Exporting the newly extended value for intercept tests

    // Cross-Check Port (Asynchronous read of previous score iteration)
    wire cross_valid = (cross_k >= k_min_active && cross_k <= k_max_active);
    assign cross_wf_curr = cross_valid ? WF_curr[cross_k - K_MIN] : NULL_OFFSET;

endmodule
