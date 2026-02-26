`timescale 1ns / 1ps

module wfa_pe #(
    parameter OFFSET_WIDTH = 16
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    en,
    input  wire [OFFSET_WIDTH-1:0] in_M, // Offset for Match/Mismatch path
    input  wire [OFFSET_WIDTH-1:0] in_I, // Offset for Insertion path
    input  wire [OFFSET_WIDTH-1:0] in_D, // Offset for Deletion path
    input  wire [7:0]              seqA_char,
    input  wire [7:0]              seqB_char,
    output reg  [OFFSET_WIDTH-1:0] out_O,
    output wire                    match
);

    // WFA base recurrence offset maximization
    wire [OFFSET_WIDTH-1:0] max_MID;
    assign max_MID = (in_M > in_I) ? ((in_M > in_D) ? in_M : in_D) : ((in_I > in_D) ? in_I : in_D);

    // Exact match detection for X-Drop/Extension
    assign match = (seqA_char == seqB_char);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_O <= {OFFSET_WIDTH{1'b0}};
        end else if (en) begin
            // Extend offset if characters match, else just take max of transitions
            if (match) begin
                out_O <= max_MID + 1; 
            end else begin
                out_O <= max_MID;
            end
        end
    end

endmodule
