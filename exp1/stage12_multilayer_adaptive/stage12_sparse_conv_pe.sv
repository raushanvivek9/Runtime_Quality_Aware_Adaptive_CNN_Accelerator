`timescale 1ns/1ps

module stage12_sparse_conv_pe #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer WEIGHT_WIDTH = 16,
    parameter integer ACC_WIDTH    = 48
) (
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic                                      enable,
    input  logic                                      valid,
    input  logic signed [DATA_WIDTH-1:0]              activation,
    input  logic signed [WEIGHT_WIDTH-1:0]            weight,
    input  logic signed [ACC_WIDTH-1:0]               acc_in,
    output logic signed [ACC_WIDTH-1:0]               acc_out,
    output logic                                      mac_valid
);
    logic signed [DATA_WIDTH+WEIGHT_WIDTH-1:0] product_wide;
    logic signed [ACC_WIDTH-1:0] product_ext;

    always_comb begin
        product_wide = activation * weight;
        product_ext = product_wide;
        if (valid && enable) begin
            acc_out = acc_in + product_ext;
        end else begin
            acc_out = acc_in;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            mac_valid <= 1'b0;
        end else begin
            mac_valid <= enable && valid;
        end
    end
endmodule
