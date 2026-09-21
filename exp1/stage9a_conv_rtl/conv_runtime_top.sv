`timescale 1ns/1ps

// Stage 9A integration: Stage 8A observes a layer stream, then this boundary
// captures its decision before a separate loaded tensor enters convolution.
module conv_runtime_top #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer WEIGHT_WIDTH = 16,
    parameter integer ACC_WIDTH    = 48,
    parameter integer INPUT_H      = 8,
    parameter integer INPUT_W      = 8,
    parameter integer INPUT_C      = 3,
    parameter integer OUTPUT_C     = 16,
    parameter integer PE_COUNT     = 64,
    parameter integer USE_FIXED64  = 0
) (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  logic                                      layer_start,
    input  logic                                      layer_end,
    input  logic                                      sample_valid,
    input  logic signed [DATA_WIDTH-1:0]              sample_data,
    input  logic [1:0]                                layer_id,
    input  logic                                      override_enable,
    input  logic [1:0]                                resource_override_cfg,
    input  logic signed [DATA_WIDTH-1:0]              input_mem [0:INPUT_C*INPUT_H*INPUT_W-1],
    input  logic signed [WEIGHT_WIDTH-1:0]            weight_mem [0:OUTPUT_C*INPUT_C*3*3-1],
    output logic                                      stats_valid,
    output logic                                      features_valid,
    output logic                                      estimate_valid,
    output logic                                      decision_valid,
    output logic [31:0]                               element_count,
    output logic [31:0]                               zero_count,
    output logic signed [47:0]                        sum,
    output logic [63:0]                               sum_square,
    output logic [31:0]                               sparsity,
    output logic signed [31:0]                        mean,
    output logic [31:0]                               variance,
    output logic [31:0]                               degradation_hat_16,
    output logic [31:0]                               degradation_hat_32,
    output logic [31:0]                               degradation_hat_64,
    output logic [1:0]                                stage8a_resource_cfg,
    output logic                                      fallback_to_64,
    output logic [1:0]                                decision_layer_id,
    output logic                                      resource_capture_valid,
    output logic [1:0]                                stage8a_resource_at_capture,
    output logic [1:0]                                captured_resource_cfg,
    output logic [1:0]                                selected_resource_cfg,
    output logic                                      conv_start,
    output logic                                      conv_busy,
    output logic                                      conv_done,
    output logic [31:0]                               conv_cycle_count,
    output logic                                      output_valid,
    output logic                                      output_write_valid,
    output logic [9:0]                                output_index_debug,
    output logic [6:0]                                active_pe_count,
    output logic [PE_COUNT-1:0]                       pe_enable_mask,
    output logic [PE_COUNT-1:0]                       pe_valid_debug,
    output logic signed [ACC_WIDTH-1:0]               pe_accum_debug [0:PE_COUNT-1],
    output logic signed [ACC_WIDTH-1:0]               output_mem [0:OUTPUT_C*INPUT_H*INPUT_W-1]
);
    logic rst;
    logic [1:0] selected_candidate_cfg;
    logic pe_clear;
    logic signed [DATA_WIDTH-1:0] pe_activation [0:PE_COUNT-1];
    logic signed [WEIGHT_WIDTH-1:0] pe_weight [0:PE_COUNT-1];
    logic signed [ACC_WIDTH-1:0] pe_mac_next [0:PE_COUNT-1];
    logic [PE_COUNT-1:0] pe_mac_valid_unused;
    integer pe_index;

    assign rst = ~rst_n;
    always_comb begin
        if (override_enable)
            selected_candidate_cfg = resource_override_cfg;
        else
            selected_candidate_cfg = stage8a_resource_cfg;
        selected_resource_cfg = captured_resource_cfg;

        case (captured_resource_cfg)
            2'b00: active_pe_count = 7'd16;
            2'b01: active_pe_count = 7'd32;
            default: active_pe_count = 7'd64;
        endcase
        pe_enable_mask = '0;
        for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
            if (pe_index < active_pe_count)
                pe_enable_mask[pe_index] = 1'b1;
        end
    end

    // The candidate is sampled only after the actual Stage 8A decision. The
    // saved configuration feeds the scheduler for the entire convolution.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resource_capture_valid      <= 1'b0;
            stage8a_resource_at_capture <= 2'b10;
            captured_resource_cfg       <= 2'b10;
            conv_start                  <= 1'b0;
        end else begin
            resource_capture_valid <= 1'b0;
            conv_start             <= 1'b0;
            if (decision_valid && !conv_busy && !conv_start) begin
                stage8a_resource_at_capture <= stage8a_resource_cfg;
                captured_resource_cfg       <= selected_candidate_cfg;
                resource_capture_valid      <= 1'b1;
                conv_start                  <= 1'b1;
            end
        end
    end

    runtime_controller_top #(
        .DATA_W(DATA_WIDTH), .USE_FIXED64(USE_FIXED64)
    ) stage8a_i (
        .clk(clk), .rst_n(rst_n), .layer_start(layer_start), .layer_end(layer_end),
        .sample_valid(sample_valid), .sample_data(sample_data), .layer_id(layer_id),
        .stats_valid(stats_valid), .features_valid(features_valid),
        .estimate_valid(estimate_valid), .decision_valid(decision_valid),
        .element_count(element_count), .zero_count(zero_count), .sum(sum),
        .sum_square(sum_square), .sparsity(sparsity), .mean(mean), .variance(variance),
        .degradation_hat_16(degradation_hat_16),
        .degradation_hat_32(degradation_hat_32), .degradation_hat_64(degradation_hat_64),
        .resource_cfg(stage8a_resource_cfg), .fallback_to_64(fallback_to_64),
        .decision_layer_id(decision_layer_id)
    );

    conv_scheduler #(
        .DATA_WIDTH(DATA_WIDTH), .WEIGHT_WIDTH(WEIGHT_WIDTH), .ACC_WIDTH(ACC_WIDTH),
        .INPUT_H(INPUT_H), .INPUT_W(INPUT_W), .INPUT_C(INPUT_C),
        .OUTPUT_C(OUTPUT_C), .PE_COUNT(PE_COUNT)
    ) scheduler_i (
        .clk(clk), .rst(rst), .start(conv_start), .active_pe_count(active_pe_count),
        .pe_enable_mask(pe_enable_mask), .input_mem(input_mem), .weight_mem(weight_mem),
        .pe_mac_next(pe_mac_next), .pe_clear(pe_clear), .pe_valid(pe_valid_debug),
        .pe_activation(pe_activation), .pe_weight(pe_weight), .busy(conv_busy),
        .done(conv_done), .cycle_count(conv_cycle_count), .output_valid(output_valid),
        .output_write_valid(output_write_valid), .output_index_debug(output_index_debug),
        .output_mem(output_mem)
    );

    conv_pe_array #(
        .DATA_WIDTH(DATA_WIDTH), .WEIGHT_WIDTH(WEIGHT_WIDTH), .ACC_WIDTH(ACC_WIDTH),
        .PE_COUNT(PE_COUNT)
    ) pe_array_i (
        .clk(clk), .rst(rst), .pe_enable_mask(pe_enable_mask), .pe_clear(pe_clear),
        .pe_valid(pe_valid_debug), .pe_activation(pe_activation), .pe_weight(pe_weight),
        .pe_accumulator(pe_accum_debug), .pe_mac_next(pe_mac_next),
        .pe_mac_valid(pe_mac_valid_unused)
    );
endmodule
