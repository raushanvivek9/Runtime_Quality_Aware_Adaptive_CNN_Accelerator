`timescale 1ns/1ps

module pooling2x2 #(
    parameter integer DATA_W = 16,
    parameter integer C      = 16,
    parameter integer H      = 8,
    parameter integer W      = 8
) (
    input  logic signed [DATA_W-1:0] in_data [0:C*H*W-1],
    output logic signed [DATA_W-1:0] out_data [0:C*(H/2)*(W/2)-1]
);
    integer ch, row, col, idx;
    logic signed [DATA_W-1:0] maxv;

    always_comb begin
        for (ch = 0; ch < C; ch++) begin
            for (row = 0; row < H/2; row++) begin
                for (col = 0; col < W/2; col++) begin
                    idx = ((ch * (H/2) + row) * (W/2) + col);
                    maxv = in_data[(ch * H + 2*row) * W + 2*col];
                    if (in_data[(ch * H + 2*row) * W + 2*col + 1] > maxv)
                        maxv = in_data[(ch * H + 2*row) * W + 2*col + 1];
                    if (in_data[(ch * H + 2*row + 1) * W + 2*col] > maxv)
                        maxv = in_data[(ch * H + 2*row + 1) * W + 2*col];
                    if (in_data[(ch * H + 2*row + 1) * W + 2*col + 1] > maxv)
                        maxv = in_data[(ch * H + 2*row + 1) * W + 2*col + 1];
                    out_data[idx] = maxv;
                end
            end
        end
    end
endmodule
