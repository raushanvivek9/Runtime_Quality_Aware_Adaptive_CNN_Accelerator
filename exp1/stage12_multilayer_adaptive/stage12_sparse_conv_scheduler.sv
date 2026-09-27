`timescale 1ns/1ps

module stage12_sparse_conv_scheduler #(
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
    output logic [31:0]                               total_activation_elements,
    output logic [31:0]                               zero_activation_elements,
    output logic [31:0]                               useful_mac_count,
    output logic [31:0]                               skipped_mac_count,
    output logic [31:0]                               cycle_count,
    output logic [15:0]                               sparsity_q,
    output logic signed [ACC_WIDTH-1:0]               output_mem [0:OUTPUT_C*INPUT_H*INPUT_W-1]
);
    integer oc, row, col, ic, ky, kx, yy, xx, idx;
    integer active_pe_int;
    integer total_count;
    integer zero_count;
    integer useful_count;
    integer skipped_count;

    always_comb begin
        total_count = 0;
        zero_count = 0;
        useful_count = 0;
        skipped_count = 0;
        for (idx = 0; idx < OUTPUT_C*INPUT_H*INPUT_W; idx = idx + 1) begin
            output_mem[idx] = '0;
        end

        for (oc = 0; oc < OUTPUT_C; oc = oc + 1) begin
            for (row = 0; row < INPUT_H; row = row + 1) begin
                for (col = 0; col < INPUT_W; col = col + 1) begin
                    idx = oc * INPUT_H * INPUT_W + row * INPUT_W + col;
                    output_mem[idx] = '0;
                    for (ic = 0; ic < INPUT_C; ic = ic + 1) begin
                        for (ky = 0; ky < KERNEL_H; ky = ky + 1) begin
                            for (kx = 0; kx < KERNEL_W; kx = kx + 1) begin
                                yy = row + ky - 1;
                                xx = col + kx - 1;
                                if ((yy >= 0) && (yy < INPUT_H) && (xx >= 0) && (xx < INPUT_W)) begin
                                    total_count = total_count + 1;
                                    if (input_mem[ic * INPUT_H * INPUT_W + yy * INPUT_W + xx] == 0) begin
                                        zero_count = zero_count + 1;
                                        skipped_count = skipped_count + 1;
                                    end else begin
                                        output_mem[idx] = output_mem[idx] +
                                            $signed(input_mem[ic * INPUT_H * INPUT_W + yy * INPUT_W + xx]) *
                                            $signed(weight_mem[oc * INPUT_C * KERNEL_H * KERNEL_W + ic * KERNEL_H * KERNEL_W + ky * KERNEL_W + kx]);
                                        useful_count = useful_count + 1;
                                    end
                                end else begin
                                    zero_count = zero_count + 1;
                                    skipped_count = skipped_count + 1;
                                end
                            end
                        end
                    end
                end
            end
        end

        total_activation_elements = INPUT_C * INPUT_H * INPUT_W;
        zero_activation_elements = zero_count;
        useful_mac_count = useful_count;
        skipped_mac_count = skipped_count;

        active_pe_int = active_pe_count;
        if (active_pe_int <= 0) begin
            cycle_count = 0;
        end else begin
            cycle_count = (useful_count + active_pe_int - 1) / active_pe_int;
        end

        if (total_activation_elements == 0) begin
            sparsity_q = 0;
        end else begin
            sparsity_q = (zero_count * 10000) / total_activation_elements;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            output_valid <= 1'b0;
        end else if (start) begin
            output_valid <= 1'b1;
        end else begin
            output_valid <= 1'b0;
        end
    end
endmodule
