`timescale 1ns/1ps

module conv_layer_wrapper #(
    parameter integer DATA_W      = 16,
    parameter integer WEIGHT_W    = 16,
    parameter integer ACC_W       = 48,
    parameter integer INPUT_C     = 3,
    parameter integer INPUT_H     = 8,
    parameter integer INPUT_W     = 8,
    parameter integer OUTPUT_C    = 16,
    parameter integer KERNEL      = 3,
    parameter integer PAD         = 1,
    parameter integer SCALE_BITS  = 32,
    parameter integer PE_COUNT    = 64
) (
    input  logic                                         clk,
    input  logic                                         rst_n,
    input  logic                                         start,
    input  logic [1:0]                                   layer_id,
    input  logic                                         override_enable,
    input  logic [1:0]                                   resource_override_cfg,
    input  logic signed [DATA_W-1:0]                     input_tensor [0:INPUT_C*INPUT_H*INPUT_W-1],
    input  logic signed [WEIGHT_W-1:0]                   weight_tensor [0:OUTPUT_C*INPUT_C*KERNEL*KERNEL-1],
    output logic                                         decision_valid,
    output logic [1:0]                                   resource_cfg,
    output logic [1:0]                                   captured_resource_cfg,
    output logic [1:0]                                   decision_layer_id,
    output logic                                         conv_start,
    output logic                                         conv_busy,
    output logic                                         conv_done,
    output logic                                         output_valid,
    output logic [PE_COUNT-1:0]                          pe_enable_mask,
    output logic [6:0]                                   active_pe_count,
    output logic signed [ACC_W-1:0]                      output_mem [0:OUTPUT_C*INPUT_H*INPUT_W-1],
    output logic [31:0]                                  cycle_count,
    output logic                                         layer_monitor_done
);

    localparam integer INPUT_ELEMS = INPUT_C * INPUT_H * INPUT_W;
    localparam integer WEIGHT_ELEMS = OUTPUT_C * INPUT_C * KERNEL * KERNEL;
    localparam integer OUTPUT_ELEMS = OUTPUT_C * INPUT_H * INPUT_W;

    typedef enum logic [2:0] { WRAP_IDLE=3'd0, WRAP_STREAM=3'd1, WRAP_END=3'd2, WRAP_WAIT=3'd3 } wrap_state_t;

    wrap_state_t wrapper_state;
    logic [31:0] sample_index;
    logic        layer_end_issued;
    logic layer_start_pulse;
    logic sample_valid_i;
    logic layer_end_i;
    logic signed [DATA_W-1:0] sample_data_i;
    logic [1:0] local_resource_cfg;
    logic [1:0] local_captured_cfg;
    logic [1:0] local_decision_layer_id;
    logic [1:0] stage8a_decision_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wrapper_state     <= WRAP_IDLE;
            layer_start_pulse <= 1'b0;
            sample_valid_i    <= 1'b0;
            layer_end_i       <= 1'b0;
            sample_data_i     <= '0;
            sample_index      <= '0;
            layer_end_issued  <= 1'b0;
            layer_monitor_done <= 1'b0;
        end else begin
            layer_start_pulse <= 1'b0;
            sample_valid_i    <= 1'b0;
            layer_end_i       <= 1'b0;
            sample_data_i     <= '0;

            case (wrapper_state)
                WRAP_IDLE: begin
                    if (start) begin
                        layer_start_pulse <= 1'b1;
                        sample_index      <= '0;
                        layer_end_issued  <= 1'b0;
                        layer_monitor_done <= 1'b0;
                        wrapper_state     <= WRAP_STREAM;
                    end
                end

                WRAP_STREAM: begin
                    if (start) begin
                        layer_start_pulse <= 1'b1;
                        sample_index      <= '0;
                        layer_end_issued  <= 1'b0;
                        layer_monitor_done <= 1'b0;
                        wrapper_state     <= WRAP_STREAM;
                    end else if (sample_index < INPUT_ELEMS) begin
                        sample_valid_i <= 1'b1;
                        sample_data_i  <= input_tensor[sample_index];
                        sample_index   <= sample_index + 1;
                        if (sample_index == INPUT_ELEMS - 1) begin
                            wrapper_state <= WRAP_END;
                            sample_valid_i <= 1'b1;
                            sample_data_i  <= input_tensor[sample_index];
                        end
                    end else begin
                        wrapper_state <= WRAP_END;
                    end
                end

                WRAP_END: begin
                    sample_valid_i <= 1'b0;
                    layer_end_i    <= 1'b1;
                    layer_end_issued <= 1'b1;
                    layer_monitor_done <= 1'b1;
                    wrapper_state <= WRAP_WAIT;
                end

                WRAP_WAIT: begin
                    sample_valid_i <= 1'b0;
                    layer_end_i    <= 1'b0;
                    layer_end_issued <= 1'b1;
                    layer_monitor_done <= 1'b1;
                    if (start) begin
                        layer_start_pulse <= 1'b1;
                        sample_index      <= '0;
                        layer_end_issued  <= 1'b0;
                        layer_monitor_done <= 1'b0;
                        wrapper_state     <= WRAP_STREAM;
                    end else begin
                        wrapper_state <= WRAP_IDLE;
                    end
                end

                default: begin
                    wrapper_state <= WRAP_IDLE;
                end
            endcase

        end
    end

    conv_runtime_top #(
        .DATA_WIDTH(DATA_W),
        .WEIGHT_WIDTH(WEIGHT_W),
        .ACC_WIDTH(ACC_W),
        .INPUT_H(INPUT_H),
        .INPUT_W(INPUT_W),
        .INPUT_C(INPUT_C),
        .OUTPUT_C(OUTPUT_C),
        .PE_COUNT(PE_COUNT),
        .USE_FIXED64(0)
    ) conv_runtime_i (
        .clk(clk),
        .rst_n(rst_n),
        .layer_start(layer_start_pulse),
        .layer_end(layer_end_i),
        .sample_valid(sample_valid_i),
        .sample_data(sample_data_i),
        .layer_id(layer_id),
        .override_enable(override_enable),
        .resource_override_cfg(resource_override_cfg),
        .input_mem(input_tensor),
        .weight_mem(weight_tensor),
        .decision_valid(decision_valid),
        .stage8a_resource_cfg(resource_cfg),
        .captured_resource_cfg(captured_resource_cfg),
        .decision_layer_id(decision_layer_id),
        .conv_start(conv_start),
        .conv_busy(conv_busy),
        .conv_done(conv_done),
        .output_valid(output_valid),
        .pe_enable_mask(pe_enable_mask),
        .active_pe_count(active_pe_count),
        .output_mem(output_mem),
        .conv_cycle_count(cycle_count)
    );
endmodule
