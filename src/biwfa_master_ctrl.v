`timescale 1ns / 1ps

module biwfa_master_ctrl #(
    parameter SCORE_WIDTH = 10,
    parameter K_WIDTH = 10,
    parameter OFFSET_WIDTH = 14,
    parameter THRESHOLD_LEN = 4 // Sub-problems of length <= 4 are solved by Base Case Solver
)(
    input  wire clk,
    input  wire rst_n,
    
    // Core Control
    input  wire start,
    output reg  done,
    input  wire [OFFSET_WIDTH-1:0] seq_q_len,
    input  wire [OFFSET_WIDTH-1:0] seq_r_len,
    
    // Segmentation Stack Interface
    output reg  stack_push,
    output reg  stack_pop,
    output reg  [OFFSET_WIDTH-1:0] push_q_start,
    output reg  [OFFSET_WIDTH-1:0] push_q_end,
    output reg  [OFFSET_WIDTH-1:0] push_r_start,
    output reg  [OFFSET_WIDTH-1:0] push_r_end,
    input  wire [OFFSET_WIDTH-1:0] pop_q_start,
    input  wire [OFFSET_WIDTH-1:0] pop_q_end,
    input  wire [OFFSET_WIDTH-1:0] pop_r_start,
    input  wire [OFFSET_WIDTH-1:0] pop_r_end,
    input  wire stack_empty,
    
    // Engine Control (Dual WFA DP)
    output reg  engine_start,
    output reg  [OFFSET_WIDTH-1:0] engine_q_start,
    output reg  [OFFSET_WIDTH-1:0] engine_q_end,
    output reg  [OFFSET_WIDTH-1:0] engine_r_start,
    output reg  [OFFSET_WIDTH-1:0] engine_r_end,
    input  wire engine_done, // Indicates either collision found or max extensions met
    input  wire collision_found,
    input  wire [SCORE_WIDTH-1:0] collision_s,
    input  wire signed [K_WIDTH-1:0] collision_k,
    input  wire [OFFSET_WIDTH-1:0] collision_x,
    
    // Base Solver trigger
    output reg  base_solve_start,
    input  wire base_solve_done
);

    localparam IDLE           = 4'd0;
    localparam INIT_PUSH      = 4'd1;
    localparam POP_EVAL       = 4'd2;
    localparam CHECK_BASE     = 4'd3;
    localparam RUN_WFA        = 4'd4;
    localparam WAIT_WFA       = 4'd5;
    localparam PUSH_RIGHT     = 4'd6;
    localparam PUSH_LEFT      = 4'd7;
    localparam SOLVE_BASE     = 4'd8;
    localparam FINISH         = 4'd9;

    reg [3:0] state;
    
    // Latched state of popped segment bounds
    reg [OFFSET_WIDTH-1:0] cur_q_start, cur_q_end, cur_r_start, cur_r_end;
    
    // Latched collision point globally
    reg [OFFSET_WIDTH-1:0] q_star, r_star;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done <= 0;
            stack_push <= 0;
            stack_pop <= 0;
            engine_start <= 0;
            base_solve_start <= 0;
        end else begin
            stack_push <= 0;
            stack_pop <= 0;
            engine_start <= 0;
            base_solve_start <= 0;
            
            case (state)
                IDLE: begin
                    done <= 0;
                    if (start) begin
                        // Push fully bounded sequences: [0, N][0, M]
                        push_q_start <= 0;
                        push_q_end   <= seq_q_len;
                        push_r_start <= 0;
                        push_r_end   <= seq_r_len;
                        stack_push   <= 1;
                        state        <= INIT_PUSH;
                    end
                end
                
                INIT_PUSH: begin
                    // After the initial push, enter the pop/eval loop
                    state <= POP_EVAL;
                end
                
                POP_EVAL: begin
                    if (stack_empty) begin
                        state <= FINISH; // All segments resolved
                    end else begin
                        stack_pop <= 1;
                        state <= CHECK_BASE;
                    end
                end
                
                CHECK_BASE: begin
                    // FWFT reads valid immediately after pop pulse
                    cur_q_start <= pop_q_start;
                    cur_q_end   <= pop_q_end;
                    cur_r_start <= pop_r_start;
                    cur_r_end   <= pop_r_end;
                    
                    if ((pop_q_end - pop_q_start) <= THRESHOLD_LEN || 
                        (pop_r_end - pop_r_start) <= THRESHOLD_LEN) begin
                        // Subproblem is too tiny, use direct base solver to emit string
                        base_solve_start <= 1;
                        state <= SOLVE_BASE;
                    end else begin
                        // Proceed to dual wavefron DP
                        engine_q_start <= pop_q_start;
                        engine_q_end   <= pop_q_end;
                        engine_r_start <= pop_r_start;
                        engine_r_end   <= pop_r_end;
                        engine_start   <= 1;
                        state          <= WAIT_WFA;
                    end
                end
                
                WAIT_WFA: begin
                    if (engine_done) begin
                        if (collision_found) begin
                            // Calculate global indices safely mapped to Forward perspective
                            // q* = q_start + x
                            // r* = r_start + x - k
                            q_star <= cur_q_start + collision_x;
                            // Need signed math to correctly add negative k if present. 
                            r_star <= cur_r_start + collision_x - collision_k;
                            
                            if (collision_s == 0) begin
                                // Perfect match over segment! No sub-problems needed, handled implicitly as Base
                                base_solve_start <= 1;
                                state <= SOLVE_BASE;
                            end else begin
                                // Divide and push
                                state <= PUSH_RIGHT;
                            end
                        end else begin
                            // Handle sequence max-out gracefully without collision (e.g. alignment divergence limit)
                            // Normally BiWFA guarantees intersection if edit distance bounds allow it. 
                            // If memory runs out before intersection, it's an alignment fail state.
                            state <= POP_EVAL; 
                        end
                    end
                end
                
                PUSH_RIGHT: begin
                    // Right sub-block goes precisely from (q_star, r_star) to (q_end, r_end)
                    push_q_start <= q_star;
                    push_q_end   <= cur_q_end;
                    push_r_start <= r_star;
                    push_r_end   <= cur_r_end;
                    stack_push   <= 1;
                    state        <= PUSH_LEFT;
                end
                
                PUSH_LEFT: begin
                    // Left sub-block goes precisely from (q_start, r_start) to (q_star, r_star)
                    push_q_start <= cur_q_start;
                    push_q_end   <= q_star;
                    push_r_start <= cur_r_start;
                    push_r_end   <= r_star;
                    stack_push   <= 1;
                    state        <= POP_EVAL;
                end
                
                SOLVE_BASE: begin
                    if (base_solve_done) begin
                        state <= POP_EVAL;
                    end
                end
                
                FINISH: begin
                    done <= 1;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
