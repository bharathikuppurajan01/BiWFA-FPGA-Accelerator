`timescale 1ns / 1ps

module wfa_ctrl #(
    parameter SCORE_WIDTH = 10,
    parameter DIAGONAL_WIDTH = 10
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      start,
    output reg                       done,
    output reg                       pe_en,
    output reg  [SCORE_WIDTH-1:0]    curr_score,
    output reg  [DIAGONAL_WIDTH-1:0] curr_diag,
    output reg                       mem_we
);

    localparam IDLE = 2'b00;
    localparam CALC = 2'b01;
    localparam DONE = 2'b10;

    reg [1:0] state, next_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            IDLE: if (start) next_state = CALC;
            CALC: if (curr_score == 10'd100) next_state = DONE; // Termination condition for simulation
            DONE: next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_score <= 0;
            curr_diag <= 0;
            done <= 0;
            pe_en <= 0;
            mem_we <= 0;
        end else begin
            case (state)
                IDLE: begin
                    curr_score <= 0;
                    curr_diag <= 0;
                    done <= 0;
                    pe_en <= 0;
                    mem_we <= 0;
                end
                CALC: begin
                    pe_en <= 1;
                    mem_we <= 1;
                    if (curr_diag == 10'd50) begin
                        curr_diag <= 0;
                        curr_score <= curr_score + 1;
                    end else begin
                        curr_diag <= curr_diag + 1;
                    end
                end
                DONE: begin
                    pe_en <= 0;
                    mem_we <= 0;
                    done <= 1;
                end
            endcase
        end
    end

endmodule
