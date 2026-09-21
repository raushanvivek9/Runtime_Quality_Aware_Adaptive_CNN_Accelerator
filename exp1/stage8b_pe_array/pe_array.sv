`timescale 1ns/1ps

// One physical 8x8 (64 PE) array. A batch assigns one independent C[i][j]
// output element to each enabled PE, and each PE performs eight MAC cycles.
module pe_array #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ACC_WIDTH  = 32,
    parameter integer MATRIX_DIM = 8,
    parameter integer PE_COUNT   = 64
) (
    input  logic                                  clk,
    input  logic                                  rst,
    input  logic                                  start,
    input  logic [6:0]                            active_pe_count,
    input  logic [PE_COUNT-1:0]                   pe_enable,
    input  logic signed [DATA_WIDTH-1:0]          matrix_a [0:PE_COUNT-1],
    input  logic signed [DATA_WIDTH-1:0]          matrix_b [0:PE_COUNT-1],
    output logic                                  busy,
    output logic                                  done,
    output logic [31:0]                           cycle_count,
    output logic                                  result_valid,
    output logic signed [ACC_WIDTH-1:0]           result_matrix [0:PE_COUNT-1],
    output logic [PE_COUNT-1:0]                   pe_valid_debug,
    output logic signed [ACC_WIDTH-1:0]           pe_accum_debug [0:PE_COUNT-1]
);
    localparam logic [1:0] ST_IDLE    = 2'd0;
    localparam logic [1:0] ST_COMPUTE = 2'd1;
    localparam logic [1:0] ST_DONE    = 2'd2;

    logic [1:0] state;
    logic [6:0] batch_base;
    logic [3:0] k_index;

    logic signed [DATA_WIDTH-1:0] pe_activation [0:PE_COUNT-1];
    logic signed [DATA_WIDTH-1:0] pe_weight [0:PE_COUNT-1];
    logic signed [ACC_WIDTH-1:0]  pe_acc_in [0:PE_COUNT-1];
    logic signed [ACC_WIDTH-1:0]  pe_mac_next [0:PE_COUNT-1];
    logic [PE_COUNT-1:0]          pe_mac_valid_unused;

    integer pe_index;
    integer output_index;
    integer row_index;
    integer col_index;

    // The scheduler drives no valid work to a PE unless it is both logically
    // enabled and assigned an output. Disabled PEs consequently retain acc_out.
    always_comb begin
        pe_valid_debug = '0;
        for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
            pe_activation[pe_index] = '0;
            pe_weight[pe_index]     = '0;
            pe_acc_in[pe_index]     = '0;
            if ((state == ST_COMPUTE) && pe_enable[pe_index] &&
                (pe_index < active_pe_count) && ((batch_base + pe_index) < PE_COUNT)) begin
                output_index = batch_base + pe_index;
                row_index = output_index / MATRIX_DIM;
                col_index = output_index % MATRIX_DIM;
                pe_activation[pe_index] = matrix_a[row_index*MATRIX_DIM + k_index];
                pe_weight[pe_index]     = matrix_b[k_index*MATRIX_DIM + col_index];
                if (k_index == 0)
                    pe_acc_in[pe_index] = '0;
                else
                    pe_acc_in[pe_index] = pe_accum_debug[pe_index];
                pe_valid_debug[pe_index] = 1'b1;
            end
        end
    end

    genvar generated_pe;
    generate
        for (generated_pe = 0; generated_pe < PE_COUNT; generated_pe = generated_pe + 1) begin : gen_physical_pe
            pe_mac #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) mac_i (
                .clk(clk),
                .rst(rst),
                .enable(pe_enable[generated_pe]),
                .valid(pe_valid_debug[generated_pe]),
                .activation(pe_activation[generated_pe]),
                .weight(pe_weight[generated_pe]),
                .acc_in(pe_acc_in[generated_pe]),
                .acc_out(pe_accum_debug[generated_pe]),
                .mac_next(pe_mac_next[generated_pe]),
                .mac_valid(pe_mac_valid_unused[generated_pe])
            );
        end
    endgenerate

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state        <= ST_IDLE;
            batch_base   <= '0;
            k_index      <= '0;
            busy         <= 1'b0;
            done         <= 1'b0;
            cycle_count  <= '0;
            result_valid <= 1'b0;
            for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1)
                result_matrix[pe_index] <= '0;
        end else begin
            done <= 1'b0;
            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        batch_base   <= '0;
                        k_index      <= '0;
                        cycle_count  <= '0;
                        result_valid <= 1'b0;
                        busy         <= 1'b1;
                        state        <= ST_COMPUTE;
                        for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1)
                            result_matrix[pe_index] <= '0;
                    end
                end

                ST_COMPUTE: begin
                    busy        <= 1'b1;
                    cycle_count <= cycle_count + 1'b1;
                    if (k_index == MATRIX_DIM-1) begin
                        // pe_mac registers the same value at this edge. Capture
                        // its explicit combinational next-MAC value for C[i][j].
                        for (pe_index = 0; pe_index < PE_COUNT; pe_index = pe_index + 1) begin
                            if (pe_valid_debug[pe_index])
                                result_matrix[batch_base + pe_index] <= pe_mac_next[pe_index];
                        end
                        if ((batch_base + active_pe_count) >= PE_COUNT) begin
                            state <= ST_DONE;
                        end else begin
                            batch_base <= batch_base + active_pe_count;
                            k_index    <= '0;
                        end
                    end else begin
                        k_index <= k_index + 1'b1;
                    end
                end

                ST_DONE: begin
                    busy         <= 1'b0;
                    done         <= 1'b1;
                    result_valid <= 1'b1;
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
