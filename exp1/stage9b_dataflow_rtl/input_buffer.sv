`timescale 1ns/1ps

// Behavioral register-array model for the 3x8x8 activation tensor.  Reads are
// combinational: a scheduler address presented in a cycle returns data in that
// same cycle.  tensor_data is an explicit behavioral-buffer view used by the
// aggregate convolution model; its counted accesses remain action counts only.
module input_buffer #(
    parameter integer DATA_WIDTH = 16,
    parameter integer ELEMENTS   = 192,
    parameter integer PE_COUNT   = 64
) (
    input  logic                                  clk,
    input  logic                                  rst_n,
    input  logic                                  clear,
    input  logic                                  write_valid,
    input  logic [7:0]                            write_index,
    input  logic signed [DATA_WIDTH-1:0]          write_data,
    output logic signed [DATA_WIDTH-1:0]          tensor_data [0:ELEMENTS-1],
    input  logic [15:0]                           compute_read_actions,
    input  logic                                  monitor_read_enable,
    input  logic [7:0]                            monitor_read_index,
    output logic signed [DATA_WIDTH-1:0]          monitor_read_data,
    output logic                                  load_complete,
    output logic [31:0]                           write_count,
    output logic [31:0]                           read_count
);
    logic signed [DATA_WIDTH-1:0] mem [0:ELEMENTS-1];
    integer i;
    genvar data_index;

    generate
        for (data_index = 0; data_index < ELEMENTS; data_index = data_index + 1) begin : gen_tensor_view
            assign tensor_data[data_index] = mem[data_index];
        end
    endgenerate

    always_comb begin
        monitor_read_data = '0;
        if (monitor_read_enable && (monitor_read_index < ELEMENTS))
            monitor_read_data = mem[monitor_read_index];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_complete <= 1'b0;
            write_count   <= '0;
            read_count    <= '0;
            for (i = 0; i < ELEMENTS; i = i + 1)
                mem[i] <= '0;
        end else if (clear) begin
            load_complete <= 1'b0;
            write_count   <= '0;
            read_count    <= '0;
            for (i = 0; i < ELEMENTS; i = i + 1)
                mem[i] <= '0;
        end else begin
            if (write_valid && (write_index < ELEMENTS)) begin
                mem[write_index] <= write_data;
                write_count <= write_count + 1'b1;
                if (write_count == ELEMENTS-1)
                    load_complete <= 1'b1;
            end
            read_count <= read_count + compute_read_actions + (monitor_read_enable ? 1 : 0);
        end
    end
endmodule
