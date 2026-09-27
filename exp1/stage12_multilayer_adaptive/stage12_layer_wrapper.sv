`timescale 1ns/1ps

module stage12_layer_wrapper #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer WEIGHT_WIDTH = 16,
    parameter integer ACC_WIDTH    = 48,
    parameter integer INPUT_H      = 8,
    parameter integer INPUT_W      = 8,
    parameter integer INPUT_C      = 3,
    parameter integer KERNEL_H     = 3,
    parameter integer KERNEL_W     = 3,
    parameter integer OUTPUT_C     = 16
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
    stage12_sparse_conv_scheduler #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .INPUT_H(INPUT_H),
        .INPUT_W(INPUT_W),
        .INPUT_C(INPUT_C),
        .KERNEL_H(KERNEL_H),
        .KERNEL_W(KERNEL_W),
        .OUTPUT_C(OUTPUT_C),
        .PE_COUNT(64)
    ) core (
        .clk(clk),
        .rst(rst),
        .start(start),
        .active_pe_count(active_pe_count),
        .input_mem(input_mem),
        .weight_mem(weight_mem),
        .output_valid(output_valid),
        .total_activation_elements(total_activation_elements),
        .zero_activation_elements(zero_activation_elements),
        .useful_mac_count(useful_mac_count),
        .skipped_mac_count(skipped_mac_count),
        .cycle_count(cycle_count),
        .sparsity_q(sparsity_q),
        .output_mem(output_mem)
    );
endmodule
