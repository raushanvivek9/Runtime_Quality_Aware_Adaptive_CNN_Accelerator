`timescale 1ns/1ps

// End-to-end Stage 8C boundary. Existing Stage 8A and Stage 8B modules are
// instantiated unchanged; this module only captures a valid Stage 8A decision
// and starts the existing Stage 8B compute top with that stable configuration.
module integration_top #(
    parameter integer DATA_W      = 16,
    parameter integer COUNT_W     = 32,
    parameter integer SUM_W       = 48,
    parameter integer SUMSQ_W     = 64,
    parameter integer FIXED_W     = 32,
    parameter integer FRAC_W      = 16,
    parameter integer ACC_WIDTH   = 32,
    parameter integer MATRIX_DIM  = 8,
    parameter integer PE_COUNT    = 64,
    parameter integer USE_FIXED64 = 0
) (
    input  logic                                  clk,
    input  logic                                  rst_n,
    input  logic                                  layer_start,
    input  logic                                  layer_end,
    input  logic                                  sample_valid,
    input  logic signed [DATA_W-1:0]              sample_data,
    input  logic [1:0]                            layer_id,
    input  logic signed [DATA_W-1:0]              matrix_a [0:PE_COUNT-1],
    input  logic signed [DATA_W-1:0]              matrix_b [0:PE_COUNT-1],

    // Explicit test-only integration-boundary override. It never changes the
    // unchanged Stage 8A output and is used only after decision_valid arrives.
    input  logic                                  force_resource_enable,
    input  logic [1:0]                            force_resource_cfg,

    output logic                                  stats_valid,
    output logic                                  features_valid,
    output logic                                  estimate_valid,
    output logic                                  decision_valid,
    output logic [COUNT_W-1:0]                    element_count,
    output logic [COUNT_W-1:0]                    zero_count,
    output logic signed [SUM_W-1:0]               sum,
    output logic [SUMSQ_W-1:0]                    sum_square,
    output logic [FIXED_W-1:0]                    sparsity,
    output logic signed [FIXED_W-1:0]             mean,
    output logic [FIXED_W-1:0]                    variance,
    output logic [FIXED_W-1:0]                    degradation_hat_16,
    output logic [FIXED_W-1:0]                    degradation_hat_32,
    output logic [FIXED_W-1:0]                    degradation_hat_64,
    output logic [1:0]                            stage8a_resource_cfg,
    output logic                                  fallback_to_64,
    output logic [1:0]                            decision_layer_id,

    output logic                                  resource_capture_valid,
    output logic [1:0]                            stage8a_resource_at_capture,
    output logic [1:0]                            captured_resource_cfg,
    output logic [1:0]                            selected_resource_cfg,
    output logic                                  compute_start,
    output logic                                  compute_busy,
    output logic                                  compute_done,
    output logic [31:0]                           compute_cycle_count,
    output logic                                  result_valid,
    output logic signed [ACC_WIDTH-1:0]           result_matrix [0:PE_COUNT-1],
    output logic [6:0]                            active_pe_count,
    output logic [PE_COUNT-1:0]                   pe_enable_debug,
    output logic [PE_COUNT-1:0]                   pe_valid_debug,
    output logic signed [ACC_WIDTH-1:0]           pe_accum_debug [0:PE_COUNT-1],
    output logic [1:0]                            stage8b_captured_resource_cfg
);
    logic stage8b_rst;

    assign stage8b_rst = ~rst_n;
    always_comb begin
        if (force_resource_enable)
            selected_resource_cfg = force_resource_cfg;
        else
            selected_resource_cfg = stage8a_resource_cfg;
    end

    // Capture only after a real Stage 8A decision. Stage 8B is fed the
    // registered captured value, not the live Stage 8A/override selection.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resource_capture_valid      <= 1'b0;
            stage8a_resource_at_capture <= 2'b10;
            captured_resource_cfg       <= 2'b10;
            compute_start               <= 1'b0;
        end else begin
            resource_capture_valid <= 1'b0;
            compute_start          <= 1'b0;
            if (decision_valid && !compute_busy && !compute_start) begin
                stage8a_resource_at_capture <= stage8a_resource_cfg;
                captured_resource_cfg       <= selected_resource_cfg;
                resource_capture_valid      <= 1'b1;
                compute_start               <= 1'b1;
            end
        end
    end

    runtime_controller_top #(
        .DATA_W(DATA_W), .COUNT_W(COUNT_W), .SUM_W(SUM_W), .SUMSQ_W(SUMSQ_W),
        .FIXED_W(FIXED_W), .FRAC_W(FRAC_W), .USE_FIXED64(USE_FIXED64)
    ) stage8a_i (
        .clk(clk), .rst_n(rst_n), .layer_start(layer_start), .layer_end(layer_end),
        .sample_valid(sample_valid), .sample_data(sample_data), .layer_id(layer_id),
        .stats_valid(stats_valid), .features_valid(features_valid),
        .estimate_valid(estimate_valid), .decision_valid(decision_valid),
        .element_count(element_count), .zero_count(zero_count), .sum(sum),
        .sum_square(sum_square), .sparsity(sparsity), .mean(mean), .variance(variance),
        .degradation_hat_16(degradation_hat_16),
        .degradation_hat_32(degradation_hat_32),
        .degradation_hat_64(degradation_hat_64), .resource_cfg(stage8a_resource_cfg),
        .fallback_to_64(fallback_to_64), .decision_layer_id(decision_layer_id)
    );

    adaptive_compute_top #(
        .DATA_WIDTH(DATA_W), .ACC_WIDTH(ACC_WIDTH),
        .MATRIX_DIM(MATRIX_DIM), .PE_COUNT(PE_COUNT)
    ) stage8b_i (
        .clk(clk), .rst(stage8b_rst), .start(compute_start),
        .resource_cfg(captured_resource_cfg), .matrix_a(matrix_a), .matrix_b(matrix_b),
        .busy(compute_busy), .done(compute_done), .cycle_count(compute_cycle_count),
        .result_valid(result_valid), .result_matrix(result_matrix),
        .active_pe_count(active_pe_count), .pe_enable_debug(pe_enable_debug),
        .pe_valid_debug(pe_valid_debug), .pe_accum_debug(pe_accum_debug),
        .captured_resource_cfg(stage8b_captured_resource_cfg)
    );
endmodule
