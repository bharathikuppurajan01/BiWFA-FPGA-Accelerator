`timescale 1ns / 1ps

module wfa_tb;

    reg clk;
    reg rst_n;
    reg start;
    reg [7:0] seqA_char;
    reg [7:0] seqB_char;
    wire done;
    wire [15:0] max_offset;

    // Instantiate Top Level WFA core
    wfa_top #(
        .OFFSET_WIDTH(16),
        .SCORE_WIDTH(10),
        .DIAGONAL_WIDTH(10)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .seqA_char(seqA_char),
        .seqB_char(seqB_char),
        .done(done),
        .max_offset(max_offset)
    );

    // Clock generation
    always #5 clk = ~clk;

    initial begin
        // Initialize Inputs
        clk = 0;
        rst_n = 0;
        start = 0;
        seqA_char = 8'h41; // ASCII 'A'
        seqB_char = 8'h41; // ASCII 'A' (Match condition)

        // Wait for global reset
        #20;
        rst_n = 1;
        
        // Assert start generic signal
        #10;
        start = 1;
        #10;
        start = 0;

        // Change characters to test mismatch handling midway
        #200;
        seqB_char = 8'h43; // ASCII 'C' (Mismatch condition)

        // Wait until Controller signals DONE
        wait(done);

        $display("==================================================");
        $display("WFA Simulation Finished! Max offset computed.");
        $display("==================================================");
        
        $finish;
    end

endmodule
