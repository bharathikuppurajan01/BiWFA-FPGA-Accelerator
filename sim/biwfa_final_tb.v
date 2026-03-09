`timescale 1ns / 1ps

module biwfa_final_tb;

    reg clk;
    reg rst_n;
    reg start_alignment;
    
    // Preload Interface
    reg preload_en;
    reg [13:0] preload_addr;
    reg [7:0] preload_q_char;
    reg [7:0] preload_r_char;

    wire system_done;
    wire [9:0] final_edit_distance;
    wire align_valid;
    wire [1:0] op_code;
    wire [13:0] op_length;

    parameter MAX_SEQ_LEN = 2000;

    // We instantiate the REAL 5-layer algorithm here
    wfa_top_5layer_algo #(
        .SCORE_WIDTH(10), .MAX_SEQ_LEN(MAX_SEQ_LEN), .ADDR_WIDTH(14),
        .K_WIDTH(10), .OFFSET_WIDTH(14), .K_MIN(-1024), .K_MAX(1024),
        .NULL_OFFSET(14'h3FFF)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start_alignment(start_alignment),
        .preload_en(preload_en), .preload_addr(preload_addr), .preload_q_char(preload_q_char), .preload_r_char(preload_r_char),
        .system_done(system_done), .final_edit_distance(final_edit_distance),
        .align_valid(align_valid), .op_code(op_code), .op_length(op_length),
        .seq_len(tb_seq_len)
    );

    always #5 clk = ~clk;

    // Test Variables
    reg [7:0] seq_Q [0:MAX_SEQ_LEN-1];
    reg [7:0] seq_R [0:MAX_SEQ_LEN-1];
    integer i, j;
    
    // Lengths
    reg [13:0] tb_seq_q_len;
    reg [13:0] tb_seq_r_len;
    reg [13:0] tb_seq_len; // Max of Q and R length padded
    
    // CIGAR Buffer
    reg [8*MAX_SEQ_LEN-1:0] cigar_buffer;
    
    // Reconstruct Arrays
    reg [7:0] aligned_Q [0:MAX_SEQ_LEN*2-1];
    reg [7:0] aligned_R [0:MAX_SEQ_LEN*2-1];
    integer q_idx;
    integer r_idx;
    integer a_idx;
    integer wait_timeout;
    
    task run_test;
        input [800:1] test_name;
        begin
            $display("==================================================");
            $display("       TRUE BiWFA ALIGNMENT TEST: %0s", test_name);
            $display("==================================================");
            
            // For the 5-layer algorithm, sequence length is defined by the maximum of the two bounds 
            // since we pad the shorter sequence with 0x00.
            tb_seq_len = (tb_seq_q_len > tb_seq_r_len) ? tb_seq_q_len : tb_seq_r_len;
            
            $display("\n[1] INPUT SEQUENCES:");
            $display("    Sequence Length Configured: %0d", tb_seq_len);
            $write("    Query (Q) : ");
            for (j = 0; j < tb_seq_q_len; j = j + 1) $write("%c", seq_Q[j]);
            $display(""); 
            $write("    Ref   (R) : ");
            for (j = 0; j < tb_seq_r_len; j = j + 1) $write("%c", seq_R[j]);
            $display("\n");
            
            // Clear trackers
            cigar_buffer = "";
            q_idx = 0;
            r_idx = 0;
            a_idx = 0;
            wait_timeout = 0;
            
            // Reset
            rst_n = 0;
            start_alignment = 0;
            preload_en = 0;
            #20 rst_n = 1;
            
            // Preload the BRAMs in Layer 1 Sequence Memory
            $display("[2] PRELOADING SEQUENCES...");
            preload_en = 1;
            for (i = 0; i < tb_seq_len; i = i + 1) begin
                preload_addr = i;
                preload_q_char = seq_Q[i];
                preload_r_char = seq_R[i];
                #10;
            end
            preload_en = 0;
            
            $display("[3] PROCESS: BiWFA 5-Layer Execution Engine started...");
            
            // Start algorithm
            #20 start_alignment = 1;
            #10 start_alignment = 0;
            
            // Wait for completion with timeout
            while(!system_done && wait_timeout < 50000) begin
                #10;
                wait_timeout = wait_timeout + 1;
            end
            
            if (wait_timeout >= 50000) begin
                $display("\n[!] ERROR: Simulation timed out. Check Wavefront bounds.");
            end else begin
                #100; // Extra cycle to catch CIGAR flush
                
                $display("\n[4] ALIGNMENT COMPLETE!");
                $display("==================================================");
                $display("    Final Edit Distance (Score): %0d", final_edit_distance);
                $display("    Final CIGAR String         : %0s", cigar_buffer);
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
        end
    endtask
    
    always @(posedge clk) begin
        if (align_valid) begin
            case (op_code)
                2'd0: cigar_buffer = {cigar_buffer[(8*MAX_SEQ_LEN)-17:0], 8'd48 + op_length[7:0], 8'h4D}; // "M"
                2'd1: cigar_buffer = {cigar_buffer[(8*MAX_SEQ_LEN)-17:0], 8'd48 + op_length[7:0], 8'h49}; // "I"
                2'd2: cigar_buffer = {cigar_buffer[(8*MAX_SEQ_LEN)-17:0], 8'd48 + op_length[7:0], 8'h44}; // "D"
                2'd3: cigar_buffer = {cigar_buffer[(8*MAX_SEQ_LEN)-17:0], 8'd48 + op_length[7:0], 8'h58}; // "X"
            endcase
            
            $display("  -> Hardware Engine Emitted Trace: %0d%0s", op_length, 
                (op_code==0)?"M": (op_code==1)?"I": (op_code==2)?"D": "X"
            );
            
            // Reconstruct logic
            for (i = 0; i < op_length; i = i + 1) begin
                if (op_code == 2'd0 || op_code == 2'd3) begin 
                    aligned_Q[a_idx] = (q_idx < tb_seq_q_len) ? seq_Q[q_idx] : "-";
                    aligned_R[a_idx] = (r_idx < tb_seq_r_len) ? seq_R[r_idx] : "-";
                    q_idx = q_idx + 1;
                    r_idx = r_idx + 1;
                end else if (op_code == 2'd1) begin  // Insertion (Query has char)
                    aligned_Q[a_idx] = (q_idx < tb_seq_q_len) ? seq_Q[q_idx] : "-";
                    aligned_R[a_idx] = "-";
                    q_idx = q_idx + 1;
                end else if (op_code == 2'd2) begin  // Deletion (Reference has char)
                    aligned_Q[a_idx] = "-";
                    aligned_R[a_idx] = (r_idx < tb_seq_r_len) ? seq_R[r_idx] : "-";
                    r_idx = r_idx + 1;
                end
                a_idx = a_idx + 1;
            end
        end
    end

    initial begin
        $dumpfile("biwfa_final_sim.vcd");
        $dumpvars(0, biwfa_final_tb);

        clk = 0;
        rst_n = 0;
        start_alignment = 0;
        preload_en = 0; preload_addr = 0; preload_q_char = 0; preload_r_char = 0;
        #10;
        
        $display("==================================================");
        $display("Starting Full TRUE BiWFA 5-Layer Simulation");
        
        // ------------------------- EXAMPLE 1 -------------------------
        for (i = 0; i < MAX_SEQ_LEN; i = i + 1) begin seq_Q[i] = 8'h00; seq_R[i] = 8'h00; end
        $readmemh("query.mem", seq_Q); $readmemh("reference.mem", seq_R);
        tb_seq_q_len = 0; while(tb_seq_q_len < MAX_SEQ_LEN && seq_Q[tb_seq_q_len] != 8'h00 && seq_Q[tb_seq_q_len] !== 8'hxx) tb_seq_q_len = tb_seq_q_len + 1;
        tb_seq_r_len = 0; while(tb_seq_r_len < MAX_SEQ_LEN && seq_R[tb_seq_r_len] != 8'h00 && seq_R[tb_seq_r_len] !== 8'hxx) tb_seq_r_len = tb_seq_r_len + 1;
        
        if (tb_seq_q_len > 0 && tb_seq_r_len > 0) run_test("Example 1 (query.mem / reference.mem)");

        // ------------------------- EXAMPLE 2 -------------------------
        for (i = 0; i < MAX_SEQ_LEN; i = i + 1) begin seq_Q[i] = 8'h00; seq_R[i] = 8'h00; end
        $readmemh("query2.mem", seq_Q); $readmemh("reference2.mem", seq_R);
        tb_seq_q_len = 0; while(tb_seq_q_len < MAX_SEQ_LEN && seq_Q[tb_seq_q_len] != 8'h00 && seq_Q[tb_seq_q_len] !== 8'hxx) tb_seq_q_len = tb_seq_q_len + 1;
        tb_seq_r_len = 0; while(tb_seq_r_len < MAX_SEQ_LEN && seq_R[tb_seq_r_len] != 8'h00 && seq_R[tb_seq_r_len] !== 8'hxx) tb_seq_r_len = tb_seq_r_len + 1;
        
        if (tb_seq_q_len > 0 && tb_seq_r_len > 0) run_test("Example 2 (query2.mem / reference2.mem)");

        // ------------------------- EXAMPLE 3 -------------------------
        for (i = 0; i < MAX_SEQ_LEN; i = i + 1) begin seq_Q[i] = 8'h00; seq_R[i] = 8'h00; end
        $readmemh("query3.mem", seq_Q); $readmemh("reference3.mem", seq_R);
        tb_seq_q_len = 0; while(tb_seq_q_len < MAX_SEQ_LEN && seq_Q[tb_seq_q_len] != 8'h00 && seq_Q[tb_seq_q_len] !== 8'hxx) tb_seq_q_len = tb_seq_q_len + 1;
        tb_seq_r_len = 0; while(tb_seq_r_len < MAX_SEQ_LEN && seq_R[tb_seq_r_len] != 8'h00 && seq_R[tb_seq_r_len] !== 8'hxx) tb_seq_r_len = tb_seq_r_len + 1;
        
        if (tb_seq_q_len > 0 && tb_seq_r_len > 0) run_test("Example 3 (query3.mem / reference3.mem)");
        
        $finish;
    end

endmodule
