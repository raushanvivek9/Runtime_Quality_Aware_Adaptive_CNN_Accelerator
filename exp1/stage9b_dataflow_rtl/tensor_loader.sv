`timescale 1ns/1ps

// Deterministic single-word tensor ingress.  This is intentionally a small
// valid/ready protocol, not an AXI or DMA implementation.
module tensor_loader #(
    parameter integer DATA_WIDTH      = 16,
    parameter integer INPUT_ELEMENTS  = 192,
    parameter integer WEIGHT_ELEMENTS = 432
) (
    input  logic                         load_valid,
    output logic                         load_ready,
    input  logic signed [DATA_WIDTH-1:0] load_data,
    input  logic [1:0]                   load_type,
    input  logic [9:0]                   load_index,
    input  logic                         load_enable,
    input  logic                         input_loaded,
    input  logic                         weight_loaded,
    output logic                         input_write_valid,
    output logic [7:0]                   input_write_index,
    output logic signed [DATA_WIDTH-1:0] input_write_data,
    output logic                         weight_write_valid,
    output logic [8:0]                   weight_write_index,
    output logic signed [DATA_WIDTH-1:0] weight_write_data,
    output logic                         input_load_fire,
    output logic                         weight_load_fire,
    output logic                         load_done
);
    localparam logic [1:0] TYPE_INPUT  = 2'b00;
    localparam logic [1:0] TYPE_WEIGHT = 2'b01;

    always_comb begin
        input_write_valid = 1'b0;
        input_write_index = load_index[7:0];
        input_write_data  = load_data;
        weight_write_valid = 1'b0;
        weight_write_index = load_index[8:0];
        weight_write_data  = load_data;
        input_load_fire = 1'b0;
        weight_load_fire = 1'b0;
        load_ready = 1'b0;

        if (load_enable) begin
            if ((load_type == TYPE_INPUT) && !input_loaded &&
                (load_index < INPUT_ELEMENTS)) begin
                load_ready = 1'b1;
                if (load_valid) begin
                    input_write_valid = 1'b1;
                    input_load_fire   = 1'b1;
                end
            end else if ((load_type == TYPE_WEIGHT) && !weight_loaded &&
                         (load_index < WEIGHT_ELEMENTS)) begin
                load_ready = 1'b1;
                if (load_valid) begin
                    weight_write_valid = 1'b1;
                    weight_load_fire   = 1'b1;
                end
            end
        end
    end

    assign load_done = input_loaded && weight_loaded;
endmodule
