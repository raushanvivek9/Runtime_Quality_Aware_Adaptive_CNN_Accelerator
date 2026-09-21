`timescale 1ns/1ps

// Behavioral 1024-entry output store with a deterministic ascending-index
// stream.  stream_last accompanies index 1023 on its valid/ready transfer.
module output_buffer #(
    parameter integer ACC_WIDTH = 48,
    parameter integer ELEMENTS  = 1024
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         clear,
    input  logic                         write_valid,
    input  logic [9:0]                   write_index,
    input  logic signed [ACC_WIDTH-1:0]  write_data,
    input  logic                         stream_start,
    output logic                         output_stream_valid,
    input  logic                         output_stream_ready,
    output logic signed [ACC_WIDTH-1:0]  output_stream_data,
    output logic [9:0]                   output_stream_index,
    output logic                         output_stream_last,
    output logic                         output_stream_done,
    output logic [31:0]                  write_count,
    output logic [31:0]                  stream_read_count
);
    logic signed [ACC_WIDTH-1:0] mem [0:ELEMENTS-1];
    logic streaming;
    logic [9:0] stream_index;
    integer i;

    always_comb begin
        output_stream_valid = streaming;
        output_stream_index = stream_index;
        output_stream_data  = mem[stream_index];
        output_stream_last  = streaming && (stream_index == ELEMENTS-1);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            streaming         <= 1'b0;
            stream_index      <= '0;
            output_stream_done <= 1'b0;
            write_count       <= '0;
            stream_read_count <= '0;
            for (i = 0; i < ELEMENTS; i = i + 1)
                mem[i] <= '0;
        end else if (clear) begin
            streaming         <= 1'b0;
            stream_index      <= '0;
            output_stream_done <= 1'b0;
            write_count       <= '0;
            stream_read_count <= '0;
            for (i = 0; i < ELEMENTS; i = i + 1)
                mem[i] <= '0;
        end else begin
            output_stream_done <= 1'b0;
            if (write_valid && (write_index < ELEMENTS)) begin
                mem[write_index] <= write_data;
                write_count <= write_count + 1'b1;
            end
            if (stream_start && !streaming) begin
                streaming    <= 1'b1;
                stream_index <= '0;
            end else if (streaming && output_stream_ready) begin
                stream_read_count <= stream_read_count + 1'b1;
                if (stream_index == ELEMENTS-1) begin
                    streaming          <= 1'b0;
                    output_stream_done <= 1'b1;
                end else begin
                    stream_index <= stream_index + 1'b1;
                end
            end
        end
    end
endmodule
