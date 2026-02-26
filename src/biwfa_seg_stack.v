`timescale 1ns / 1ps

module biwfa_seg_stack #(
    parameter ADDR_WIDTH = 14,
    parameter MAX_DEPTH_BITS = 10 // Max 1024 depth, more than enough for s_max
)(
    input  wire clk,
    input  wire rst_n,

    input  wire push,
    input  wire [ADDR_WIDTH-1:0] in_q_start,
    input  wire [ADDR_WIDTH-1:0] in_q_end,
    input  wire [ADDR_WIDTH-1:0] in_r_start,
    input  wire [ADDR_WIDTH-1:0] in_r_end,

    input  wire pop,
    output reg  [ADDR_WIDTH-1:0] out_q_start,
    output reg  [ADDR_WIDTH-1:0] out_q_end,
    output reg  [ADDR_WIDTH-1:0] out_r_start,
    output reg  [ADDR_WIDTH-1:0] out_r_end,
    
    output wire empty,
    output wire full
);

    localparam DATA_WIDTH = 4 * ADDR_WIDTH;
    localparam MAX_DEPTH = (1 << MAX_DEPTH_BITS);

    reg [DATA_WIDTH-1:0] stack_mem [0:MAX_DEPTH-1];
    reg [MAX_DEPTH_BITS:0] sp; // Stack pointer

    assign empty = (sp == 0);
    assign full = (sp == MAX_DEPTH);

    wire [DATA_WIDTH-1:0] push_data = {in_q_start, in_q_end, in_r_start, in_r_end};

    // BRAM/LUTRAM Write
    always @(posedge clk) begin
        if (push && !full) begin
            stack_mem[sp] <= push_data;
        end
    end

    // Stack Pointer & Output Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp <= 0;
            out_q_start <= 0;
            out_q_end <= 0;
            out_r_start <= 0;
            out_r_end <= 0;
        end else begin
            if (push && !full) begin
                if (pop) begin
                    // Push and pop same cycle (bypass or replace top)
                    // If popping, we replace the top conceptually, sp stays same length
                    // In a normal LIFO, simultaneous push/pop to same addr usually is handled specially.
                    // For safety in this FSM, we will not assert Push & Pop together.
                end else begin
                    sp <= sp + 1;
                end
            end else if (pop && !empty) begin
                sp <= sp - 1;
            end
            
            // Read port (combinatorial output of current top if popping, or pre-read?
            // To make it 1-cycle latency read, let's output the top of stack when pop is asserted.
            // Actuality: we can just continuously output the top of stack `sp-1` if we want zero latency FWFT.
            // Let's implement FWFT (First Word Fall Through) behavior for ease of FSM use.
        end
    end
    
    // FWFT Continuous Assign (LUTRAM asynchronous read)
    wire [MAX_DEPTH_BITS-1:0] top_addr = (sp == 0) ? 0 : sp - 1;
    wire [DATA_WIDTH-1:0] top_data = stack_mem[top_addr];
    
    always @(*) begin
        if (!empty) begin
            {out_q_start, out_q_end, out_r_start, out_r_end} = top_data;
        end else begin
            out_q_start = 0;
            out_q_end = 0;
            out_r_start = 0;
            out_r_end = 0;
        end
    end

endmodule
