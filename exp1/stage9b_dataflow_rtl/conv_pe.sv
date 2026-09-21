`timescale 1ns/1ps

// One signed MAC PE.  Resource gating controls both clearing and MAC updates;
// disabled PEs therefore remain inactive throughout a workload.
module conv_pe #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer WEIGHT_WIDTH = 16,
    parameter integer ACC_WIDTH    = 48
) (
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic                                      enable,
    input  logic                                      clear,
    input  logic                                      valid,
    input  logic signed [DATA_WIDTH-1:0]              activation,
    input  logic signed [WEIGHT_WIDTH-1:0]            weight,
    output logic signed [ACC_WIDTH-1:0]               accumulator,
    output logic signed [ACC_WIDTH-1:0]               mac_next,
    output logic                                      mac_valid
);
    localparam integer OPERAND_WIDTH = DATA_WIDTH + WEIGHT_WIDTH;
    logic signed [OPERAND_WIDTH-1:0] activation_operand;
    logic signed [OPERAND_WIDTH-1:0] weight_operand;
    logic signed [(2*OPERAND_WIDTH)-1:0] product_wide;
    logic signed [ACC_WIDTH-1:0] product_extended;

    always_comb begin
        activation_operand = activation;
        weight_operand     = weight;
        product_wide       = activation_operand * weight_operand;
        product_extended   = product_wide;
        mac_next           = accumulator + product_extended;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            accumulator <= '0;
            mac_valid   <= 1'b0;
        end else begin
            mac_valid <= 1'b0;
            if (enable && clear)
                accumulator <= '0;
            else if (enable && valid) begin
                accumulator <= mac_next;
                mac_valid   <= 1'b1;
            end
        end
    end
endmodule
