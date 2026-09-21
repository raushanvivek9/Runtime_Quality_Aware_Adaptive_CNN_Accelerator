`timescale 1ns/1ps

// Stage 8B integration boundary: a future Stage 8A decision_valid/resource_cfg
// pair may drive start/resource_cfg here. This prototype receives them directly.
module adaptive_compute_top #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ACC_WIDTH  = 32,
    parameter integer MATRIX_DIM = 8,
    parameter integer PE_COUNT   = 64
) (
    input  logic                                  clk,
    input  logic                                  rst,
    input  logic                                  start,
    input  logic [1:0]                            resource_cfg,
    input  logic signed [DATA_WIDTH-1:0]          matrix_a [0:PE_COUNT-1],
    input  logic signed [DATA_WIDTH-1:0]          matrix_b [0:PE_COUNT-1],
    output logic                                  busy,
    output logic                                  done,
    output logic [31:0]                           cycle_count,
    output logic                                  result_valid,
    output logic signed [ACC_WIDTH-1:0]           result_matrix [0:PE_COUNT-1],
    output logic [6:0]                            active_pe_count,
    output logic [PE_COUNT-1:0]                   pe_enable_debug,
    output logic [PE_COUNT-1:0]                   pe_valid_debug,
    output logic signed [ACC_WIDTH-1:0]           pe_accum_debug [0:PE_COUNT-1],
    output logic [1:0]                            captured_resource_cfg
);
    logic launch_array;
    logic array_busy;

    // resource_cfg is captured before array start. The incoming value can then
    // change while busy without changing PE gating for the active workload.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            captured_resource_cfg <= 2'b10;
            launch_array          <= 1'b0;
        end else begin
            launch_array <= 1'b0;
            if (start && !busy) begin
                captured_resource_cfg <= resource_cfg;
                launch_array          <= 1'b1;
            end
        end
    end

    assign busy = array_busy | launch_array;

    adaptive_pe_controller #(.PE_COUNT(PE_COUNT)) controller_i (
        .resource_cfg(captured_resource_cfg),
        .active_pe_count(active_pe_count),
        .pe_enable(pe_enable_debug)
    );

    pe_array #(
        .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH),
        .MATRIX_DIM(MATRIX_DIM), .PE_COUNT(PE_COUNT)
    ) array_i (
        .clk(clk), .rst(rst), .start(launch_array),
        .active_pe_count(active_pe_count), .pe_enable(pe_enable_debug),
        .matrix_a(matrix_a), .matrix_b(matrix_b), .busy(array_busy), .done(done),
        .cycle_count(cycle_count), .result_valid(result_valid),
        .result_matrix(result_matrix), .pe_valid_debug(pe_valid_debug),
        .pe_accum_debug(pe_accum_debug)
    );
endmodule
