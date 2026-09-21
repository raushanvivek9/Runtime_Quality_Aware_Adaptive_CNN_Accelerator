`timescale 1ns/1ps

// Explicit padded 3x3 convolution scheduler. An enabled PE owns one flattened
// output element for all 27 MACs of a batch before the next batch is assigned.
module conv_scheduler #(
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
    input  logic signed [DATA_WIDTH-1:0]              input_mem [0:INPUT_C*INPUT_H*INPUT_W-1],
    input  logic signed [WEIGHT_WIDTH-1:0]            weight_mem [0:OUTPUT_C*INPUT_C*KERNEL_H*KERNEL_W-1],
    input  logic signed [ACC_WIDTH-1:0]               pe_mac_next [0:PE_COUNT-1],
    output logic                                      pe_clear,
    output logic [PE_COUNT-1:0]                       pe_valid,
    output logic signed [DATA_WIDTH-1:0]              pe_activation [0:PE_COUNT-1],
    output logic signed [WEIGHT_WIDTH-1:0]            pe_weight [0:PE_COUNT-1],
    output logic                                      busy,
    output logic                                      done,
    output logic [31:0]                               cycle_count,
    output logic                                      output_valid,
    output logic                                      output_write_valid,
    output logic [9:0]                                output_index_debug,
    output logic signed [ACC_WIDTH-1:0]               output_mem [0:OUTPUT_C*INPUT_H*INPUT_W-1]
);
    localparam integer OUTPUT_H        = INPUT_H;
    localparam integer OUTPUT_W        = INPUT_W;
    localparam integer OUTPUT_ELEMENTS = OUTPUT_C * OUTPUT_H * OUTPUT_W;
    localparam integer MACS_PER_OUTPUT = INPUT_C * KERNEL_H * KERNEL_W;
    localparam logic [1:0] ST_IDLE     = 2'd0;
    localparam logic [1:0] ST_CLEAR    = 2'd1;
    localparam logic [1:0] ST_MAC      = 2'd2;
    localparam logic [1:0] ST_DONE     = 2'd3;

    logic [1:0] state;
    logic [9:0] batch_base;
    logic [4:0] mac_index;
    integer pe_index;
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

    always_comb begin
        pe_clear = (state == ST_CLEAR);
        pe_valid = '0;
        output_index_debug = batch_base;
        output_write_valid = (state == ST_MAC) && (mac_index == MACS_PER_OUTPUT-1);

        for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
            pe_activation[pe_index] = '0;
            pe_weight[pe_index]     = '0;
            if ((state == ST_MAC) && pe_enable_mask[pe_index] &&
                ((batch_base + pe_index) < OUTPUT_ELEMENTS)) begin
                flat_output_index    = batch_base + pe_index;
                output_channel_index = flat_output_index / (OUTPUT_H * OUTPUT_W);
                output_spatial_index = flat_output_index % (OUTPUT_H * OUTPUT_W);
                output_row_index     = output_spatial_index / OUTPUT_W;
                output_col_index     = output_spatial_index % OUTPUT_W;

                input_channel_index = mac_index / (KERNEL_H * KERNEL_W);
                kernel_remainder    = mac_index % (KERNEL_H * KERNEL_W);
                kernel_row_index    = kernel_remainder / KERNEL_W;
                kernel_col_index    = kernel_remainder % KERNEL_W;
                input_row_index     = output_row_index + kernel_row_index - 1;
                input_col_index     = output_col_index + kernel_col_index - 1;

                if ((input_row_index >= 0) && (input_row_index < INPUT_H) &&
                    (input_col_index >= 0) && (input_col_index < INPUT_W)) begin
                    pe_activation[pe_index] =
                        input_mem[input_channel_index*INPUT_H*INPUT_W +
                                  input_row_index*INPUT_W + input_col_index];
                end
                pe_weight[pe_index] =
                    weight_mem[output_channel_index*INPUT_C*KERNEL_H*KERNEL_W +
                               input_channel_index*KERNEL_H*KERNEL_W +
                               kernel_row_index*KERNEL_W + kernel_col_index];
                pe_valid[pe_index] = 1'b1;
            end
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state        <= ST_IDLE;
            batch_base   <= '0;
            mac_index    <= '0;
            busy         <= 1'b0;
            done         <= 1'b0;
            cycle_count  <= '0;
            output_valid <= 1'b0;
            for (pe_index = 0; pe_index < OUTPUT_ELEMENTS; pe_index = pe_index + 1)
                output_mem[pe_index] <= '0;
        end else begin
            done         <= 1'b0;
            output_valid <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        batch_base  <= '0;
                        mac_index   <= '0;
                        cycle_count <= '0;
                        busy        <= 1'b1;
                        state       <= ST_CLEAR;
                        for (pe_index = 0; pe_index < OUTPUT_ELEMENTS; pe_index = pe_index + 1)
                            output_mem[pe_index] <= '0;
                    end
                end

                ST_CLEAR: begin
                    busy      <= 1'b1;
                    mac_index <= '0;
                    state     <= ST_MAC;
                end

                ST_MAC: begin
                    busy        <= 1'b1;
                    cycle_count <= cycle_count + 1'b1;
                    if (mac_index == MACS_PER_OUTPUT-1) begin
                        for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
                            if (pe_valid[pe_index])
                                output_mem[batch_base + pe_index] <= pe_mac_next[pe_index];
                        end
                        if ((batch_base + active_pe_count) >= OUTPUT_ELEMENTS) begin
                            state <= ST_DONE;
                        end else begin
                            batch_base <= batch_base + active_pe_count;
                            mac_index  <= '0;
                            state      <= ST_CLEAR;
                        end
                    end else begin
                        mac_index <= mac_index + 1'b1;
                    end
                end

                ST_DONE: begin
                    busy         <= 1'b0;
                    done         <= 1'b1;
                    output_valid <= 1'b1;
                    state        <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                    busy  <= 1'b0;
                end
            endcase
        end
    end
endmodule
