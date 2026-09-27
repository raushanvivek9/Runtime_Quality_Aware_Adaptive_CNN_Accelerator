`timescale 1ns/1ps

module cnn_dataflow_controller #(
    parameter integer LAYER_COUNT = 3
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       start_network,
    input  logic                       layer_done,
    output logic [1:0]                 current_layer_id,
    output logic                       layer_start,
    output logic                       layer_end,
    output logic                       network_done,
    output logic [2:0]                 state_id
);
    localparam logic [2:0] ST_IDLE    = 3'd0;
    localparam logic [2:0] ST_L1      = 3'd1;
    localparam logic [2:0] ST_POOL1   = 3'd2;
    localparam logic [2:0] ST_L2      = 3'd3;
    localparam logic [2:0] ST_POOL2   = 3'd4;
    localparam logic [2:0] ST_L3      = 3'd5;
    localparam logic [2:0] ST_DONE    = 3'd6;

    logic [2:0] state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            current_layer_id <= 2'b00;
            layer_start <= 1'b0;
            layer_end <= 1'b0;
            network_done <= 1'b0;
            state_id <= ST_IDLE;
        end else begin
            layer_start <= 1'b0;
            layer_end <= 1'b0;
            network_done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start_network) begin
                        state <= ST_L1;
                        current_layer_id <= 2'b00;
                        layer_start <= 1'b1;
                        state_id <= ST_L1;
                    end else begin
                        state_id <= ST_IDLE;
                    end
                end

                ST_L1: begin
                    if (layer_done) begin
                        current_layer_id <= 2'b00;
                        layer_end <= 1'b1;
                        state <= ST_POOL1;
                        state_id <= ST_POOL1;
                    end else begin
                        current_layer_id <= 2'b00;
                        state_id <= ST_L1;
                    end
                end

                ST_POOL1: begin
                    current_layer_id <= 2'b00;
                    state <= ST_L2;
                    current_layer_id <= 2'b01;
                    layer_start <= 1'b1;
                    state_id <= ST_L2;
                end

                ST_L2: begin
                    if (layer_done) begin
                        current_layer_id <= 2'b01;
                        layer_end <= 1'b1;
                        state <= ST_POOL2;
                        state_id <= ST_POOL2;
                    end else begin
                        current_layer_id <= 2'b01;
                        state_id <= ST_L2;
                    end
                end

                ST_POOL2: begin
                    current_layer_id <= 2'b01;
                    state <= ST_L3;
                    current_layer_id <= 2'b10;
                    layer_start <= 1'b1;
                    state_id <= ST_L3;
                end

                ST_L3: begin
                    if (layer_done) begin
                        current_layer_id <= 2'b10;
                        layer_end <= 1'b1;
                        state <= ST_DONE;
                        network_done <= 1'b1;
                        state_id <= ST_DONE;
                    end else begin
                        current_layer_id <= 2'b10;
                        state_id <= ST_L3;
                    end
                end

                default: begin
                    state <= ST_DONE;
                    network_done <= 1'b1;
                    state_id <= ST_DONE;
                end
            endcase
        end
    end
endmodule
