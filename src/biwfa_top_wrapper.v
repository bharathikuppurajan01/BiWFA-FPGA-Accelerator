`timescale 1ns / 1ps

module biwfa_top_wrapper #(
    parameter MAX_SEQ_LEN  = 1000,
    parameter ADDR_WIDTH   = 14,
    parameter K_WIDTH      = 10,
    parameter OFFSET_WIDTH = 14
)(
    input  wire clk,
    input  wire rst_n,

    input  wire start_alignment,
    input  wire [OFFSET_WIDTH-1:0] seq_q_len,
    input  wire [OFFSET_WIDTH-1:0] seq_r_len,

    output wire system_done,

    output wire align_valid,
    output wire [1:0] op_code,
    output wire [OFFSET_WIDTH-1:0] op_length,

    input  wire preload_en,
    input  wire [ADDR_WIDTH-1:0] preload_addr,
    input  wire [7:0] preload_q_char,
    input  wire [7:0] preload_r_char
);

    // Sequence memory only (BRAM)
    wfa_layer1_streaming #(
        .MAX_SEQ_LEN(MAX_SEQ_LEN),
        .ADDR_WIDTH(ADDR_WIDTH),
        .K_WIDTH(K_WIDTH),
        .OFFSET_WIDTH(OFFSET_WIDTH)
    ) L1_MEM (
        .clk(clk), .rst_n(rst_n),
        .req_valid(1'b0), .req_k({K_WIDTH{1'b0}}), .req_x({OFFSET_WIDTH{1'b0}}), .req_ready(),
        .q_base({OFFSET_WIDTH{1'b0}}), .r_base({OFFSET_WIDTH{1'b0}}), .dir_bwd(1'b0),
        .preload_en(preload_en), .preload_addr(preload_addr), .preload_q_char(preload_q_char), .preload_r_char(preload_r_char),
        .resp_valid(), .resp_k(), .resp_q_char(), .resp_r_char()
    );

    // Base solver taps memory directly (1-cycle latency)
    wire base_fetch_req;
    wire [OFFSET_WIDTH-1:0] base_fetch_q_addr, base_fetch_r_addr;
    reg  [7:0] q_mem_base_read, r_mem_base_read;
    reg        base_read_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base_read_valid <= 0;
        end else begin
            if (base_fetch_req) begin
                q_mem_base_read <= L1_MEM.q_mem[base_fetch_q_addr];
                r_mem_base_read <= L1_MEM.r_mem[base_fetch_r_addr];
                base_read_valid <= 1;
            end else begin
                base_read_valid <= 0;
            end
        end
    end

    wire base_fetch_valid = base_read_valid;
    wire [7:0] base_fetch_q_char = q_mem_base_read;
    wire [7:0] base_fetch_r_char = r_mem_base_read;

    wire base_solve_done;
    wire base_cigar_valid;
    wire [1:0] base_cigar_op;
    wire [OFFSET_WIDTH-1:0] base_cigar_len;

    biwfa_base_solver #(
        .OFFSET_WIDTH(OFFSET_WIDTH)
    ) BASE_SOLVER (
        .clk(clk), .rst_n(rst_n),
        .start(start_alignment),
        .q_start({OFFSET_WIDTH{1'b0}}), .q_end(seq_q_len),
        .r_start({OFFSET_WIDTH{1'b0}}), .r_end(seq_r_len),
        .done(base_solve_done),
        .fetch_req(base_fetch_req), .fetch_q_addr(base_fetch_q_addr), .fetch_r_addr(base_fetch_r_addr),
        .fetch_valid(base_fetch_valid), .fetch_q_char(base_fetch_q_char), .fetch_r_char(base_fetch_r_char),
        .cigar_valid(base_cigar_valid), .cigar_op(base_cigar_op), .cigar_len(base_cigar_len)
    );

    biwfa_cigar_coalescer #(
        .OFFSET_WIDTH(OFFSET_WIDTH)
    ) CIGAR_ENC (
        .clk(clk), .rst_n(rst_n),
        .valid_in(base_cigar_valid), .op_in(base_cigar_op), .len_in(base_cigar_len),
        .end_of_alignment(base_solve_done),
        .valid_out(align_valid), .op_out(op_code), .len_out(op_length)
    );

    assign system_done = base_solve_done;

endmodule
