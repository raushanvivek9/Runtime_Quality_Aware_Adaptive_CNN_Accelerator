`timescale 1ns/1ps

module runtime_controller_top #(
    parameter integer DATA_W      = 16,
    parameter integer COUNT_W     = 32,
    parameter integer SUM_W       = 48,
    parameter integer SUMSQ_W     = 64,
    parameter integer FIXED_W     = 32,
    parameter integer FRAC_W      = 16,
    parameter integer USE_FIXED64 = 0
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         layer_start,
    input  logic                         layer_end,
    input  logic                         sample_valid,
    input  logic signed [DATA_W-1:0]     sample_data,
    output logic                         stats_valid,
    output logic                         features_valid,
    output logic                         estimate_valid,
    output logic                         decision_valid,
    output logic [COUNT_W-1:0]           element_count,
    output logic [COUNT_W-1:0]           zero_count,
    output logic signed [SUM_W-1:0]      sum,
    output logic [SUMSQ_W-1:0]           sum_square,
    output logic [FIXED_W-1:0]           sparsity,
    output logic signed [FIXED_W-1:0]    mean,
    output logic [FIXED_W-1:0]           variance,
    output logic [FIXED_W-1:0]           degradation_hat_16,
    output logic [FIXED_W-1:0]           degradation_hat_32,
    output logic [FIXED_W-1:0]           degradation_hat_64,
    output logic [1:0]                   resource_cfg,
    output logic                         fallback_to_64,
    // Appended ports preserve the original positional port ordering.
    input  logic [1:0]                   layer_id,
    output logic [1:0]                   decision_layer_id
);
    logic [1:0] stats_layer_id;
    logic [1:0] features_layer_id;
    logic [1:0] estimate_layer_id;

    runtime_monitor #(
        .DATA_W(DATA_W), .COUNT_W(COUNT_W), .SUM_W(SUM_W), .SUMSQ_W(SUMSQ_W)
    ) monitor_i (
        .clk(clk), .rst_n(rst_n), .layer_start(layer_start),
        .layer_end(layer_end), .sample_valid(sample_valid),
        .sample_data(sample_data), .layer_id(layer_id), .stats_valid(stats_valid),
        .element_count(element_count), .zero_count(zero_count), .sum(sum),
        .sum_square(sum_square), .stats_layer_id(stats_layer_id)
    );

    feature_calculator #(
        .COUNT_W(COUNT_W), .SUM_W(SUM_W), .SUMSQ_W(SUMSQ_W),
        .FIXED_W(FIXED_W), .FRAC_W(FRAC_W)
    ) features_i (
        .stats_valid(stats_valid), .stats_layer_id(stats_layer_id),
        .element_count(element_count), .zero_count(zero_count), .sum(sum),
        .sum_square(sum_square), .features_valid(features_valid),
        .features_layer_id(features_layer_id), .sparsity(sparsity), .mean(mean),
        .variance(variance)
    );

    quality_estimator #(.FIXED_W(FIXED_W), .FRAC_W(FRAC_W)) estimator_i (
        .clk(clk), .rst_n(rst_n), .features_valid(features_valid),
        .features_layer_id(features_layer_id), .sparsity(sparsity), .mean(mean),
        .variance(variance), .estimate_valid(estimate_valid),
        .estimate_layer_id(estimate_layer_id),
        .degradation_hat_16(degradation_hat_16),
        .degradation_hat_32(degradation_hat_32),
        .degradation_hat_64(degradation_hat_64)
    );

    resource_controller #(.FIXED_W(FIXED_W), .USE_FIXED64(USE_FIXED64)) controller_i (
        .clk(clk), .rst_n(rst_n), .estimate_valid(estimate_valid),
        .estimate_layer_id(estimate_layer_id),
        .degradation_hat_16(degradation_hat_16),
        .degradation_hat_32(degradation_hat_32),
        .degradation_hat_64(degradation_hat_64), .decision_valid(decision_valid),
        .decision_layer_id(decision_layer_id), .resource_cfg(resource_cfg),
        .fallback_to_64(fallback_to_64)
    );
endmodule
