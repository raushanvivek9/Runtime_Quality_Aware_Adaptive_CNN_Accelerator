`timescale 1ns/1ps

// One registered signed multiply-accumulate processing element.
module pe_mac #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ACC_WIDTH  = 32
) (
    input  logic                              clk,
    input  logic                              rst,
    input  logic                              enable,
    input  logic                              valid,
    input  logic signed [DATA_WIDTH-1:0]      activation,
    input  logic signed [DATA_WIDTH-1:0]      weight,
    input  logic signed [ACC_WIDTH-1:0]       acc_in,
    output logic signed [ACC_WIDTH-1:0]       acc_out,
    output logic signed [ACC_WIDTH-1:0]       mac_next,
    output logic                              mac_valid
);
    // Operands are explicitly extended before multiplication. The lower
    // 2*DATA_WIDTH result holds the complete product of the original inputs.
    logic signed [(2*DATA_WIDTH)-1:0] activation_operand;
    logic signed [(2*DATA_WIDTH)-1:0] weight_operand;
    logic signed [(2*DATA_WIDTH)-1:0] product_wide;
    logic signed [ACC_WIDTH-1:0]      product_extended;

    always_comb begin
        activation_operand = activation;
        weight_operand     = weight;
        product_wide       = activation_operand * weight_operand;
        product_extended   = product_wide;
        mac_next           = acc_in + product_extended;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            acc_out   <= '0;
            mac_valid <= 1'b0;
        end else begin
            mac_valid <= 1'b0;
            if (enable && valid) begin
                acc_out   <= mac_next;
                mac_valid <= 1'b1;
            end
        end
    end
endmodule
