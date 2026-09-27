`timescale 1ns/1ps

module sparse_conv_scheduler #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer WEIGHT_WIDTH = 16,
    parameter integer ACC_WIDTH    = 48,
    parameter integer INPUT_H      = 8,
    parameter integer INPUT_W      = 8,
    parameter integer INPUT_C      = 3,
    parameter integer KERNEL_H     = 3,
    parameter integer KERNEL_W     = 3,
    parameter integer OUTPUT_C     = 16,
    parameter integer PE_COUNT     = 64
) (
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic                                      start,
    input  logic [6:0]                                active_pe_count,
    input  logic signed [DATA_WIDTH-1:0]              input_mem [0:INPUT_C*INPUT_H*INPUT_W-1],
    input  logic signed [WEIGHT_WIDTH-1:0]            weight_mem [0:OUTPUT_C*INPUT_C*KERNEL_H*KERNEL_W-1],
    output logic                                      output_valid,
    output logic [31:0]                               useful_mac_count,
    output logic [31:0]                               skipped_mac_count,
    output logic [31:0]                               cycle_count,
    output logic signed [ACC_WIDTH-1:0]               output_mem [0:OUTPUT_C*INPUT_H*INPUT_W-1]
);
    localparam integer OUTPUT_H        = INPUT_H;
    localparam integer OUTPUT_W        = INPUT_W;
    localparam integer OUTPUT_ELEMENTS = OUTPUT_C * OUTPUT_H * OUTPUT_W;
    localparam integer MACS_PER_OUTPUT = INPUT_C * KERNEL_H * KERNEL_W;

    integer oc;
    integer row;
    integer col;
    integer ic;
    integer ky;
    integer kx;
    integer yy;
    integer xx;
    integer idx;
    integer flat_idx;
    integer output_index;
    integer active_pe_int;
    integer acc;
    logic signed [DATA_WIDTH-1:0] activation;
    logic signed [WEIGHT_WIDTH-1:0] weight;

    always_comb begin
        useful_mac_count = 0;
        skipped_mac_count = 0;
        for (output_index = 0; output_index < OUTPUT_ELEMENTS; output_index = output_index + 1)
            output_mem[output_index] = '0;

        for (oc = 0; oc < OUTPUT_C; oc = oc + 1) begin
            for (row = 0; row < OUTPUT_H; row = row + 1) begin
                for (col = 0; col < OUTPUT_W; col = col + 1) begin
                    idx = oc * OUTPUT_H * OUTPUT_W + row * OUTPUT_W + col;
                    acc = 0;
                    for (ic = 0; ic < INPUT_C; ic = ic + 1) begin
                        for (ky = 0; ky < KERNEL_H; ky = ky + 1) begin
                            for (kx = 0; kx < KERNEL_W; kx = kx + 1) begin
                                yy = row + ky - 1;
                                xx = col + kx - 1;
                                if ((yy >= 0) && (yy < INPUT_H) && (xx >= 0) && (xx < INPUT_W)) begin
                                    activation = input_mem[ic * INPUT_H * INPUT_W + yy * INPUT_W + xx];
                                    weight = weight_mem[oc * INPUT_C * KERNEL_H * KERNEL_W + ic * KERNEL_H * KERNEL_W + ky * KERNEL_W + kx];
                                    if (activation == 0) begin
                                        skipped_mac_count = skipped_mac_count + 1;
                                    end else begin
                                        acc = acc + $signed(activation) * $signed(weight);
                                        useful_mac_count = useful_mac_count + 1;
                                    end
                                end else begin
                                    skipped_mac_count = skipped_mac_count + 1;
                                end
                            end
                        end
                    end
                    output_mem[idx] = acc;
                end
            end
        end

        active_pe_int = active_pe_count;
        if (active_pe_int <= 0)
            cycle_count = 0;
        else
            cycle_count = (useful_mac_count + active_pe_int - 1) / active_pe_int;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            output_valid <= 1'b0;
        end else begin
            output_valid <= 1'b0;
            if (start) begin
                output_valid <= 1'b1;
            end
        end
    end
endmodule
