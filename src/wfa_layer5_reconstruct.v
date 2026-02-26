`timescale 1ns / 1ps

module wfa_layer5_reconstruct #(
    parameter OFFSET_WIDTH = 14,
    parameter K_WIDTH = 10,
    parameter SCORE_WIDTH = 10
)(
    input  wire clk,
    input  wire rst_n,

    // Interface from Layer 4 Intersection Detector
    input  wire trace_segment_valid,
    input  wire signed [K_WIDTH-1:0] trace_k,
    input  wire [OFFSET_WIDTH-1:0] trace_x_start,
    input  wire [OFFSET_WIDTH-1:0] trace_x_end,
    
    // Outputs representing CIGAR or trace outputs
    output reg align_valid,
    output reg [1:0] op_code, // 0: Match, 1: Ins, 2: Del, 3: Mismatch
    output reg [OFFSET_WIDTH-1:0] op_length,
    output reg align_done,
    
    // Dynamic Sequence Length from top
    input  wire  [OFFSET_WIDTH-1:0] seq_len
);

    // Reconstructs sequence gaps and matches natively from diagonal drops
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            align_valid <= 0;
            op_code <= 0;
            op_length <= 0;
            align_done <= 0;
        end else begin
            align_valid <= 0;
            align_done <= 0;
            
            if (trace_segment_valid) begin
                align_valid <= 1;
                op_code <= 2'b00; // Match run
                op_length <= trace_x_end - trace_x_start;
                
                // If it hits end of sequences implicitly, mark done.
                if (trace_x_end >= seq_len) begin
                    align_done <= 1;
                end
            end
        end
    end

endmodule
