`timescale 1ns / 1ps

module wfa_tb_5layer;

    reg clk;
    reg rst_n;
    reg start_alignment;
    
    reg preload_en;
    reg [13:0] preload_addr;
    reg [7:0] preload_q_char;
    reg [7:0] preload_r_char;

    wire align_valid;
    wire [7:0] align_q_char;
    wire [7:0] align_r_char;
    wire align_done;

    // Instantiate 5-Layer Top Level WFA
    wfa_top_5layer #(
        .MAX_SEQ_LEN(1024),
        .ADDR_WIDTH(14),
        .K_WIDTH(10),
        .OFFSET_WIDTH(14),
        .SCORE_WIDTH(10),
        .K_MIN(-512),
        .K_MAX(512)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_alignment(start_alignment),
        .preload_en(preload_en),
        .preload_addr(preload_addr),
        .preload_q_char(preload_q_char),
        .preload_r_char(preload_r_char),
        .align_valid(align_valid),
        .align_q_char(align_q_char),
        .align_r_char(align_r_char),
        .align_done(align_done)
    );

    // Clock generation
    always #5 clk = ~clk;

    initial begin
        // Initialize Inputs
        clk = 0;
        rst_n = 0;
        start_alignment = 0;
        preload_en = 0;
        preload_addr = 0;
        preload_q_char = 0;
        preload_r_char = 0;

        // Reset
        #20;
        rst_n = 1;

        // Sequence preloading phase
        $display("Preloading sequences into Streaming Layer...");
        preload_en = 1;
        
        // Let's create a match: "ACGT" vs "ACGT"
        preload_addr = 0; preload_q_char = "A"; preload_r_char = "A"; #10;
        preload_addr = 1; preload_q_char = "C"; preload_r_char = "C"; #10;
        preload_addr = 2; preload_q_char = "G"; preload_r_char = "G"; #10;
        preload_addr = 3; preload_q_char = "T"; preload_r_char = "T"; #10;
        
        preload_en = 0;

        // Start Alignment phase
        $display("Starting Pipeline Processing across all layers...");
        #20;
        start_alignment = 1;
        #10;
        start_alignment = 0;

        // Wait to monitor behavior
        // The DPU will now issue a fetch for diagonal 0 offset 0
        // Address FIFO -> BRAM delay -> DPU Match extension -> offset 1
        // And repeats.
        
        #500;
        
        $display("==================================================");
        $display("5-Layer WFA Simulation Finished! Check waveform for pipelined requests.");
        $display("==================================================");
        
        $finish;
    end

endmodule
