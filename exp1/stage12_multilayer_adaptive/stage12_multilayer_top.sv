`timescale 1ns/1ps

module stage12_multilayer_top #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer WEIGHT_WIDTH = 16,
    parameter integer ACC_WIDTH    = 48,
    parameter integer INPUT_H      = 8,
    parameter integer INPUT_W      = 8
) (
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic                                      start,
    input  logic [1:0]                                case_id,
    input  logic [1:0]                                layer_id,
    input  logic [6:0]                                active_pe_count,
    input  logic signed [DATA_WIDTH-1:0]              layer1_input [0:3*8*8-1],
    input  logic signed [DATA_WIDTH-1:0]              layer2_input [0:16*8*8-1],
    input  logic signed [DATA_WIDTH-1:0]              layer3_input [0:32*8*8-1],
    input  logic signed [WEIGHT_WIDTH-1:0]            layer1_weight [0:16*3*3*3-1],
    input  logic signed [WEIGHT_WIDTH-1:0]            layer2_weight [0:32*16*3*3-1],
    input  logic signed [WEIGHT_WIDTH-1:0]            layer3_weight [0:16*32*3*3-1],
    output logic                                      output_valid,
    output logic [31:0]                               total_activation_elements,
    output logic [31:0]                               zero_activation_elements,
    output logic [31:0]                               useful_mac_count,
    output logic [31:0]                               skipped_mac_count,
    output logic [31:0]                               cycle_count,
    output logic [15:0]                               sparsity_q,
    output logic signed [ACC_WIDTH-1:0]               output_mem [0:32*8*8-1]
);
    logic                                      layer1_valid;
    logic                                      layer2_valid;
    logic                                      layer3_valid;
    logic [31:0]                               layer1_total_ae;
    logic [31:0]                               layer1_zero_ae;
    logic [31:0]                               layer1_useful;
    logic [31:0]                               layer1_skipped;
    logic [31:0]                               layer1_cycle;
    logic [15:0]                               layer1_sparsity;
    logic [31:0]                               layer2_total_ae;
    logic [31:0]                               layer2_zero_ae;
    logic [31:0]                               layer2_useful;
    logic [31:0]                               layer2_skipped;
    logic [31:0]                               layer2_cycle;
    logic [15:0]                               layer2_sparsity;
    logic [31:0]                               layer3_total_ae;
    logic [31:0]                               layer3_zero_ae;
    logic [31:0]                               layer3_useful;
    logic [31:0]                               layer3_skipped;
    logic [31:0]                               layer3_cycle;
    logic [15:0]                               layer3_sparsity;

    logic signed [ACC_WIDTH-1:0] layer1_out [0:16*8*8-1];
    logic signed [ACC_WIDTH-1:0] layer2_out [0:32*8*8-1];
    logic signed [ACC_WIDTH-1:0] layer3_out [0:16*8*8-1];

    stage12_layer_wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .INPUT_H(INPUT_H),
        .INPUT_W(INPUT_W),
        .INPUT_C(3),
        .KERNEL_H(3),
        .KERNEL_W(3),
        .OUTPUT_C(16)
    ) u_layer1 (
        .clk(clk),
        .rst(rst),
        .start(start && (layer_id == 2'd0)),
        .active_pe_count(active_pe_count),
        .input_mem(layer1_input),
        .weight_mem(layer1_weight),
        .output_valid(layer1_valid),
        .total_activation_elements(layer1_total_ae),
        .zero_activation_elements(layer1_zero_ae),
        .useful_mac_count(layer1_useful),
        .skipped_mac_count(layer1_skipped),
        .cycle_count(layer1_cycle),
        .sparsity_q(layer1_sparsity),
        .output_mem(layer1_out)
    );

    stage12_layer_wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .INPUT_H(INPUT_H),
        .INPUT_W(INPUT_W),
        .INPUT_C(16),
        .KERNEL_H(3),
        .KERNEL_W(3),
        .OUTPUT_C(32)
    ) u_layer2 (
        .clk(clk),
        .rst(rst),
        .start(start && (layer_id == 2'd1)),
        .active_pe_count(active_pe_count),
        .input_mem(layer2_input),
        .weight_mem(layer2_weight),
        .output_valid(layer2_valid),
        .total_activation_elements(layer2_total_ae),
        .zero_activation_elements(layer2_zero_ae),
        .useful_mac_count(layer2_useful),
        .skipped_mac_count(layer2_skipped),
        .cycle_count(layer2_cycle),
        .sparsity_q(layer2_sparsity),
        .output_mem(layer2_out)
    );

    stage12_layer_wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .INPUT_H(INPUT_H),
        .INPUT_W(INPUT_W),
        .INPUT_C(32),
        .KERNEL_H(3),
        .KERNEL_W(3),
        .OUTPUT_C(16)
    ) u_layer3 (
        .clk(clk),
        .rst(rst),
        .start(start && (layer_id == 2'd2)),
        .active_pe_count(active_pe_count),
        .input_mem(layer3_input),
        .weight_mem(layer3_weight),
        .output_valid(layer3_valid),
        .total_activation_elements(layer3_total_ae),
        .zero_activation_elements(layer3_zero_ae),
        .useful_mac_count(layer3_useful),
        .skipped_mac_count(layer3_skipped),
        .cycle_count(layer3_cycle),
        .sparsity_q(layer3_sparsity),
        .output_mem(layer3_out)
    );

    always_comb begin
        output_valid = 1'b0;
        total_activation_elements = '0;
        zero_activation_elements = '0;
        useful_mac_count = '0;
        skipped_mac_count = '0;
        cycle_count = '0;
        sparsity_q = '0;

        if (layer_id == 2'd0) begin
            output_valid = layer1_valid;
            total_activation_elements = layer1_total_ae;
            zero_activation_elements = layer1_zero_ae;
            useful_mac_count = layer1_useful;
            skipped_mac_count = layer1_skipped;
            cycle_count = layer1_cycle;
            sparsity_q = layer1_sparsity;
            for (int i = 0; i < 16*8*8; i = i + 1) output_mem[i] = layer1_out[i];
        end else if (layer_id == 2'd1) begin
            output_valid = layer2_valid;
            total_activation_elements = layer2_total_ae;
            zero_activation_elements = layer2_zero_ae;
            useful_mac_count = layer2_useful;
            skipped_mac_count = layer2_skipped;
            cycle_count = layer2_cycle;
            sparsity_q = layer2_sparsity;
            for (int i = 0; i < 32*8*8; i = i + 1) output_mem[i] = layer2_out[i];
        end else if (layer_id == 2'd2) begin
            output_valid = layer3_valid;
            total_activation_elements = layer3_total_ae;
            zero_activation_elements = layer3_zero_ae;
            useful_mac_count = layer3_useful;
            skipped_mac_count = layer3_skipped;
            cycle_count = layer3_cycle;
            sparsity_q = layer3_sparsity;
            for (int i = 0; i < 16*8*8; i = i + 1) output_mem[i] = layer3_out[i];
        end
    end
endmodule
