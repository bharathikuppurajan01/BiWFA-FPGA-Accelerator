`timescale 1ns / 1ps

module wfa_top_5layer #(
    parameter MAX_SEQ_LEN = 16384,
    parameter ADDR_WIDTH = 14,
    parameter K_WIDTH = 10,
    parameter OFFSET_WIDTH = 14,
    parameter SCORE_WIDTH = 10,
    parameter K_MIN = -512,
    parameter K_MAX = 512
)(
    input  wire clk,
    input  wire rst_n,

    // Config/Start interface
    input  wire start_alignment,
    
    // Memory Pre-load interface directly forwarded to Layer 1
    input  wire preload_en,
    input  wire [ADDR_WIDTH-1:0] preload_addr,
    input  wire [7:0] preload_q_char,
    input  wire [7:0] preload_r_char,

    // Final outputs from Layer 5
    output wire align_valid,
    output wire [7:0] align_q_char,
    output wire [7:0] align_r_char,
    output wire align_done
);

    // --- Signals Interconnecting Layers ---
    
    // Layer 1 <-> Layer 2
    wire layer2_req_valid;
    wire signed [K_WIDTH-1:0] layer2_req_k;
    wire [OFFSET_WIDTH-1:0] layer2_req_x;
    wire layer1_req_ready;

    wire layer1_resp_valid;
    wire signed [K_WIDTH-1:0] layer1_resp_k;
    wire [7:0] layer1_resp_q_char;
    wire [7:0] layer1_resp_r_char;

    // Layer 2 <-> Layer 3
    wire layer2_wf_out_valid;
    wire signed [K_WIDTH-1:0] layer2_wf_out_k;
    wire [OFFSET_WIDTH-1:0] layer2_wf_out_x;

    wire req_wf_read;
    wire signed [K_WIDTH-1:0] request_read_k;
    wire [OFFSET_WIDTH-1:0] current_wf_x_read;
    wire next_score_step;

    // Layer 4 <-> Layer 5
    wire trace_segment_valid;
    wire signed [K_WIDTH-1:0] trace_k;
    wire [OFFSET_WIDTH-1:0] trace_x_start;
    wire [OFFSET_WIDTH-1:0] trace_x_end;

    // --- INSTANCES ---

    // LAYER 1: Sequence Streaming Layer
    wfa_layer1_streaming #(
        .MAX_SEQ_LEN(MAX_SEQ_LEN),
        .ADDR_WIDTH(ADDR_WIDTH),
        .K_WIDTH(K_WIDTH),
        .OFFSET_WIDTH(OFFSET_WIDTH)
    ) layer1_streaming (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(layer2_req_valid),
        .req_k(layer2_req_k),
        .req_x(layer2_req_x),
        .req_ready(layer1_req_ready),
        .preload_en(preload_en),
        .preload_addr(preload_addr),
        .preload_q_char(preload_q_char),
        .preload_r_char(preload_r_char),
        .resp_valid(layer1_resp_valid),
        .resp_k(layer1_resp_k),
        .resp_q_char(layer1_resp_q_char),
        .resp_r_char(layer1_resp_r_char)
    );

    // LAYER 2: Wavefront Compute Layer
    wfa_layer2_compute #(
        .K_WIDTH(K_WIDTH),
        .OFFSET_WIDTH(OFFSET_WIDTH)
    ) layer2_compute (
        .clk(clk),
        .rst_n(rst_n),
        .stream_valid(layer1_resp_valid),
        .stream_k(layer1_resp_k),
        .stream_q(layer1_resp_q_char),
        .stream_r(layer1_resp_r_char),
        .wf_in_x(current_wf_x_read),
        .current_k_proc(request_read_k),
        .wf_in_valid(req_wf_read),
        .req_valid(layer2_req_valid),
        .req_k(layer2_req_k),
        .req_x(layer2_req_x),
        .req_ready(layer1_req_ready),
        .wf_out_valid(layer2_wf_out_valid),
        .wf_out_k(layer2_wf_out_k),
        .wf_out_x(layer2_wf_out_x)
    );

    // LAYER 3: Wavefront State Storage
    wfa_layer3_storage #(
        .K_MIN(K_MIN),
        .K_MAX(K_MAX),
        .K_WIDTH(K_WIDTH),
        .OFFSET_WIDTH(OFFSET_WIDTH)
    ) layer3_storage (
        .clk(clk),
        .rst_n(rst_n),
        .wf_in_valid(layer2_wf_out_valid),
        .wf_in_k(layer2_wf_out_k),
        .wf_in_x(layer2_wf_out_x),
        .read_req(req_wf_read),
        .read_k(request_read_k),
        .read_x(current_wf_x_read),
        .next_score_step(next_score_step)
    );

    // LAYER 4: Bi-Directional Trace-Back Layer
    wfa_layer4_traceback #(
        .OFFSET_WIDTH(OFFSET_WIDTH),
        .K_WIDTH(K_WIDTH),
        .SCORE_WIDTH(SCORE_WIDTH)
    ) layer4_traceback (
        .clk(clk),
        .rst_n(rst_n),
        .score_iteration_done(next_score_step),
        .current_s(10'd5), // Driven by a missing master FSM, forced constant for structural top-level
        .fwd_bwd_intersect_valid(1'b0), // Intersection simulation stubs
        .intersect_k(10'd0),
        .intersect_x(14'd0),
        .trace_segment_valid(trace_segment_valid),
        .trace_k(trace_k),
        .trace_x_start(trace_x_start),
        .trace_x_end(trace_x_end)
    );

    // LAYER 5: Alignment Reconstruction Layer
    wfa_layer5_reconstruct #(
        .K_WIDTH(K_WIDTH),
        .OFFSET_WIDTH(OFFSET_WIDTH)
    ) layer5_reconstruct (
        .clk(clk),
        .rst_n(rst_n),
        .trace_segment_valid(trace_segment_valid),
        .trace_k(trace_k),
        .trace_x_start(trace_x_start),
        .trace_x_end(trace_x_end),
        .q_char_in(layer1_resp_q_char), // Stub read back 
        .r_char_in(layer1_resp_r_char),
        .align_valid(align_valid),
        .align_q_char(align_q_char),
        .align_r_char(align_r_char),
        .align_done(align_done)
    );

    // Basic master start triggers
    assign req_wf_read = start_alignment;
    assign request_read_k = 10'd0; // Kick off diagonal 0 calculation

endmodule
