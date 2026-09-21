`timescale 1ns/1ps

// Buffered padded-3x3 scheduler. A functional compute beat evaluates the 27
// MACs owned by every enabled PE in its current output batch, then scalar
// writeback transfers results into output_buffer. It models dataflow/action
// accounting, not a cycle-accurate SRAM or PE pipeline.
module conv_buffered_scheduler #(
    parameter integer DATA_WIDTH   = 16,
    parameter integer WEIGHT_WIDTH = 16,
    parameter integer ACC_WIDTH    = 48,
    parameter integer INPUT_H      = 8,
    parameter integer INPUT_W      = 8,
    parameter integer INPUT_C      = 3,
    parameter integer KERNEL_H     = 3,
    parameter integer KERNEL_W     = 3,
    parameter integer OUTPUT_C     = 16,
    parameter integer PE_COUNT     = 64
) (
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic                                      start,
    input  logic [6:0]                                active_pe_count,
    input  logic [PE_COUNT-1:0]                       pe_enable_mask,
    input  logic signed [DATA_WIDTH-1:0]              input_tensor [0:INPUT_C*INPUT_H*INPUT_W-1],
    input  logic signed [WEIGHT_WIDTH-1:0]            weight_tensor [0:OUTPUT_C*INPUT_C*KERNEL_H*KERNEL_W-1],
    output logic [15:0]                               input_read_actions,
    output logic [15:0]                               weight_read_actions,
    output logic                                      pe_clear,
    output logic [PE_COUNT-1:0]                       pe_valid,
    output logic signed [DATA_WIDTH-1:0]              pe_activation [0:PE_COUNT-1],
    output logic signed [WEIGHT_WIDTH-1:0]            pe_weight [0:PE_COUNT-1],
    output logic                                      busy,
    output logic                                      done,
    output logic [31:0]                               schedule_cycle_count,
    output logic [31:0]                               mac_cycle_count,
    output logic [31:0]                               active_pe_mac_count,
    output logic                                      output_write_valid,
    output logic [9:0]                                output_write_index,
    output logic signed [ACC_WIDTH-1:0]               output_write_data
);
    localparam integer OUTPUT_H        = INPUT_H;
    localparam integer OUTPUT_W        = INPUT_W;
    localparam integer OUTPUT_ELEMENTS = OUTPUT_C * OUTPUT_H * OUTPUT_W;
    localparam integer MACS_PER_OUTPUT = INPUT_C * KERNEL_H * KERNEL_W;
    localparam logic [2:0] ST_IDLE     = 3'd0;
    localparam logic [2:0] ST_CLEAR    = 3'd1;
    localparam logic [2:0] ST_MAC      = 3'd2;
    localparam logic [2:0] ST_WRITE    = 3'd3;
    localparam logic [2:0] ST_DONE     = 3'd4;

    logic [2:0] state;
    logic [9:0] batch_base;
    logic [6:0] write_pe_index;
    logic signed [ACC_WIDTH-1:0] batch_result_calc [0:PE_COUNT-1];
    logic signed [ACC_WIDTH-1:0] batch_result_reg [0:PE_COUNT-1];
    integer pe_index;
    integer mac_index;
    integer flat_output_index;
    integer output_channel_index;
    integer output_spatial_index;
    integer output_row_index;
    integer output_col_index;
    integer input_channel_index;
    integer kernel_remainder;
    integer kernel_row_index;
    integer kernel_col_index;
    integer input_row_index;
    integer input_col_index;
    integer activation_value;
    integer weight_value;
    integer sum_value;
    integer valid_input_actions;
    integer valid_weight_actions;
    integer valid_mac_actions;

    always_comb begin
        pe_clear = (state == ST_CLEAR);
        pe_valid = '0;
        input_read_actions = '0;
        weight_read_actions = '0;
        valid_input_actions = 0;
        valid_weight_actions = 0;
        valid_mac_actions = 0;
        output_write_valid = 1'b0;
        output_write_index = batch_base + write_pe_index;
        output_write_data = '0;
        for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
            pe_activation[pe_index] = '0;
            pe_weight[pe_index] = '0;
            batch_result_calc[pe_index] = '0;
        end

        if (state == ST_MAC) begin
            for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
                if (pe_enable_mask[pe_index] && (pe_index < active_pe_count) &&
                    ((batch_base + pe_index) < OUTPUT_ELEMENTS)) begin
                    flat_output_index = batch_base + pe_index;
                    output_channel_index = flat_output_index / (OUTPUT_H * OUTPUT_W);
                    output_spatial_index = flat_output_index % (OUTPUT_H * OUTPUT_W);
                    output_row_index = output_spatial_index / OUTPUT_W;
                    output_col_index = output_spatial_index % OUTPUT_W;
                    sum_value = 0;
                    for (mac_index = 0; mac_index < MACS_PER_OUTPUT; mac_index = mac_index + 1) begin
                        input_channel_index = mac_index / (KERNEL_H * KERNEL_W);
                        kernel_remainder = mac_index % (KERNEL_H * KERNEL_W);
                        kernel_row_index = kernel_remainder / KERNEL_W;
                        kernel_col_index = kernel_remainder % KERNEL_W;
                        input_row_index = output_row_index + kernel_row_index - 1;
                        input_col_index = output_col_index + kernel_col_index - 1;
                        activation_value = 0;
                        if ((input_row_index >= 0) && (input_row_index < INPUT_H) &&
                            (input_col_index >= 0) && (input_col_index < INPUT_W)) begin
                            activation_value = input_tensor[input_channel_index*INPUT_H*INPUT_W +
                                                            input_row_index*INPUT_W + input_col_index];
                            valid_input_actions = valid_input_actions + 1;
                        end
                        weight_value = weight_tensor[output_channel_index*INPUT_C*KERNEL_H*KERNEL_W +
                                                     input_channel_index*KERNEL_H*KERNEL_W +
                                                     kernel_row_index*KERNEL_W + kernel_col_index];
                        sum_value = sum_value + activation_value * weight_value;
                        valid_weight_actions = valid_weight_actions + 1;
                        valid_mac_actions = valid_mac_actions + 1;
                    end
                    batch_result_calc[pe_index] = sum_value;
                end
            end
            input_read_actions = valid_input_actions;
            weight_read_actions = valid_weight_actions;
        end

        if ((state == ST_WRITE) && (write_pe_index < active_pe_count) &&
            ((batch_base + write_pe_index) < OUTPUT_ELEMENTS)) begin
            output_write_valid = 1'b1;
            output_write_data = batch_result_reg[write_pe_index];
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= ST_IDLE;
            batch_base <= '0;
            write_pe_index <= '0;
            busy <= 1'b0;
            done <= 1'b0;
            schedule_cycle_count <= '0;
            mac_cycle_count <= '0;
            active_pe_mac_count <= '0;
            for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1)
                batch_result_reg[pe_index] <= '0;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        batch_base <= '0;
                        write_pe_index <= '0;
                        schedule_cycle_count <= '0;
                        mac_cycle_count <= '0;
                        active_pe_mac_count <= '0;
                        busy <= 1'b1;
                        state <= ST_CLEAR;
                    end
                end
                ST_CLEAR: begin
                    busy <= 1'b1;
                    schedule_cycle_count <= schedule_cycle_count + 1'b1;
                    state <= ST_MAC;
                end
                ST_MAC: begin
                    busy <= 1'b1;
                    schedule_cycle_count <= schedule_cycle_count + 1'b1;
                    mac_cycle_count <= mac_cycle_count + 1'b1;
                    active_pe_mac_count <= active_pe_mac_count + valid_mac_actions;
                    for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1)
                        if (pe_index < active_pe_count)
                            batch_result_reg[pe_index] <= batch_result_calc[pe_index];
                    write_pe_index <= '0;
                    state <= ST_WRITE;
                end
                ST_WRITE: begin
                    busy <= 1'b1;
                    schedule_cycle_count <= schedule_cycle_count + 1'b1;
                    if (write_pe_index == active_pe_count-1) begin
                        if ((batch_base + active_pe_count) >= OUTPUT_ELEMENTS)
                            state <= ST_DONE;
                        else begin
                            batch_base <= batch_base + active_pe_count;
                            state <= ST_CLEAR;
                        end
                    end else begin
                        write_pe_index <= write_pe_index + 1'b1;
                    end
                end
                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: begin
                    state <= ST_IDLE;
                    busy <= 1'b0;
                end
            endcase
        end
    end
endmodule
