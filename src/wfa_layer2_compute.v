`timescale 1ns / 1ps

module wfa_layer2_compute #(
    parameter K_WIDTH = 10,
    parameter OFFSET_WIDTH = 14,
    parameter MAX_Q_LEN = 1000,
    parameter MAX_R_LEN = 1000,
    // Add initialization sentinels for WF memory reads out-of-bounds
    parameter NULL_OFFSET = 14'h3FFF
)(
    input  wire clk,
    input  wire rst_n,

    // Interface with Layer 1 Streamed sequences
    input  wire stream_valid,
    input  wire signed [K_WIDTH-1:0] stream_k,
    input  wire [7:0] stream_q,
    input  wire [7:0] stream_r,

    // Interface with Layer 3 (Wavefront State Storage) read ports
    input  wire [OFFSET_WIDTH-1:0] wf_in_del, // O(s-1, k+1) -> Query Deletion
    input  wire [OFFSET_WIDTH-1:0] wf_in_ins, // O(s-1, k-1) -> Query Insertion
    input  wire [OFFSET_WIDTH-1:0] wf_in_mis, // O(s-1, k)   -> Mismatch
    
    // Pipeline control from Master
    input  wire k_proc_valid,
    input  wire signed [K_WIDTH-1:0] current_k_proc,
    input  wire [SCORE_WIDTH-1:0] current_s,
    
    // Requests going to Layer 1
    output reg req_valid,
    output reg signed [K_WIDTH-1:0] req_k,
    output reg [OFFSET_WIDTH-1:0] req_x,
    input  wire req_ready,
    
    // Final calculated offset to Layer 3
    output reg wf_out_valid,
    output reg signed [K_WIDTH-1:0] wf_out_k,
    output reg [OFFSET_WIDTH-1:0] wf_out_x,
    
    // Termination to Master
    output reg alignment_complete_flag,
    
    // Dynamic Sequence Length from top
    input  wire  [OFFSET_WIDTH-1:0] seq_len
);

    localparam SCORE_WIDTH = 10;
    localparam IDLE = 0;
    localparam WAIT_STREAM = 1;

    reg [1:0] state;
    reg signed [K_WIDTH-1:0] active_k;
    reg [OFFSET_WIDTH-1:0] active_x;
    
    wire [OFFSET_WIDTH-1:0] q_len = seq_len;
    wire [OFFSET_WIDTH-1:0] r_len = seq_len;

    // Combinatorial expressions for recurrence
    wire [OFFSET_WIDTH-1:0] del_val = (wf_in_del == NULL_OFFSET) ? 14'd0 : wf_in_del + 1;
    wire [OFFSET_WIDTH-1:0] ins_val = (wf_in_ins == NULL_OFFSET) ? 14'd0 : wf_in_ins;
    wire [OFFSET_WIDTH-1:0] mis_val = (wf_in_mis == NULL_OFFSET) ? 14'd0 : wf_in_mis + 1;
    reg [OFFSET_WIDTH-1:0] max_x;
    
    // Combinatorial expressions for IDLE state pre-compute
    wire [OFFSET_WIDTH-1:0] d_val = (wf_in_del == NULL_OFFSET) ? 14'd0 : wf_in_del + 1;
    wire [OFFSET_WIDTH-1:0] i_val = (wf_in_ins == NULL_OFFSET) ? 14'd0 : wf_in_ins;
    wire [OFFSET_WIDTH-1:0] m_val = (wf_in_mis == NULL_OFFSET) ? 14'd0 : wf_in_mis + 1;
    reg [OFFSET_WIDTH-1:0] mx;
    
    // Combinatorial extensions for boundary check
    wire [OFFSET_WIDTH-1:0] active_j = active_x - active_k;
    wire out_of_bounds = (active_x >= q_len) || (active_j >= r_len);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            req_valid <= 0;
            wf_out_valid <= 0;
            alignment_complete_flag <= 0;
        end else begin
            wf_out_valid <= 0;
            
            case (state)
                IDLE: begin
                    if (k_proc_valid) begin
                        active_k <= current_k_proc;

                        // --- Exact WFA Recurrence Evaluation ---
                        // x = i (query index)
                        // Deletion (from query):   Wait for an extra R char. x advances by 1.
                        // Insertion (into query):  Wait for an extra Q char. x stays same.
                        // Mismatch:                Wait for both to advance. x advances by 1.
                        
                        if (current_s == 0 && current_k_proc == 0) begin
                            active_x <= 0;
                        end else begin
                            // Handle NULL_OFFSET underflow protection explicitly
                            // Find Max
                            max_x = (del_val > ins_val) ? 
                                     ((del_val > mis_val) ? del_val : mis_val) : 
                                     ((ins_val > mis_val) ? ins_val : mis_val);
                                     
                            active_x <= max_x;
                        end
                        
                        // Fire stream fetch for match loop
                        if (req_ready) begin
                            req_valid <= 1;
                            req_k <= current_k_proc;
                            // Wait for update before triggering req_x.
                            // In this simple RTL, we assume 1 cycle combinatorial.
                            // To be syntactically robust we can decouple state delays.
                            state <= WAIT_STREAM;
                        end
                    end
                end

                WAIT_STREAM: begin
                    req_valid <= 0;
                    if (stream_valid && stream_k == active_k) begin
                        
                        // Check Boundary conditions before executing matching logic
                        // Sequence Termination rule
                        if (active_x >= q_len && active_j >= r_len) begin
                            alignment_complete_flag <= 1;
                        end
                        
                        if (!out_of_bounds && stream_q == stream_r) begin
                            // Match extended
                            active_x <= active_x + 1;
                            if (req_ready) begin
                                req_valid <= 1;
                                req_k <= active_k;
                                req_x <= active_x + 1;
                            end
                        end else begin
                            // Mismatch or Out of Bounds hit
                            wf_out_valid <= 1;
                            wf_out_k <= active_k;
                            wf_out_x <= active_x;
                            state <= IDLE;
                        end
                    end
                end
            endcase
            
            // To prevent req_x being undefined on cycle 0 of state transitions
            if (state == IDLE && k_proc_valid) begin
                // Recompute max_x combinatorially to pipeline req_x correctly
                mx = (d_val > i_val) ? ((d_val > m_val) ? d_val : m_val) : ((i_val > m_val) ? i_val : m_val);
                if (current_s == 0 && current_k_proc == 0) mx = 0;
                req_x <= mx;
            end
        end
    end

endmodule
