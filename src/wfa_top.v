`timescale 1ns / 1ps

module wfa_top #(
    parameter OFFSET_WIDTH = 16,
    parameter SCORE_WIDTH = 10,
    parameter DIAGONAL_WIDTH = 10
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    input  wire [7:0] seqA_char,
    input  wire [7:0] seqB_char,
    output wire done,
    output wire [OFFSET_WIDTH-1:0] max_offset
);

    wire pe_en;
    wire [SCORE_WIDTH-1:0] curr_score;
    wire [DIAGONAL_WIDTH-1:0] curr_diag;
    wire mem_we;
    wire [OFFSET_WIDTH-1:0] pe_out_O;
    wire pe_match;
    wire [OFFSET_WIDTH-1:0] mem_rdataA;
    wire [OFFSET_WIDTH-1:0] mem_rdataB;

    wfa_ctrl #(
        .SCORE_WIDTH(SCORE_WIDTH),
        .DIAGONAL_WIDTH(DIAGONAL_WIDTH)
    ) ctrl_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .done(done),
        .pe_en(pe_en),
        .curr_score(curr_score),
        .curr_diag(curr_diag),
        .mem_we(mem_we)
    );

    wfa_pe #(
        .OFFSET_WIDTH(OFFSET_WIDTH)
    ) pe_inst (
        .clk(clk),
        .rst_n(rst_n),
        .en(pe_en),
        .in_M(mem_rdataA), // Routed from previous wavefronts
        .in_I(mem_rdataB), // Routed from insertion dependencies
        .in_D(pe_out_O),   // Routed from deletion dependencies
        .seqA_char(seqA_char),
        .seqB_char(seqB_char),
        .out_O(pe_out_O),
        .match(pe_match)
    );

    wfa_mem #(
        .ADDR_WIDTH(DIAGONAL_WIDTH),
        .DATA_WIDTH(OFFSET_WIDTH)
    ) mem_inst (
        .clk(clk),
        .we(mem_we),
        .waddr(curr_diag),
        .wdata(pe_out_O),
        .raddrA(curr_diag), 
        .rdataA(mem_rdataA),
        .raddrB(curr_diag - 1'b1), 
        .rdataB(mem_rdataB)
    );

    assign max_offset = pe_out_O;

endmodule
