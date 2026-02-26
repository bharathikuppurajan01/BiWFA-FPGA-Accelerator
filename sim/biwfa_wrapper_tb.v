`timescale 1ns / 1ps

module biwfa_wrapper_tb;

    reg clk;
    reg rst_n;
    reg start_alignment;
    
    // Config port
    reg [13:0] tb_seq_q_len;
    reg [13:0] tb_seq_r_len;

    wire system_done;
    wire align_valid;
    wire [1:0] op_code;
    wire [13:0] op_length;

    // We will instantiate the wrapper but we also need to mock the Layer 1 sequence memory 
    // since the BASE_SOLVER requests fetches from it.
    wire base_fetch_req;
    wire [13:0] base_fetch_q_addr;
    wire [13:0] base_fetch_r_addr;
    reg base_fetch_valid;
    reg [7:0] base_fetch_q_char;
    reg [7:0] base_fetch_r_char;

    // Test Variables
    reg [7:0] seq_Q [0:99];
    reg [7:0] seq_R [0:99];
    integer i;

    biwfa_top_wrapper #(
        .SCORE_WIDTH(10), .MAX_SEQ_LEN(100), .ADDR_WIDTH(14),
        .K_WIDTH(10), .OFFSET_WIDTH(14), .THRESHOLD_LEN(4)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start_alignment(start_alignment),
        .seq_q_len(tb_seq_q_len), .seq_r_len(tb_seq_r_len),
        .system_done(system_done),
        .align_valid(align_valid), .op_code(op_code), .op_length(op_length)
    );

    // Override the wrapper's internal disconnected wires for the simulation
    // Since Verilog allows hierarchical referencing, we can drive the base struct's fetch valid from here.
    // In a real system, Layer 1 streams would be connected.
    always @(posedge clk) begin
        if (dut.base_fetch_req) begin
            base_fetch_valid <= 1;
            base_fetch_q_char <= seq_Q[dut.base_fetch_q_addr];
            base_fetch_r_char <= seq_R[dut.base_fetch_r_addr];
        end else begin
            base_fetch_valid <= 0;
        end
    end
    
    // Push the mocked fetch values down into the wrapper instance
    assign dut.base_fetch_valid = base_fetch_valid;
    assign dut.base_fetch_q_char = base_fetch_q_char;
    assign dut.base_fetch_r_char = base_fetch_r_char;

    // Furthermore, mapping the stubbed "Engine" logic in the wrapper.
    // For this simulation of ONLY the divide and conquer framework, we can intercept `engine_start` internally
    // and instantly provide a fake "collision" to force the stack to divide.
    // Let's force an intersection exactly halfway through the block.
    reg fake_engine_done;
    reg fake_collision;
    reg [13:0] fake_x;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fake_engine_done <= 0;
            fake_collision <= 0;
            fake_x <= 0;
        end else begin
            fake_engine_done <= 0;
            if (dut.engine_start) begin
                // 1-cycle fake engine delay
                fake_engine_done <= 1;
                fake_collision <= 1;
                // Cut the sequence length in half relative to local
                fake_x <= (dut.engine_q_end - dut.engine_q_start) / 2;
            end
        end
    end
    
    // Override internal wire assignments using force
    initial begin
        force dut.engine_done = fake_engine_done;
        force dut.collision_found = fake_collision;
        force dut.collision_s = 10'd1; // Arbitrary score > 0 to force subdivision
        force dut.collision_k = 10'd0; // Assume diagonal 0 collision
        // collision_x is relative to q_start in the master controller logic
        force dut.collision_x = fake_x; 
    end

    always #5 clk = ~clk;

    // CIGAR Buffer
    reg [8*64-1:0] cigar_buffer;

    task run_test;
        input integer length;
        input [800:1] test_name;
        begin
            tb_seq_q_len = length;
            tb_seq_r_len = length; // Equal length tests for this basic stubbed run
            
            $display("==================================================");
            $display("Starting Test: %0s", test_name);
            $display("Running BiWFA Divide-and-Conquer FSM and Stack Recursion...");
            
            cigar_buffer = "";
            
            rst_n = 0;
            start_alignment = 0;
            #20 rst_n = 1;
            
            #20 start_alignment = 1;
            #10 start_alignment = 0;
            
            wait(system_done);
            
            $display("Divide-and-Conquer Traceback Completed!");
            #10;
            $display("Reconstructed CIGAR String Output: %0s", cigar_buffer);
            #50;
        end
    endtask

    always @(posedge clk) begin
        if (align_valid) begin
            case (op_code)
                2'd0: cigar_buffer = {cigar_buffer[(8*64)-17:0], 8'd48 + op_length[7:0], 8'h4D}; // "M"
                2'd1: cigar_buffer = {cigar_buffer[(8*64)-17:0], 8'd48 + op_length[7:0], 8'h49}; // "I"
                2'd2: cigar_buffer = {cigar_buffer[(8*64)-17:0], 8'd48 + op_length[7:0], 8'h44}; // "D"
                2'd3: cigar_buffer = {cigar_buffer[(8*64)-17:0], 8'd48 + op_length[7:0], 8'h58}; // "X"
            endcase
            
            $display("  -> Base Solver Emitted Segment: %0d%0s", op_length, 
                (op_code==0)?"M": (op_code==1)?"I": (op_code==2)?"D": "X"
            );
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        start_alignment = 0;
        #10;
        
        $display("==================================================");
        $display("Testing Fully Recursive BiWFA Structure");
        
        // Load some fake sequences to test the leaf node base solver character fetching
        for(i=0; i<100; i=i+1) begin
            seq_Q[i] = "A";
            seq_R[i] = "A";
        end
        seq_R[5] = "C"; // Add a mismatch
        
        // This will trigger the stack to push [0, 10], pop it, realize it > THRESHOLD (4)
        // Fire engine_start. Our fake engine cuts it at x=5.
        // Stack pushes right [5, 10], left [0, 5].
        // Pops [0, 5], splits to [2, 5], [0, 2]... etc.
        // Eventually leaf nodes hit Base Solver and stream out CIGARs!
        run_test(10, "Base Recursive Split Test");
        
        $finish;
    end

endmodule
