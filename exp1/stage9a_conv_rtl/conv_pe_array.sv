`timescale 1ns/1ps

// Exactly one physical 64-PE maximum array. Resource gating is supplied by
// conv_runtime_top and never creates a separate smaller array.
module conv_pe_array #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer WEIGHT_WIDTH = 16,
    parameter integer ACC_WIDTH    = 48,
    parameter integer PE_COUNT     = 64
) (
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic [PE_COUNT-1:0]                       pe_enable_mask,
    input  logic                                      pe_clear,
    input  logic [PE_COUNT-1:0]                       pe_valid,
    input  logic signed [DATA_WIDTH-1:0]              pe_activation [0:PE_COUNT-1],
    input  logic signed [WEIGHT_WIDTH-1:0]            pe_weight [0:PE_COUNT-1],
    output logic signed [ACC_WIDTH-1:0]               pe_accumulator [0:PE_COUNT-1],
    output logic signed [ACC_WIDTH-1:0]               pe_mac_next [0:PE_COUNT-1],
    output logic [PE_COUNT-1:0]                       pe_mac_valid
);
    genvar pe_index;
    generate
        for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin : gen_conv_pe
            conv_pe #(
                .DATA_WIDTH(DATA_WIDTH), .WEIGHT_WIDTH(WEIGHT_WIDTH), .ACC_WIDTH(ACC_WIDTH)
            ) pe_i (
                .clk(clk), .rst(rst), .enable(pe_enable_mask[pe_index]),
                .clear(pe_clear), .valid(pe_valid[pe_index]),
                .activation(pe_activation[pe_index]), .weight(pe_weight[pe_index]),
                .accumulator(pe_accumulator[pe_index]), .mac_next(pe_mac_next[pe_index]),
                .mac_valid(pe_mac_valid[pe_index])
            );
        end
    endgenerate
endmodule
