`timescale 1ns/1ps

module multilayer_cnn_top #(
    parameter integer DATA_W   = 16,
    parameter integer WEIGHT_W = 16,
    parameter integer ACC_W    = 48,
    parameter integer INPUT_C  = 3,
    parameter integer INPUT_H  = 8,
    parameter integer INPUT_W  = 8,
    parameter integer OUT_C    = 16,
    parameter integer KERNEL   = 3,
    parameter integer PAD      = 1,
    parameter integer PE_COUNT = 64
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start_network,
    input  logic                         override_enable,
    input  logic [1:0]                   layer1_cfg,
    input  logic [1:0]                   layer2_cfg,
    input  logic [1:0]                   layer3_cfg,
    input  logic signed [DATA_W-1:0]     input_tensor [0:INPUT_C*INPUT_H*INPUT_W-1],
    input  logic signed [WEIGHT_W-1:0]   w1 [0:OUT_C*INPUT_C*KERNEL*KERNEL-1],
    input  logic signed [WEIGHT_W-1:0]   w2 [0:OUT_C*INPUT_C*KERNEL*KERNEL-1],
    input  logic signed [WEIGHT_W-1:0]   w3 [0:OUT_C*INPUT_C*KERNEL*KERNEL-1],
    output logic [1:0]                   conv1_cfg,
    output logic [1:0]                   conv2_cfg,
    output logic [1:0]                   conv3_cfg,
    output logic                         network_done,
    output logic                         final_output_valid,
    output logic signed [ACC_W-1:0]      conv1_out [0:OUT_C*INPUT_H*INPUT_W-1],
    output logic signed [DATA_W-1:0]     pool1_out [0:OUT_C*(INPUT_H/2)*(INPUT_W/2)-1],
    output logic signed [ACC_W-1:0]      conv2_out [0:OUT_C*(INPUT_H/2)*(INPUT_W/2)-1],
    output logic signed [DATA_W-1:0]     pool2_out [0:OUT_C*((INPUT_H/2)/2)*((INPUT_W/2)/2)-1],
    output logic signed [ACC_W-1:0]      conv3_out [0:OUT_C*((INPUT_H/2)/2)*((INPUT_W/2)/2)-1]
);
    assign conv1_cfg = layer1_cfg;
    assign conv2_cfg = layer2_cfg;
    assign conv3_cfg = layer3_cfg;
    assign network_done = start_network ? 1'b0 : 1'b0;
    assign final_output_valid = 1'b0;
    assign conv1_out[0] = '0;
    assign pool1_out[0] = '0;
    assign conv2_out[0] = '0;
    assign pool2_out[0] = '0;
    assign conv3_out[0] = '0;
endmodule
