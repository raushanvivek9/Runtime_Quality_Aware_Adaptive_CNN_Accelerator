`timescale 1ns/1ps

// The Stage 9B control boundary: loading, monitoring, decision capture,
// compute, and output streaming are deliberately separate FSM phases.
module dataflow_controller #(
    parameter integer INPUT_ELEMENTS = 192
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          workload_start,
    input  logic          input_loaded,
    input  logic          weight_loaded,
    input  logic          input_load_fire,
    input  logic          weight_load_fire,
    input  logic          decision_valid,
    input  logic [1:0]    stage8a_resource_cfg,
    input  logic [1:0]    selected_candidate_cfg,
    input  logic          compute_busy,
    input  logic          compute_done,
    input  logic          output_stream_valid,
    input  logic          output_stream_ready,
    input  logic          output_stream_done,
    output logic          load_enable,
    output logic          input_buffer_clear,
    output logic          weight_buffer_clear,
    output logic          output_buffer_clear,
    output logic          monitor_read_enable,
    output logic [7:0]    monitor_read_index,
    output logic          layer_start,
    output logic          sample_valid,
    output logic          layer_end,
    output logic          compute_start,
    output logic          output_stream_start,
    output logic          resource_capture_valid,
    output logic [1:0]    stage8a_resource_at_capture,
    output logic [1:0]    captured_resource_cfg,
    output logic [3:0]    state_debug,
    output logic [31:0]   input_load_cycles,
    output logic [31:0]   weight_load_cycles,
    output logic [31:0]   monitor_cycles,
    output logic [31:0]   decision_wait_cycles,
    output logic [31:0]   compute_cycles,
    output logic [31:0]   output_stream_cycles,
    output logic [31:0]   total_cycles
);
    localparam logic [3:0] ST_IDLE          = 4'd0;
    localparam logic [3:0] ST_CLEAR         = 4'd1;
    localparam logic [3:0] ST_LOAD          = 4'd2;
    localparam logic [3:0] ST_MONITOR       = 4'd3;
    localparam logic [3:0] ST_WAIT_DECISION = 4'd4;
    localparam logic [3:0] ST_CAPTURE       = 4'd5;
    localparam logic [3:0] ST_COMPUTE       = 4'd6;
    localparam logic [3:0] ST_OUTPUT        = 4'd7;
    localparam logic [3:0] ST_DONE          = 4'd8;

    logic [3:0] state;
    logic [7:0] monitor_index;
    logic output_stream_started;

    always_comb begin
        state_debug = state;
        load_enable = (state == ST_LOAD);
        input_buffer_clear = (state == ST_CLEAR);
        weight_buffer_clear = (state == ST_CLEAR);
        output_buffer_clear = (state == ST_CLEAR);
        monitor_read_enable = (state == ST_MONITOR);
        monitor_read_index = monitor_index;
        layer_start = (state == ST_MONITOR) && (monitor_index == 0);
        sample_valid = (state == ST_MONITOR);
        // Stage 8A explicitly accepts layer_end alongside the final sample.
        layer_end = (state == ST_MONITOR) && (monitor_index == INPUT_ELEMENTS-1);
        compute_start = (state == ST_CAPTURE);
        output_stream_start = (state == ST_OUTPUT) && !output_stream_started;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            monitor_index <= '0;
            output_stream_started <= 1'b0;
            resource_capture_valid <= 1'b0;
            stage8a_resource_at_capture <= 2'b10;
            captured_resource_cfg <= 2'b10;
            input_load_cycles <= '0;
            weight_load_cycles <= '0;
            monitor_cycles <= '0;
            decision_wait_cycles <= '0;
            compute_cycles <= '0;
            output_stream_cycles <= '0;
            total_cycles <= '0;
        end else begin
            resource_capture_valid <= 1'b0;
            if ((state != ST_IDLE) && (state != ST_DONE))
                total_cycles <= total_cycles + 1'b1;

            case (state)
                ST_IDLE: begin
                    if (workload_start)
                        state <= ST_CLEAR;
                end
                ST_CLEAR: begin
                    // Clear is asserted for the whole state and acted upon by
                    // every behavioral buffer at this edge.
                    input_load_cycles <= '0;
                    weight_load_cycles <= '0;
                    monitor_cycles <= '0;
                    decision_wait_cycles <= '0;
                    compute_cycles <= '0;
                    output_stream_cycles <= '0;
                    total_cycles <= '0;
                    monitor_index <= '0;
                    output_stream_started <= 1'b0;
                    state <= ST_LOAD;
                end
                ST_LOAD: begin
                    if (input_load_fire)
                        input_load_cycles <= input_load_cycles + 1'b1;
                    if (weight_load_fire)
                        weight_load_cycles <= weight_load_cycles + 1'b1;
                    if (input_loaded && weight_loaded) begin
                        monitor_index <= '0;
                        state <= ST_MONITOR;
                    end
                end
                ST_MONITOR: begin
                    monitor_cycles <= monitor_cycles + 1'b1;
                    if (monitor_index == INPUT_ELEMENTS-1)
                        state <= ST_WAIT_DECISION;
                    else
                        monitor_index <= monitor_index + 1'b1;
                end
                ST_WAIT_DECISION: begin
                    decision_wait_cycles <= decision_wait_cycles + 1'b1;
                    if (decision_valid) begin
                        stage8a_resource_at_capture <= stage8a_resource_cfg;
                        captured_resource_cfg <= selected_candidate_cfg;
                        resource_capture_valid <= 1'b1;
                        state <= ST_CAPTURE;
                    end
                end
                ST_CAPTURE: begin
                    // compute_start is a one-cycle pulse; the saved config is
                    // already stable when the scheduler samples it.
                    state <= ST_COMPUTE;
                end
                ST_COMPUTE: begin
                    if (compute_busy)
                        compute_cycles <= compute_cycles + 1'b1;
                    if (compute_done) begin
                        output_stream_started <= 1'b0;
                        state <= ST_OUTPUT;
                    end
                end
                ST_OUTPUT: begin
                    if (!output_stream_started)
                        output_stream_started <= 1'b1;
                    if (output_stream_valid && output_stream_ready)
                        output_stream_cycles <= output_stream_cycles + 1'b1;
                    if (output_stream_done)
                        state <= ST_DONE;
                end
                ST_DONE: begin
                    if (workload_start)
                        state <= ST_CLEAR;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
