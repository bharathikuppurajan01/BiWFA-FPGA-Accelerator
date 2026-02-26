`timescale 1ns / 1ps

module wfa_top_5layer_algo #(
    parameter SCORE_WIDTH = 10,
    parameter MAX_SEQ_LEN = 1000,
    parameter ADDR_WIDTH = 14,
    parameter K_WIDTH = 10,
    parameter OFFSET_WIDTH = 14,
    parameter K_MIN = -512,
    parameter K_MAX = 512,
    parameter NULL_OFFSET = 14'h3FFF
)(
    input  wire clk,
    input  wire rst_n,

    // System Control
    input  wire start_alignment,
    
    // Preload Interface
    input  wire preload_en,
    input  wire [ADDR_WIDTH-1:0] preload_addr,
    input  wire [7:0] preload_q_char,
    input  wire [7:0] preload_r_char,

    // Outputs
    output wire system_done,
    output wire [SCORE_WIDTH-1:0] final_edit_distance,
    output wire align_valid,
    output wire [1:0] op_code,
    output wire [OFFSET_WIDTH-1:0] op_length,
    
    // Config
    input  wire [OFFSET_WIDTH-1:0] seq_len
);

    // Interconnects
    wire [SCORE_WIDTH-1:0] current_s;
    wire signed [K_WIDTH-1:0] current_k_proc;
    wire k_proc_valid;
    wire next_score_step;
    wire signed [K_WIDTH-1:0] k_min_active;
    wire signed [K_WIDTH-1:0] k_max_active;
    wire alignment_complete_flag;
    wire intersection_found;
    
    wire layer2_req_valid;
    wire signed [K_WIDTH-1:0] layer2_req_k;
    wire [OFFSET_WIDTH-1:0] layer2_req_x;
    wire layer1_req_ready;
    wire layer1_resp_valid;
    wire signed [K_WIDTH-1:0] layer1_resp_k;
    wire [7:0] layer1_resp_q_char;
    wire [7:0] layer1_resp_r_char;
    
    wire [OFFSET_WIDTH-1:0] wf_out_del, wf_out_ins, wf_out_mis;
    wire layer2_wf_out_valid;
    wire signed [K_WIDTH-1:0] layer2_wf_out_k;
    wire [OFFSET_WIDTH-1:0] layer2_wf_out_x;
    wire [OFFSET_WIDTH-1:0] current_fwd_x;

    wire trace_segment_valid;
    wire signed [K_WIDTH-1:0] trace_k;
    wire [OFFSET_WIDTH-1:0] trace_x_start;
    wire [OFFSET_WIDTH-1:0] trace_x_end;

    // L1 Streaming
    wfa_layer1_streaming #(
        .MAX_SEQ_LEN(MAX_SEQ_LEN), .ADDR_WIDTH(ADDR_WIDTH),
        .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH)
    ) L1_STREAM (
        .clk(clk), .rst_n(rst_n),
        .req_valid(layer2_req_valid), .req_k(layer2_req_k), .req_x(layer2_req_x), .req_ready(layer1_req_ready),
        .preload_en(preload_en), .preload_addr(preload_addr), .preload_q_char(preload_q_char), .preload_r_char(preload_r_char),
        .resp_valid(layer1_resp_valid), .resp_k(layer1_resp_k), .resp_q_char(layer1_resp_q_char), .resp_r_char(layer1_resp_r_char)
    );

    // Master FSM
    wfa_master_ctrl #(
        .SCORE_WIDTH(SCORE_WIDTH), .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH)
    ) MASTER (
        .clk(clk), .rst_n(rst_n), .start(start_alignment), .done(system_done), .final_score(final_edit_distance),
        .current_s(current_s), .current_k_proc(current_k_proc), .k_proc_valid(k_proc_valid), .next_score_step(next_score_step),
        .k_min(k_min_active), .k_max(k_max_active),
        .alignment_complete_flag(alignment_complete_flag), .intersection_found(intersection_found),
        .dpu_done(layer2_wf_out_valid)
    );

    // L2 Compute
    wfa_layer2_compute #(
        .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH), .MAX_Q_LEN(MAX_SEQ_LEN), .MAX_R_LEN(MAX_SEQ_LEN), .NULL_OFFSET(NULL_OFFSET)
    ) L2_DPU (
        .clk(clk), .rst_n(rst_n),
        .stream_valid(layer1_resp_valid), .stream_k(layer1_resp_k), .stream_q(layer1_resp_q_char), .stream_r(layer1_resp_r_char),
        .wf_in_del(wf_out_del), .wf_in_ins(wf_out_ins), .wf_in_mis(wf_out_mis),
        .k_proc_valid(k_proc_valid), .current_k_proc(current_k_proc), .current_s(current_s),
        .req_valid(layer2_req_valid), .req_k(layer2_req_k), .req_x(layer2_req_x), .req_ready(layer1_req_ready),
        .wf_out_valid(layer2_wf_out_valid), .wf_out_k(layer2_wf_out_k), .wf_out_x(layer2_wf_out_x),
        .alignment_complete_flag(alignment_complete_flag),
        .seq_len(seq_len)
    );

    // L3 Storage
    wfa_layer3_storage #(
        .K_MIN(K_MIN), .K_MAX(K_MAX), .K_WIDTH(K_WIDTH), .OFFSET_WIDTH(OFFSET_WIDTH), .NULL_OFFSET(NULL_OFFSET)
    ) L3_STORAGE (
        .clk(clk), .rst_n(rst_n),
        .wf_in_valid(layer2_wf_out_valid), .wf_in_k(layer2_wf_out_k), .wf_in_x(layer2_wf_out_x),
        .next_score_step(next_score_step), .k_min_active(k_min_active), .k_max_active(k_max_active),
        .req_wf_read(k_proc_valid), .req_k(current_k_proc),
        .wf_out_del(wf_out_del), .wf_out_ins(wf_out_ins), .wf_out_mis(wf_out_mis),
        .current_fwd_x(current_fwd_x)
    );

    // L4 Traceback Intersect
    wfa_layer4_traceback #(
        .OFFSET_WIDTH(OFFSET_WIDTH), .K_WIDTH(K_WIDTH), .SCORE_WIDTH(SCORE_WIDTH), .MAX_Q_LEN(MAX_SEQ_LEN), .MAX_R_LEN(MAX_SEQ_LEN), .NULL_OFFSET(NULL_OFFSET)
    ) L4_TRACE (
        .clk(clk), .rst_n(rst_n),
        .next_score_step(next_score_step), .current_s(current_s),
        .k_min_active(k_min_active), .k_max_active(k_max_active),
        .check_k(current_k_proc), .wf_fwd_x(current_fwd_x), .wf_bwd_x(NULL_OFFSET), // Bwd bound missing in struct
        .intersection_found(intersection_found),
        .trace_segment_valid(trace_segment_valid), .trace_k(trace_k), .trace_x_start(trace_x_start), .trace_x_end(trace_x_end),
        .seq_len(seq_len)
    );

    // L5 Reconstruct
    wfa_layer5_reconstruct #(
        .OFFSET_WIDTH(OFFSET_WIDTH), .K_WIDTH(K_WIDTH), .SCORE_WIDTH(SCORE_WIDTH)
    ) L5_RECONSTRUCT (
        .clk(clk), .rst_n(rst_n),
        .trace_segment_valid(trace_segment_valid), .trace_k(trace_k), .trace_x_start(trace_x_start), .trace_x_end(trace_x_end),
        .align_valid(align_valid), .op_code(op_code), .op_length(op_length),
        .align_done(), // Open
        .seq_len(seq_len)
    );

endmodule
