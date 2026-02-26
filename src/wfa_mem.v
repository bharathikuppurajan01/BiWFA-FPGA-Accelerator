`timescale 1ns / 1ps

module wfa_mem #(
    parameter ADDR_WIDTH = 10,
    parameter DATA_WIDTH = 16
)(
    input  wire                  clk,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [DATA_WIDTH-1:0] wdata,
    input  wire [ADDR_WIDTH-1:0] raddrA,
    output reg  [DATA_WIDTH-1:0] rdataA,
    input  wire [ADDR_WIDTH-1:0] raddrB,
    output reg  [DATA_WIDTH-1:0] rdataB
);

    // Block RAM inference
    reg [DATA_WIDTH-1:0] ram [0:(1<<ADDR_WIDTH)-1];

    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
        end
        rdataA <= ram[raddrA];
        rdataB <= ram[raddrB];
    end

endmodule
