`timescale 1ns / 1ps

module wfa_master_ctrl #(
    parameter SCORE_WIDTH = 10,
    parameter K_WIDTH = 10,
    parameter OFFSET_WIDTH = 14
)(
    input  wire clk,
    input  wire rst_n,
    
    // Core Control
    input  wire start,
    output reg  done,
    output reg  [SCORE_WIDTH-1:0] final_score,
    
    // State Iteration
    output reg  [SCORE_WIDTH-1:0] current_s,
    output reg  signed [K_WIDTH-1:0] current_k_proc,
    output reg  k_proc_valid, // Tells Layer 2/3 to process current_k_proc
    output reg  next_score_step, // Triggers WF_next -> WF_curr swap
    
    // Global Loop Bounds
    output reg  signed [K_WIDTH-1:0] k_min,
    output reg  signed [K_WIDTH-1:0] k_max,
    
    // Termination Flags from Intersection/Bounds logic
    input  wire alignment_complete_flag, // Tied to O(s,k) >= N && O(s,k)-k >= M
    input  wire intersection_found,      // From layer 4
    
    // Handshake from DPU Layer 2
    input  wire dpu_done                 // Asserted when DPU finishes a diagonal
);

    localparam IDLE = 3'd0;
    localparam INIT_S0 = 3'd1;
    localparam RUN_DIAGS = 3'd2;
    localparam WAIT_DPU = 3'd3;
    localparam SWAP_WF = 3'd4;
    localparam DONE_STATE = 3'd5;

    reg [2:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 0;
            final_score <= 0;
            current_s <= 0;
            current_k_proc <= 0;
            k_proc_valid <= 0;
            next_score_step <= 0;
            k_min <= 0;
            k_max <= 0;
        end else begin
            k_proc_valid <= 0;
            next_score_step <= 0;
            
            case (state)
                IDLE: begin
                    done <= 0;
                    if (start) begin
                        current_s <= 0;
                        k_min <= 0;
                        k_max <= 0;
                        state <= INIT_S0;
                    end
                end
                
                INIT_S0: begin
                    // Base condition s=0
                    current_k_proc <= k_min; // which is 0
                    k_proc_valid <= 1;
                    state <= WAIT_DPU;
                end
                
                RUN_DIAGS: begin
                    if (alignment_complete_flag || intersection_found) begin
                        final_score <= current_s;
                        state <= DONE_STATE;
                    end else if (current_k_proc < k_max) begin
                        current_k_proc <= current_k_proc + 1;
                        k_proc_valid <= 1;
                        state <= WAIT_DPU;
                    end else begin
                        // Finished all diagonals for current score s
                        state <= SWAP_WF;
                    end
                end
                
                WAIT_DPU: begin
                    // Wait for Layer 2/3 pipeline to finish this diagonal.
                    if (dpu_done) begin
                        state <= RUN_DIAGS; // Go back to increment/check diags loop
                    end
                end
                
                SWAP_WF: begin
                    // Trigger swap inside Layer 3 Memory
                    next_score_step <= 1;
                    
                    // Increment score and widen diagonal wavefront logic
                    current_s <= current_s + 1;
                    k_min <= k_min - 1;
                    k_max <= k_max + 1;
                    
                    // Reset diagonal iterator for next score
                    // Old k_min is used here. We want new_k_min - 1 (which is old k_min - 2)
                    current_k_proc <= k_min - 2; 
                    state <= RUN_DIAGS;
                end
                
                DONE_STATE: begin
                    done <= 1;
                end
            endcase
        end
    end

endmodule
