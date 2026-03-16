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

    // Verilog-2001: declare temporaries at module scope
    reg next_active;
    reg [1:0] next_op;
    reg [OFFSET_WIDTH-1:0] next_len;
    reg emit_prev;
    reg [1:0] emit_op;
    reg [OFFSET_WIDTH-1:0] emit_len;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 0;
            current_op <= 0;
            current_len <= 0;
            active <= 0;
            op_out <= 0;
            len_out <= 0;

            next_active <= 0;
            next_op <= 0;
            next_len <= 0;
            emit_prev <= 0;
            emit_op <= 0;
            emit_len <= 0;
        end else begin
            valid_out <= 0;

            next_active = active;
            next_op     = current_op;
            next_len    = current_len;
            emit_prev   = 0;
            emit_op     = current_op;
            emit_len    = current_len;

            if (valid_in) begin
                if (!active) begin
                    next_active = 1;
                    next_op     = op_in;
                    next_len    = len_in;
                end else if (op_in == current_op) begin
                    next_len = current_len + len_in;
                end else begin
                    // Opcode changed, emit previous buffer now and start a new one
                    emit_prev = 1;
                    emit_op   = current_op;
                    emit_len  = current_len;
                    next_active = 1;
                    next_op     = op_in;
                    next_len    = len_in;
                end
            end

            // Emit previous buffer if opcode changed
            if (emit_prev) begin
                valid_out <= 1;
                op_out    <= emit_op;
                len_out   <= emit_len;
            end

            // Flush at end of alignment using the post-consume buffered state
            if (end_of_alignment && next_active) begin
                valid_out <= 1;
                op_out    <= next_op;
                len_out   <= next_len;
                next_active = 0;
            end

            // Commit buffered state
            active      <= next_active;
            current_op  <= next_op;
            current_len <= next_len;
        end
    end

endmodule
