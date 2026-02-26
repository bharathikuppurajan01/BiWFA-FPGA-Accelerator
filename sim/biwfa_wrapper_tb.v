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
        .align_valid(align_valid), .op_code(op_code), .op_length(op_length),
        
        // Memory wiring
        .base_fetch_req(base_fetch_req),
        .base_fetch_q_addr(base_fetch_q_addr),
        .base_fetch_r_addr(base_fetch_r_addr),
        .base_fetch_valid(base_fetch_valid),
        .base_fetch_q_char(base_fetch_q_char),
        .base_fetch_r_char(base_fetch_r_char)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base_fetch_valid <= 0;
            base_fetch_q_char <= 0;
            base_fetch_r_char <= 0;
        end else begin
            // 1-cycle latency mock BRAM
            if (base_fetch_req) begin
                base_fetch_valid <= 1;
                base_fetch_q_char <= seq_Q[base_fetch_q_addr];
                base_fetch_r_char <= seq_R[base_fetch_r_addr];
            end else begin
                base_fetch_valid <= 0;
            end
        end
    end

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

    // --- Sequence Reconstruction Trackers ---
    integer q_idx = 0; // Tracks position in original Query sequence
    integer r_idx = 0; // Tracks position in original Reference sequence
    integer a_idx = 0; // Tracks position in the new ALIGNED sequence
    integer k, j;
    
    reg [7:0] aligned_Q [0:199]; // Buffer for final reconstructed Query
    reg [7:0] aligned_R [0:199]; // Buffer for final reconstructed Ref

    task run_test;
        input integer length;
        input [800:1] test_name;
        begin
            tb_seq_q_len = length;
            tb_seq_r_len = length; // Equal length tests for this basic stubbed run
            
            $display("==================================================");
            $display("                BiWFA ALIGNMENT TEST              ");
            $display("==================================================");
            
            $display("\n[1] INPUT SEQUENCES:");
            $write("    Query (Q) : ");
            for (j = 0; j < tb_seq_q_len; j = j + 1) $write("%c", seq_Q[j]);
            $display(""); 
            $write("    Ref   (R) : ");
            for (j = 0; j < tb_seq_r_len; j = j + 1) $write("%c", seq_R[j]);
            $display("\n");
            
            $display("[2] PROCESS: BiWFA Divide-and-Conquer started...");
            
            cigar_buffer = "";
            q_idx = 0;
            r_idx = 0;
            a_idx = 0;
            
            rst_n = 0;
            start_alignment = 0;
            #20 rst_n = 1;
            
            #20 start_alignment = 1;
            #10 start_alignment = 0;
            
            // Wait for Master FSM to finish
            wait(system_done);
            #20; // Extra delay to catch the final CIGAR flush
            
            $display("\n[3] ALIGNMENT COMPLETE!");
            $display("==================================================");
            $display("    Final CIGAR String : %0s", cigar_buffer);
            $display("--------------------------------------------------");
            $display("    RECONSTRUCTED ALIGNMENT:");
            
            // Print Aligned Query
            $write("    Q: ");
            for (j = 0; j < a_idx; j = j + 1) $write("%c", aligned_Q[j]);
            $display("");
            
            // Print Alignment Matches ('|' for match, ' ' for mismatch/gap)
            $write("       ");
            for (j = 0; j < a_idx; j = j + 1) begin
                if (aligned_Q[j] == aligned_R[j] && aligned_Q[j] != "-") $write("|");
                else $write(" ");
            end
            $display("");
            
            // Print Aligned Reference
            $write("    R: ");
            for (j = 0; j < a_idx; j = j + 1) $write("%c", aligned_R[j]);
            $display("\n==================================================");
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
            
            // Loop through the length of the operation
            for (k = 0; k < op_length; k = k + 1) begin
                if (op_code == 2'd0 || op_code == 2'd3) begin 
                    // 0: Match, 3: Mismatch -> Both sequences consume a character
                    aligned_Q[a_idx] = seq_Q[q_idx];
                    aligned_R[a_idx] = seq_R[r_idx];
                    q_idx = q_idx + 1;
                    r_idx = r_idx + 1;
                end else if (op_code == 2'd1) begin 
                    // 1: Insertion (Query has character, Reference has a gap)
                    aligned_Q[a_idx] = seq_Q[q_idx];
                    aligned_R[a_idx] = "-";
                    q_idx = q_idx + 1;
                end else if (op_code == 2'd2) begin 
                    // 2: Deletion (Reference has character, Query has a gap)
                    aligned_Q[a_idx] = "-";
                    aligned_R[a_idx] = seq_R[r_idx];
                    r_idx = r_idx + 1;
                end
                a_idx = a_idx + 1;
            end
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        start_alignment = 0;
        #10;
        
        $display("==================================================");
        $display("Testing Fully Recursive BiWFA Structure");
        
        // Q: ACGTAACCGGT
        // R: ACGTTACCGGT
        seq_Q[0]="A"; seq_R[0]="A";
        seq_Q[1]="C"; seq_R[1]="C";
        seq_Q[2]="G"; seq_R[2]="G";
        seq_Q[3]="T"; seq_R[3]="T";
        seq_Q[4]="A"; seq_R[4]="T"; // Mismatch
        seq_Q[5]="A"; seq_R[5]="A";
        seq_Q[6]="C"; seq_R[6]="C";
        seq_Q[7]="C"; seq_R[7]="C";
        seq_Q[8]="G"; seq_R[8]="G";
        seq_Q[9]="G"; seq_R[9]="G";
        seq_Q[10]="T"; seq_R[10]="T";
        
        run_test(11, "Base Recursive Split Test");
        
        $finish;
    end

endmodule
