`timescale 1ns/1ps

// Stage 9B integration top.  Host tensor words cross tensor_loader before
// entering behavioral buffers; the convolution engine never sees host arrays.
module conv_dataflow_top #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer WEIGHT_WIDTH = 16,
    parameter integer ACC_WIDTH    = 48,
    parameter integer INPUT_H      = 8,
    parameter integer INPUT_W      = 8,
    parameter integer INPUT_C      = 3,
    parameter integer OUTPUT_C     = 16,
    parameter integer PE_COUNT     = 64
) (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  logic                                      workload_start,
    input  logic                                      load_valid,
    output logic                                      load_ready,
    input  logic signed [DATA_WIDTH-1:0]              load_data,
    input  logic [1:0]                                load_type,
    input  logic [9:0]                                load_index,
    output logic                                      load_done,
    input  logic [1:0]                                layer_id,
    input  logic                                      override_enable,
    input  logic [1:0]                                resource_override_cfg,
    output logic                                      output_stream_valid,
    input  logic                                      output_stream_ready,
    output logic signed [ACC_WIDTH-1:0]               output_stream_data,
    output logic [9:0]                                output_stream_index,
    output logic                                      output_stream_last,
    output logic                                      output_stream_done,
    output logic                                      input_loaded,
    output logic                                      weight_loaded,
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
    output logic [6:0]                                active_pe_count,
    output logic [PE_COUNT-1:0]                       pe_enable_mask,
    output logic [PE_COUNT-1:0]                       pe_valid_debug,
    output logic signed [ACC_WIDTH-1:0]               pe_accum_debug [0:PE_COUNT-1],
    output logic                                      compute_start,
    output logic                                      compute_busy,
    output logic                                      compute_done,
    output logic [31:0]                               schedule_cycle_count,
    output logic [31:0]                               mac_cycle_count,
    output logic [31:0]                               active_pe_mac_count,
    output logic                                      output_write_valid,
    output logic [9:0]                                output_write_index,
    output logic signed [ACC_WIDTH-1:0]               output_write_data,
    output logic [3:0]                                controller_state,
    output logic [31:0]                               input_load_cycles,
    output logic [31:0]                               weight_load_cycles,
    output logic [31:0]                               monitor_cycles,
    output logic [31:0]                               decision_wait_cycles,
    output logic [31:0]                               compute_cycles,
    output logic [31:0]                               output_stream_cycles,
    output logic [31:0]                               total_cycles,
    output logic [31:0]                               input_buffer_reads,
    output logic [31:0]                               input_buffer_writes,
    output logic [31:0]                               weight_buffer_reads,
    output logic [31:0]                               weight_buffer_writes,
    output logic [31:0]                               output_buffer_writes,
    output logic [31:0]                               output_stream_reads
);
    localparam integer INPUT_ELEMENTS  = INPUT_C * INPUT_H * INPUT_W;
    localparam integer WEIGHT_ELEMENTS = OUTPUT_C * INPUT_C * 3 * 3;

    logic rst;
    logic load_enable;
    logic input_buffer_clear, weight_buffer_clear, output_buffer_clear;
    logic input_write_valid, weight_write_valid;
    logic [7:0] input_write_index;
    logic [8:0] weight_write_index;
    logic signed [DATA_WIDTH-1:0] input_write_data, weight_write_data;
    logic input_load_fire, weight_load_fire;
    logic monitor_read_enable;
    logic [7:0] monitor_read_index;
    logic signed [DATA_WIDTH-1:0] monitor_read_data;
    logic layer_start, sample_valid, layer_end;
    logic [1:0] selected_candidate_cfg;
    logic output_stream_start;
    logic signed [DATA_WIDTH-1:0] input_tensor [0:INPUT_ELEMENTS-1];
    logic signed [WEIGHT_WIDTH-1:0] weight_tensor [0:WEIGHT_ELEMENTS-1];
    logic [15:0] compute_input_read_actions;
    logic [15:0] compute_weight_read_actions;
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

    tensor_loader #(
        .DATA_WIDTH(DATA_WIDTH), .INPUT_ELEMENTS(INPUT_ELEMENTS), .WEIGHT_ELEMENTS(WEIGHT_ELEMENTS)
    ) tensor_loader_i (
        .load_valid(load_valid), .load_ready(load_ready), .load_data(load_data),
        .load_type(load_type), .load_index(load_index), .load_enable(load_enable),
        .input_loaded(input_loaded), .weight_loaded(weight_loaded),
        .input_write_valid(input_write_valid), .input_write_index(input_write_index),
        .input_write_data(input_write_data), .weight_write_valid(weight_write_valid),
        .weight_write_index(weight_write_index), .weight_write_data(weight_write_data),
        .input_load_fire(input_load_fire), .weight_load_fire(weight_load_fire), .load_done(load_done)
    );

    input_buffer #(.DATA_WIDTH(DATA_WIDTH), .ELEMENTS(INPUT_ELEMENTS), .PE_COUNT(PE_COUNT)) input_buffer_i (
        .clk(clk), .rst_n(rst_n), .clear(input_buffer_clear),
        .write_valid(input_write_valid), .write_index(input_write_index), .write_data(input_write_data),
        .tensor_data(input_tensor), .compute_read_actions(compute_input_read_actions),
        .monitor_read_enable(monitor_read_enable),
        .monitor_read_index(monitor_read_index), .monitor_read_data(monitor_read_data),
        .load_complete(input_loaded), .write_count(input_buffer_writes), .read_count(input_buffer_reads)
    );

    weight_buffer #(.DATA_WIDTH(WEIGHT_WIDTH), .ELEMENTS(WEIGHT_ELEMENTS), .PE_COUNT(PE_COUNT)) weight_buffer_i (
        .clk(clk), .rst_n(rst_n), .clear(weight_buffer_clear),
        .write_valid(weight_write_valid), .write_index(weight_write_index), .write_data(weight_write_data),
        .tensor_data(weight_tensor), .compute_read_actions(compute_weight_read_actions),
        .load_complete(weight_loaded), .write_count(weight_buffer_writes), .read_count(weight_buffer_reads)
    );

    output_buffer #(.ACC_WIDTH(ACC_WIDTH), .ELEMENTS(OUTPUT_C*INPUT_H*INPUT_W)) output_buffer_i (
        .clk(clk), .rst_n(rst_n), .clear(output_buffer_clear),
        .write_valid(output_write_valid), .write_index(output_write_index), .write_data(output_write_data),
        .stream_start(output_stream_start), .output_stream_valid(output_stream_valid),
        .output_stream_ready(output_stream_ready), .output_stream_data(output_stream_data),
        .output_stream_index(output_stream_index), .output_stream_last(output_stream_last),
        .output_stream_done(output_stream_done), .write_count(output_buffer_writes),
        .stream_read_count(output_stream_reads)
    );

    // Stage 8A remains an unmodified monitored-control block.  Stage 9B only
    // provides its source samples from the loaded input buffer.
    runtime_controller_top #(.DATA_W(DATA_WIDTH)) stage8a_i (
        .clk(clk), .rst_n(rst_n), .layer_start(layer_start), .layer_end(layer_end),
        .sample_valid(sample_valid), .sample_data(monitor_read_data), .layer_id(layer_id),
        .stats_valid(stats_valid), .features_valid(features_valid), .estimate_valid(estimate_valid),
        .decision_valid(decision_valid), .element_count(element_count), .zero_count(zero_count),
        .sum(sum), .sum_square(sum_square), .sparsity(sparsity), .mean(mean), .variance(variance),
        .degradation_hat_16(degradation_hat_16), .degradation_hat_32(degradation_hat_32),
        .degradation_hat_64(degradation_hat_64), .resource_cfg(stage8a_resource_cfg),
        .fallback_to_64(fallback_to_64), .decision_layer_id(decision_layer_id)
    );

    dataflow_controller #(.INPUT_ELEMENTS(INPUT_ELEMENTS)) dataflow_controller_i (
        .clk(clk), .rst_n(rst_n), .workload_start(workload_start),
        .input_loaded(input_loaded), .weight_loaded(weight_loaded),
        .input_load_fire(input_load_fire), .weight_load_fire(weight_load_fire),
        .decision_valid(decision_valid), .stage8a_resource_cfg(stage8a_resource_cfg),
        .selected_candidate_cfg(selected_candidate_cfg), .compute_busy(compute_busy),
        .compute_done(compute_done), .output_stream_valid(output_stream_valid),
        .output_stream_ready(output_stream_ready), .output_stream_done(output_stream_done),
        .load_enable(load_enable), .input_buffer_clear(input_buffer_clear),
        .weight_buffer_clear(weight_buffer_clear), .output_buffer_clear(output_buffer_clear),
        .monitor_read_enable(monitor_read_enable), .monitor_read_index(monitor_read_index),
        .layer_start(layer_start), .sample_valid(sample_valid), .layer_end(layer_end),
        .compute_start(compute_start), .output_stream_start(output_stream_start),
        .resource_capture_valid(resource_capture_valid),
        .stage8a_resource_at_capture(stage8a_resource_at_capture),
        .captured_resource_cfg(captured_resource_cfg), .state_debug(controller_state),
        .input_load_cycles(input_load_cycles), .weight_load_cycles(weight_load_cycles),
        .monitor_cycles(monitor_cycles), .decision_wait_cycles(decision_wait_cycles),
        .compute_cycles(compute_cycles), .output_stream_cycles(output_stream_cycles),
        .total_cycles(total_cycles)
    );

    conv_buffered_scheduler #(
        .DATA_WIDTH(DATA_WIDTH), .WEIGHT_WIDTH(WEIGHT_WIDTH), .ACC_WIDTH(ACC_WIDTH),
        .INPUT_H(INPUT_H), .INPUT_W(INPUT_W), .INPUT_C(INPUT_C), .OUTPUT_C(OUTPUT_C), .PE_COUNT(PE_COUNT)
    ) scheduler_i (
        .clk(clk), .rst(rst), .start(compute_start), .active_pe_count(active_pe_count),
        .pe_enable_mask(pe_enable_mask), .input_tensor(input_tensor), .weight_tensor(weight_tensor),
        .input_read_actions(compute_input_read_actions), .weight_read_actions(compute_weight_read_actions),
        .pe_clear(pe_clear), .pe_valid(pe_valid_debug),
        .pe_activation(pe_activation), .pe_weight(pe_weight), .busy(compute_busy), .done(compute_done),
        .schedule_cycle_count(schedule_cycle_count), .mac_cycle_count(mac_cycle_count),
        .active_pe_mac_count(active_pe_mac_count), .output_write_valid(output_write_valid),
        .output_write_index(output_write_index), .output_write_data(output_write_data)
    );

    conv_pe_array #(
        .DATA_WIDTH(DATA_WIDTH), .WEIGHT_WIDTH(WEIGHT_WIDTH), .ACC_WIDTH(ACC_WIDTH), .PE_COUNT(PE_COUNT)
    ) pe_array_i (
        .clk(clk), .rst(rst), .pe_enable_mask(pe_enable_mask), .pe_clear(pe_clear),
        .pe_valid(pe_valid_debug), .pe_activation(pe_activation), .pe_weight(pe_weight),
        .pe_accumulator(pe_accum_debug), .pe_mac_next(pe_mac_next), .pe_mac_valid(pe_mac_valid_unused)
    );
endmodule
