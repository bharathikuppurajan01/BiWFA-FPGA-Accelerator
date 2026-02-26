`timescale 1ns / 1ps

module biwfa_cigar_coalescer #(
    parameter OFFSET_WIDTH = 14
)(
    input  wire clk,
    input  wire rst_n,
    
    // Interface from Base Solver
    input  wire valid_in,
    input  wire [1:0] op_in,
    input  wire [OFFSET_WIDTH-1:0] len_in,
    input  wire end_of_alignment,
    
    // Compressed Output Interface
    output reg  valid_out,
    output reg  [1:0] op_out,
    output reg  [OFFSET_WIDTH-1:0] len_out
);

    reg [1:0] current_op;
    reg [OFFSET_WIDTH-1:0] current_len;
    reg active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 0;
            current_op <= 0;
            current_len <= 0;
            active <= 0;
            op_out <= 0;
            len_out <= 0;
        end else begin
            valid_out <= 0;
            
            if (valid_in) begin
                if (!active) begin
                    // First operation
                    active <= 1;
                    current_op <= op_in;
                    current_len <= len_in;
                end else if (op_in == current_op) begin
                    // Coalesce identical ops
                    current_len <= current_len + len_in;
                end else begin
                    // Opcode changed, emit previous buffer
                    valid_out <= 1;
                    op_out <= current_op;
                    len_out <= current_len;
                    
                    // Start new buffer
                    current_op <= op_in;
                    current_len <= len_in;
                end
            end
            
            // Flush buffer at end of sequence alignment
            if (end_of_alignment && active) begin
                valid_out <= 1;
                op_out <= current_op;
                len_out <= current_len;
                active <= 0;
            end
        end
    end

endmodule
