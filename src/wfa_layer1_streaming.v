`timescale 1ns / 1ps

module wfa_layer1_streaming #(
    parameter MAX_SEQ_LEN = 16384,
    parameter ADDR_WIDTH = 14,
    parameter K_WIDTH = 10,
    parameter OFFSET_WIDTH = 14
)(
    input  wire clk,
    input  wire rst_n,
    
    // Interface from Layer 2 (DPUs request address)
    input  wire req_valid,
    input  wire signed [K_WIDTH-1:0] req_k,
    input  wire [OFFSET_WIDTH-1:0] req_x,
    output wire req_ready,
    
    // Sequence memory pre-load interface
    input  wire preload_en,
    input  wire [ADDR_WIDTH-1:0] preload_addr,
    input  wire [7:0] preload_q_char,
    input  wire [7:0] preload_r_char,

    // Interface to Layer 2 (Data to Stream MUX / DPUs)
    output reg  resp_valid,
    output reg  signed [K_WIDTH-1:0] resp_k,
    output wire [7:0] resp_q_char,
    output wire [7:0] resp_r_char
);

    // BRAMs for Query and Reference Sequences
    // In a real FPGA these would be inferred as Block RAMs or URAMs
    reg [7:0] q_mem [0:MAX_SEQ_LEN-1];
    reg [7:0] r_mem [0:MAX_SEQ_LEN-1];

    always @(posedge clk) begin
        if (preload_en) begin
            q_mem[preload_addr] <= preload_q_char;
            r_mem[preload_addr] <= preload_r_char;
        end
    end

    // Address FIFO
    // Buffers (k, x) requests from DPUs
    reg signed [K_WIDTH-1:0] fifo_k [0:15];
    reg [OFFSET_WIDTH-1:0] fifo_x [0:15];
    reg [3:0] fifo_wr_ptr, fifo_rd_ptr;
    reg [4:0] fifo_count;

    wire fifo_full = (fifo_count == 16);
    wire fifo_empty = (fifo_count == 0);
    assign req_ready = ~fifo_full;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= 0;
            fifo_rd_ptr <= 0;
            fifo_count <= 0;
        end else begin
            if (req_valid && !fifo_full && !(fifo_empty == 0 && fifo_count > 0 && !fifo_empty)) begin // simplify logic
                fifo_k[fifo_wr_ptr] <= req_k;
                fifo_x[fifo_wr_ptr] <= req_x;
                fifo_wr_ptr <= fifo_wr_ptr + 1;
                fifo_count <= fifo_count + 1;
            end
            
            // Read side
            if (!fifo_empty) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1;
                fifo_count <= fifo_count - 1 + (req_valid && !fifo_full);
            end
        end
    end

    // Diagonal Address Generator
    // Q_addr = x, R_addr = x - k
    wire signed [K_WIDTH-1:0] curr_k = fifo_k[fifo_rd_ptr];
    wire [OFFSET_WIDTH-1:0] curr_x = fifo_x[fifo_rd_ptr];
    wire [ADDR_WIDTH-1:0] q_addr = curr_x;
    
    // Signed math for reference address
    wire [ADDR_WIDTH-1:0] r_addr = curr_x - curr_k;

    reg [ADDR_WIDTH-1:0] q_addr_reg, r_addr_reg;
    reg signed [K_WIDTH-1:0] k_delay;
    reg read_en_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_en_reg <= 0;
        end else begin
            read_en_reg <= !fifo_empty;
            if (!fifo_empty) begin
                q_addr_reg <= q_addr;
                r_addr_reg <= r_addr;
                k_delay <= curr_k;
            end
        end
    end

    // Memory read port
    // BRAM has 1 cycle read latency
    reg [7:0] q_read_data;
    reg [7:0] r_read_data;
    always @(posedge clk) begin
        q_read_data <= q_mem[q_addr_reg];
        r_read_data <= r_mem[r_addr_reg];
    end

    // Stream MUX output alignment
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_valid <= 0;
        end else begin
            resp_valid <= read_en_reg;
            resp_k <= k_delay;
        end
    end

    assign resp_q_char = q_read_data;
    assign resp_r_char = r_read_data;

endmodule
