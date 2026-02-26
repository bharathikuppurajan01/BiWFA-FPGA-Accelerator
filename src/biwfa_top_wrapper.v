`timescale 1ns / 1ps

module biwfa_top_wrapper #(
    parameter SCORE_WIDTH = 10,
    parameter MAX_SEQ_LEN = 1000,
    parameter ADDR_WIDTH = 14,
    parameter K_WIDTH = 10,
    parameter OFFSET_WIDTH = 14,
    parameter THRESHOLD_LEN = 4
)(
    input  wire clk,
    input  wire rst_n,

    // System Control
    input  wire start_alignment,
    input  wire [OFFSET_WIDTH-1:0] seq_q_len,
    input  wire [OFFSET_WIDTH-1:0] seq_r_len,
    
    // Status
    output wire system_done,
    
    // Compressed Output Interface
    output wire align_valid,
    output wire [1:0] op_code,
    output wire [OFFSET_WIDTH-1:0] op_length
);

    // Segmentation Stack wires
    wire stack_push, stack_pop, stack_empty, stack_full;
    wire [OFFSET_WIDTH-1:0] push_q_star, push_q_end, push_r_star, push_r_end;
    wire [OFFSET_WIDTH-1:0] pop_q_star, pop_q_end, pop_r_star, pop_r_end;

    // Engine Control wires
    wire engine_start, engine_done;
    wire [OFFSET_WIDTH-1:0] engine_q_start, engine_q_end, engine_r_start, engine_r_end;
    
    // Intersection wires
    wire collision_found;
    wire [SCORE_WIDTH-1:0] collision_s;
    wire signed [K_WIDTH-1:0] collision_k;
    wire [OFFSET_WIDTH-1:0] collision_x;
    
    // Base Solver wires
    wire base_solve_start, base_solve_done;
    wire base_fetch_req;
    wire [OFFSET_WIDTH-1:0] base_fetch_q_addr, base_fetch_r_addr;
    wire base_fetch_valid = 1'b0; // TODO: Connect to Layer 1 RAM
    wire [7:0] base_fetch_q_char = 8'd0;
    wire [7:0] base_fetch_r_char = 8'd0;
    
    wire base_cigar_valid;
    wire [1:0] base_cigar_op;
    wire [OFFSET_WIDTH-1:0] base_cigar_len;

    // 1. Segmentation Stack
    biwfa_seg_stack #(
        .ADDR_WIDTH(OFFSET_WIDTH), .MAX_DEPTH_BITS(10)
    ) SEG_STACK (
        .clk(clk), .rst_n(rst_n),
        .push(stack_push),
        .in_q_start(push_q_star), .in_q_end(push_q_end), .in_r_start(push_r_star), .in_r_end(push_r_end),
        .pop(stack_pop),
        .out_q_start(pop_q_star), .out_q_end(pop_q_end), .out_r_start(pop_r_star), .out_r_end(pop_r_end),
        .empty(stack_empty), .full(stack_full)
    );

    // 2. Master FSM
    biwfa_master_ctrl #(
        .SCORE_WIDTH(SCORE_WIDTH), .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH), .THRESHOLD_LEN(THRESHOLD_LEN)
    ) MASTER (
        .clk(clk), .rst_n(rst_n), .start(start_alignment), .done(system_done),
        .seq_q_len(seq_q_len), .seq_r_len(seq_r_len),
        .stack_push(stack_push), .stack_pop(stack_pop),
        .push_q_start(push_q_star), .push_q_end(push_q_end), .push_r_start(push_r_star), .push_r_end(push_r_end),
        .pop_q_start(pop_q_star), .pop_q_end(pop_q_end), .pop_r_start(pop_r_star), .pop_r_end(pop_r_end),
        .stack_empty(stack_empty),
        .engine_start(engine_start),
        .engine_q_start(engine_q_start), .engine_q_end(engine_q_end), .engine_r_start(engine_r_start), .engine_r_end(engine_r_end),
        .engine_done(engine_done),
        .collision_found(collision_found), .collision_s(collision_s), .collision_k(collision_k), .collision_x(collision_x),
        .base_solve_start(base_solve_start), .base_solve_done(base_solve_done)
    );

    // 3. BiWFA Execution Engine (Simulated stub for integration)
    // The dual engine requires instantiation of two wfa_layer2_compute units modified for bidirectional bounds.
    // We will leave this stubbed pending explicit module implementation, since it requires mirroring the L2/L3 structs.
    assign engine_done = 1'b0;
    assign collision_found = 1'b0;
    assign collision_s = 0;
    assign collision_k = 0;
    assign collision_x = 0;

    // 4. Base Case Sub-solver
    biwfa_base_solver #(
        .OFFSET_WIDTH(OFFSET_WIDTH)
    ) BASE_SOLVER (
        .clk(clk), .rst_n(rst_n),
        .start(base_solve_start),
        .q_start(pop_q_star), .q_end(pop_q_end), .r_start(pop_r_star), .r_end(pop_r_end),
        .done(base_solve_done),
        .fetch_req(base_fetch_req), .fetch_q_addr(base_fetch_q_addr), .fetch_r_addr(base_fetch_r_addr),
        .fetch_valid(base_fetch_valid), .fetch_q_char(base_fetch_q_char), .fetch_r_char(base_fetch_r_char),
        .cigar_valid(base_cigar_valid), .cigar_op(base_cigar_op), .cigar_len(base_cigar_len)
    );

    // 5. CIGAR Encoder
    biwfa_cigar_coalescer #(
        .OFFSET_WIDTH(OFFSET_WIDTH)
    ) CIGAR_ENC (
        .clk(clk), .rst_n(rst_n),
        .valid_in(base_cigar_valid), .op_in(base_cigar_op), .len_in(base_cigar_len),
        .end_of_alignment(system_done),
        .valid_out(align_valid), .op_out(op_code), .len_out(op_length)
    );

endmodule
