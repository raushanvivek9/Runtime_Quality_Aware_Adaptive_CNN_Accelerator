`timescale 1ns/1ps

// Streaming activation statistics collector. No activation tensor is stored.
module runtime_monitor #(
    parameter integer DATA_W  = 16,
    parameter integer COUNT_W = 32,
    parameter integer SUM_W   = 48,
    parameter integer SUMSQ_W = 64
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         layer_start,
    input  logic                         layer_end,
    input  logic                         sample_valid,
    input  logic signed [DATA_W-1:0]     sample_data,
    output logic                         stats_valid,
    output logic [COUNT_W-1:0]           element_count,
    output logic [COUNT_W-1:0]           zero_count,
    output logic signed [SUM_W-1:0]      sum,
    output logic [SUMSQ_W-1:0]           sum_square,
    // Appended ports preserve the original positional port ordering.
    input  logic [1:0]                   layer_id,
    output logic [1:0]                   stats_layer_id
);
    logic [COUNT_W-1:0]      element_count_next;
    logic [COUNT_W-1:0]      zero_count_next;
    logic signed [SUM_W-1:0] sum_next;
    logic [SUMSQ_W-1:0]      sum_square_next;
    logic signed [SUM_W-1:0] sample_ext;

    // A DATA_W-bit signed value needs 2*DATA_W bits for its positive square.
    // This explicit intermediate prevents a DATA_W-wide multiply from truncating.
    logic signed [(2*DATA_W)-1:0] sample_multiply_operand;
    logic signed [(2*DATA_W)-1:0] sample_square_wide;
    logic [SUMSQ_W-1:0]           sample_square_ext;

    always_comb begin
        sample_ext              = sample_data;
        sample_multiply_operand = sample_data;
        sample_square_wide      = sample_multiply_operand * sample_multiply_operand;
        sample_square_ext  = sample_square_wide;

        element_count_next = element_count + {{(COUNT_W-1){1'b0}}, 1'b1};
        zero_count_next    = zero_count +
                             ((sample_data == '0) ? {{(COUNT_W-1){1'b0}}, 1'b1}
                                                   : '0);
        sum_next           = sum + sample_ext;
        sum_square_next    = sum_square + sample_square_ext;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stats_valid    <= 1'b0;
            element_count  <= '0;
            zero_count     <= '0;
            sum            <= '0;
            sum_square     <= '0;
            stats_layer_id <= '0;
        end else begin
            stats_valid <= 1'b0;

            // layer_start starts a fresh accumulator. Supporting a valid sample
            // on this cycle avoids silently discarding it, although the documented
            // stream protocol uses sample_valid=0 with layer_start.
            if (layer_start) begin
                stats_layer_id <= layer_id;
                if (sample_valid) begin
                    element_count <= {{(COUNT_W-1){1'b0}}, 1'b1};
                    zero_count    <= (sample_data == '0) ?
                                     {{(COUNT_W-1){1'b0}}, 1'b1} : '0;
                    sum           <= sample_ext;
                    sum_square    <= sample_square_ext;
                end else begin
                    element_count <= '0;
                    zero_count    <= '0;
                    sum           <= '0;
                    sum_square    <= '0;
                end
            end else if (sample_valid) begin
                element_count <= element_count_next;
                zero_count    <= zero_count_next;
                sum           <= sum_next;
                sum_square    <= sum_square_next;
            end

            // layer_end normally follows the final valid sample by one cycle.
            // If it coincides with a final sample, the nonblocking accumulator
            // updates and stats_valid become visible together after this edge.
            if (layer_end)
                stats_valid <= 1'b1;
        end
    end
endmodule
