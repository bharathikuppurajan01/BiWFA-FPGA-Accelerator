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
    output wire [OFFSET_WIDTH-1:0] op_length,

    // Preload Interface (Layer 1 Memory)
    input  wire preload_en,
    input  wire [ADDR_WIDTH-1:0] preload_addr,
    input  wire [7:0] preload_q_char,
    input  wire [7:0] preload_r_char
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
    
    wire base_cigar_valid;
    wire [1:0] base_cigar_op;
    wire [OFFSET_WIDTH-1:0] base_cigar_len;

    // ---------------------------------------------------------
    // Shared Signals for Engines
    // ---------------------------------------------------------
    // FWD Engine Nets
    wire signed [K_WIDTH-1:0] fwd_current_k_proc, fwd_layer2_req_k, fwd_layer1_resp_k, fwd_layer2_wf_out_k;
    wire [OFFSET_WIDTH-1:0] fwd_layer2_req_x, fwd_layer2_wf_out_x, fwd_wf_out_del, fwd_wf_out_ins, fwd_wf_out_mis;
    wire [7:0] fwd_layer1_resp_q_char, fwd_layer1_resp_r_char;
    wire fwd_k_proc_valid, fwd_layer2_req_valid, fwd_layer1_req_ready, fwd_layer1_resp_valid, fwd_layer2_wf_out_valid;

    // BWD Engine Nets  
    wire signed [K_WIDTH-1:0] bwd_current_k_proc, bwd_layer2_req_k, bwd_layer1_resp_k, bwd_layer2_wf_out_k;
    wire [OFFSET_WIDTH-1:0] bwd_layer2_req_x, bwd_layer2_wf_out_x, bwd_wf_out_del, bwd_wf_out_ins, bwd_wf_out_mis;
    wire [7:0] bwd_layer1_resp_q_char, bwd_layer1_resp_r_char;
    wire bwd_k_proc_valid, bwd_layer2_req_valid, bwd_layer1_req_ready, bwd_layer1_resp_valid, bwd_layer2_wf_out_valid;

    // Score steps driven by Master FSM (mirrored here to drive both L2/L3)
    wire [SCORE_WIDTH-1:0] current_s;
    wire next_score_step;
    wire signed [K_WIDTH-1:0] k_min_active;
    wire signed [K_WIDTH-1:0] k_max_active;
    
    // ---------------------------------------------------------
    // DPU SYNCHRONIZATION
    // ---------------------------------------------------------
    // The FWD and BWD engines perform internal match extension loops. Since the sequence
    // content differs, they will frequently finish on different clock cycles.
    reg fwd_done_latch;
    reg bwd_done_latch;
    reg [OFFSET_WIDTH-1:0] fwd_x_latch;
    reg [OFFSET_WIDTH-1:0] bwd_x_latch;
    reg [K_WIDTH-1:0] fwd_k_latch;
    reg [K_WIDTH-1:0] bwd_k_latch;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fwd_done_latch <= 0;
            bwd_done_latch <= 0;
            fwd_x_latch <= 14'h3FFF;
            bwd_x_latch <= 14'h3FFF;
            fwd_k_latch <= 0;
            bwd_k_latch <= 0;
        end else begin
            if (fwd_k_proc_valid) begin // clear on new iteration
                fwd_done_latch <= 0;
                bwd_done_latch <= 0;
            end else begin
                if (fwd_layer2_wf_out_valid) begin
                    fwd_done_latch <= 1;
                    fwd_x_latch <= fwd_layer2_wf_out_x;
                    fwd_k_latch <= fwd_layer2_wf_out_k;
                end
                
                if (bwd_layer2_wf_out_valid) begin
                    bwd_done_latch <= 1;
                    bwd_x_latch <= bwd_layer2_wf_out_x;
                    bwd_k_latch <= bwd_layer2_wf_out_k;
                end
            end
        end
    end

    wire global_dpu_done = fwd_done_latch & bwd_done_latch;
    
    // We instantiate essentially two copies of WFA Master Ctrl just to drive score sweeps,
    // but the *engine controller* should be a unified state machine. 
    wire engine_fwd_complete, engine_bwd_complete;
    
    wfa_master_ctrl #(
        .SCORE_WIDTH(SCORE_WIDTH), .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH)
    ) ENGINE_CTRL (
        .clk(clk), .rst_n(rst_n),
        .start(engine_start), .done(engine_done), .final_score(),
        .current_s(current_s), .current_k_proc(fwd_current_k_proc), .k_proc_valid(fwd_k_proc_valid), 
        .next_score_step(next_score_step),
        .k_min(k_min_active), .k_max(k_max_active),
        .alignment_complete_flag(collision_found | engine_fwd_complete), 
        .intersection_found(collision_found),
        .dpu_done(global_dpu_done) // Sync both engines with latches
    );
    
    assign bwd_k_proc_valid = fwd_k_proc_valid;
    assign bwd_current_k_proc = fwd_current_k_proc;

    // ---------------------------------------------------------
    // LAYER 1: Streaming Memories (Dual Instantiation)
    // ---------------------------------------------------------
    wfa_layer1_streaming #(
        .MAX_SEQ_LEN(MAX_SEQ_LEN), .ADDR_WIDTH(ADDR_WIDTH), .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH)
    ) L1_FWD (
        .clk(clk), .rst_n(rst_n),
        .req_valid(fwd_layer2_req_valid), .req_k(fwd_layer2_req_k), .req_x(fwd_layer2_req_x), .req_ready(fwd_layer1_req_ready),
        .q_base(engine_q_start), .r_base(engine_r_start), .dir_bwd(1'b0),
        .preload_en(preload_en), .preload_addr(preload_addr), .preload_q_char(preload_q_char), .preload_r_char(preload_r_char),
        .resp_valid(fwd_layer1_resp_valid), .resp_k(fwd_layer1_resp_k), .resp_q_char(fwd_layer1_resp_q_char), .resp_r_char(fwd_layer1_resp_r_char)
    );

    wfa_layer1_streaming #(
        .MAX_SEQ_LEN(MAX_SEQ_LEN), .ADDR_WIDTH(ADDR_WIDTH), .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH)
    ) L1_BWD (
        .clk(clk), .rst_n(rst_n),
        .req_valid(bwd_layer2_req_valid), .req_k(bwd_layer2_req_k), .req_x(bwd_layer2_req_x), .req_ready(bwd_layer1_req_ready),
        .q_base(engine_q_end - 1), .r_base(engine_r_end - 1), .dir_bwd(1'b1),
        .preload_en(preload_en), .preload_addr(preload_addr), .preload_q_char(preload_q_char), .preload_r_char(preload_r_char),
        .resp_valid(bwd_layer1_resp_valid), .resp_k(bwd_layer1_resp_k), .resp_q_char(bwd_layer1_resp_q_char), .resp_r_char(bwd_layer1_resp_r_char)
    );

    // ---------------------------------------------------------
    // LAYER 2: Compute DPUs
    // ---------------------------------------------------------
    wfa_layer2_compute #(
        .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH), .MAX_Q_LEN(MAX_SEQ_LEN), .MAX_R_LEN(MAX_SEQ_LEN), .NULL_OFFSET(14'h3FFF)
    ) L2_FWD (
        .clk(clk), .rst_n(rst_n),
        .stream_valid(fwd_layer1_resp_valid), .stream_k(fwd_layer1_resp_k), .stream_q(fwd_layer1_resp_q_char), .stream_r(fwd_layer1_resp_r_char),
        .wf_in_del(fwd_wf_out_del), .wf_in_ins(fwd_wf_out_ins), .wf_in_mis(fwd_wf_out_mis),
        .k_proc_valid(fwd_k_proc_valid), .current_k_proc(fwd_current_k_proc), .current_s(current_s),
        .req_valid(fwd_layer2_req_valid), .req_k(fwd_layer2_req_k), .req_x(fwd_layer2_req_x), .req_ready(fwd_layer1_req_ready),
        .wf_out_valid(fwd_layer2_wf_out_valid), .wf_out_k(fwd_layer2_wf_out_k), .wf_out_x(fwd_layer2_wf_out_x),
        .alignment_complete_flag(engine_fwd_complete), .q_len_in(engine_q_end - engine_q_start), .r_len_in(engine_r_end - engine_r_start)
    );

    wfa_layer2_compute #(
        .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH), .MAX_Q_LEN(MAX_SEQ_LEN), .MAX_R_LEN(MAX_SEQ_LEN), .NULL_OFFSET(14'h3FFF)
    ) L2_BWD (
        .clk(clk), .rst_n(rst_n),
        .stream_valid(bwd_layer1_resp_valid), .stream_k(bwd_layer1_resp_k), .stream_q(bwd_layer1_resp_q_char), .stream_r(bwd_layer1_resp_r_char),
        .wf_in_del(bwd_wf_out_del), .wf_in_ins(bwd_wf_out_ins), .wf_in_mis(bwd_wf_out_mis),
        .k_proc_valid(bwd_k_proc_valid), .current_k_proc(bwd_current_k_proc), .current_s(current_s),
        .req_valid(bwd_layer2_req_valid), .req_k(bwd_layer2_req_k), .req_x(bwd_layer2_req_x), .req_ready(bwd_layer1_req_ready),
        .wf_out_valid(bwd_layer2_wf_out_valid), .wf_out_k(bwd_layer2_wf_out_k), .wf_out_x(bwd_layer2_wf_out_x),
        .alignment_complete_flag(engine_bwd_complete), .q_len_in(engine_q_end - engine_q_start), .r_len_in(engine_r_end - engine_r_start)
    );

    // ---------------------------------------------------------
    // LAYER 3: Wavefront Storage
    // ---------------------------------------------------------
    wire [OFFSET_WIDTH-1:0] fwd_current_x;
    wire signed [K_WIDTH-1:0] req_cross_fwd_k;
    wire [OFFSET_WIDTH-1:0] cross_fwd_curr_x;
    
    wfa_layer3_storage #(
        .K_MIN(-1024), .K_MAX(1024), .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH), .NULL_OFFSET(14'h3FFF)
    ) L3_FWD (
        .clk(clk), .rst_n(rst_n),
        .wf_in_valid(fwd_layer2_wf_out_valid), .wf_in_k(fwd_layer2_wf_out_k), .wf_in_x(fwd_layer2_wf_out_x),
        .next_score_step(next_score_step), .k_min_active(k_min_active), .k_max_active(k_max_active),
        .req_wf_read(fwd_k_proc_valid), .req_k(fwd_current_k_proc),
        .wf_out_del(fwd_wf_out_del), .wf_out_ins(fwd_wf_out_ins), .wf_out_mis(fwd_wf_out_mis),
        .current_fwd_x(fwd_current_x),
        .cross_k(req_cross_fwd_k), .cross_wf_curr(cross_fwd_curr_x)
    );

    wire [OFFSET_WIDTH-1:0] bwd_current_x;
    wire signed [K_WIDTH-1:0] req_cross_bwd_k;
    wire [OFFSET_WIDTH-1:0] cross_bwd_curr_x;
    
    wfa_layer3_storage #(
        .K_MIN(-1024), .K_MAX(1024), .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH), .NULL_OFFSET(14'h3FFF)
    ) L3_BWD (
        .clk(clk), .rst_n(rst_n),
        .wf_in_valid(bwd_layer2_wf_out_valid), .wf_in_k(bwd_layer2_wf_out_k), .wf_in_x(bwd_layer2_wf_out_x),
        .next_score_step(next_score_step), .k_min_active(k_min_active), .k_max_active(k_max_active),
        .req_wf_read(bwd_k_proc_valid), .req_k(bwd_current_k_proc),
        .wf_out_del(bwd_wf_out_del), .wf_out_ins(bwd_wf_out_ins), .wf_out_mis(bwd_wf_out_mis),
        .current_fwd_x(bwd_current_x),
        .cross_k(req_cross_bwd_k), .cross_wf_curr(cross_bwd_curr_x)
    );

    // ---------------------------------------------------------
    // LAYER 4: Intersection Detector (replaces fake collision)
    // ---------------------------------------------------------
    biwfa_intersect #(
        .OFFSET_WIDTH(OFFSET_WIDTH), .K_WIDTH(K_WIDTH), .SCORE_WIDTH(SCORE_WIDTH), .NULL_OFFSET(14'h3FFF)
    ) INTERSECT (
        .clk(clk), .rst_n(rst_n),
        .current_s(current_s),
        .current_k_fwd(fwd_current_k_proc),
        .sub_q_len(engine_q_end - engine_q_start),
        .sub_r_len(engine_r_end - engine_r_start),
        .wf_fwd_next_x(fwd_x_latch),
        .bwd_cross_curr_x(cross_bwd_curr_x),
        .wf_bwd_next_x(bwd_x_latch),
        .fwd_cross_curr_x(cross_fwd_curr_x),
        .req_cross_bwd_k(req_cross_bwd_k),
        .req_cross_fwd_k(req_cross_fwd_k),
        .check_valid(global_dpu_done), // Evaluate robustly only when BOTH engines have finished their match loop
        .start_new_iteration(engine_start), // clear state per engine run
        .intersection_found(collision_found),
        .intersect_s(collision_s),
        .intersect_k_fwd(collision_k),
        .intersect_x_fwd(collision_x)
    );

    // ---------------------------------------------------------
    // MASTER CONTROLLER (Divides and Conquers)
    // ---------------------------------------------------------
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
        .engine_done(engine_done | collision_found), // Short-circuit engine on collision
        .collision_found(collision_found), .collision_s(collision_s), .collision_k(collision_k), .collision_x(collision_x),
        .base_solve_start(base_solve_start), .base_solve_done(base_solve_done)
    );

    // ---------------------------------------------------------
    // BASE SOLVER & CIGAR
    // ---------------------------------------------------------
    // Base solver simply needs direct memory lookup. WFA Layer1 does not expose a 
    // direct memory bus to other modules out of the box. 
    // To solve this concisely for the project, we use L1_FWD's preloaded internal array 
    // to feed the base solver via simple wire taps, or we instantiate a third parallel 
    // block RAM purely for the base solver (typical on FPGA).
    // For Verilog compilation, we'll let Base Solver read the FWD BRAM port directly.
    wire base_fetch_req;
    wire [OFFSET_WIDTH-1:0] base_fetch_q_addr, base_fetch_r_addr;
    wire base_fetch_valid;
    wire [7:0] base_fetch_q_char, base_fetch_r_char;

    // Simple 1-cycle latency mock to read from L1_FWD's inferred array
    reg [7:0] q_mem_base_read, r_mem_base_read;
    reg base_read_valid;
    always @(posedge clk) begin
        if (base_fetch_req) begin
            q_mem_base_read <= L1_FWD.q_mem[base_fetch_q_addr];
            r_mem_base_read <= L1_FWD.r_mem[base_fetch_r_addr];
            base_read_valid <= 1;
        end else begin
            base_read_valid <= 0;
        end
    end
    assign base_fetch_valid = base_read_valid;
    assign base_fetch_q_char = q_mem_base_read;
    assign base_fetch_r_char = r_mem_base_read;

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
