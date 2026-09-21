`timescale 1ns/1ps

module resource_controller #(
    parameter integer FIXED_W     = 32,
    parameter integer D_MAX       = 16'd3277,
    parameter integer USE_FIXED64 = 0
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       estimate_valid,
    input  logic [FIXED_W-1:0]         degradation_hat_16,
    input  logic [FIXED_W-1:0]         degradation_hat_32,
    input  logic [FIXED_W-1:0]         degradation_hat_64,
    output logic                       decision_valid,
    output logic [1:0]                 resource_cfg,
    output logic                       fallback_to_64,
    // Appended ports preserve the original positional port ordering.
    input  logic [1:0]                 estimate_layer_id,
    output logic [1:0]                 decision_layer_id
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decision_valid    <= 1'b0;
            decision_layer_id <= '0;
            resource_cfg      <= 2'b10;
            fallback_to_64    <= 1'b0;
        end else begin
            decision_valid <= estimate_valid;
            fallback_to_64 <= 1'b0;
            if (estimate_valid) begin
                decision_layer_id <= estimate_layer_id;
                if (USE_FIXED64 != 0) begin
                    resource_cfg <= 2'b10;
                end else if (degradation_hat_16 <= D_MAX) begin
                    resource_cfg <= 2'b00;
                end else if (degradation_hat_32 <= D_MAX) begin
                    resource_cfg <= 2'b01;
                end else begin
                    // D64 is not compared: it is only the prototype baseline.
                    resource_cfg   <= 2'b10;
                    fallback_to_64 <= 1'b1;
                end
            end
        end
    end
endmodule
