// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Module: mac_unit_40b.sv
// Description: Signed 40-bit Saturating MAC Unit with Exact-Zero Bypass
// Specification: Ratified Amendments AMD-01 through AMD-05 & Gate 1 Decision G1-D02
// =============================================================================

`timescale 1ns / 1ps

module mac_unit_40b #(
    parameter int ACT_WIDTH   = 16,
    parameter int WEIGHT_WIDTH = 16,
    parameter int ACCUM_WIDTH  = 40
)(
    input  logic                          clk,
    input  logic                          rst_n,
    
    // Control interfaces
    input  logic                          enable,
    input  logic                          accum_clear,
    input  logic                          sat_clear,
    
    // Operands and Exact-Zero Mask (AMD-01, AMD-02)
    input  logic signed [ACT_WIDTH-1:0]   act_data,
    input  logic                          act_mask,       // 1 = compute, 0 = exact-zero skip
    input  logic signed [WEIGHT_WIDTH-1:0] weight_data,
    
    // Outputs
    output logic signed [ACCUM_WIDTH-1:0] accum_out,
    output logic                          sticky_saturation, // Option G1-02A (datapath register latch)
    output logic                          cycle_skipped
);

    // Constant saturation bounds: [-2^39, 2^39 - 1]
    localparam logic signed [ACCUM_WIDTH-1:0] SAT_MAX_POS = 40'sh7F_FFFF_FFFF;
    localparam logic signed [ACCUM_WIDTH-1:0] SAT_MAX_NEG = -40'sh80_0000_0000;

    // Internal arithmetic signals
    logic signed [31:0]                   product_32;
    logic signed [ACCUM_WIDTH:0]          sum_41;        // 41-bit extended for overflow detection
    logic                                 bypass_mac;

    // Exact-zero bypass condition (AMD-02)
    // If mask is 0 or activation operand is 0, MAC is zero-bypassed
    assign bypass_mac = (!act_mask) || (act_data == '0);
    assign cycle_skipped = enable && bypass_mac;

    // Multiplier stage
    always_comb begin
        if (enable && !bypass_mac) begin
            product_32 = act_data * weight_data;
        end else begin
            product_32 = '0;
        end
    end

    // Saturation addition stage (AMD-05)
    always_comb begin
        sum_41 = accum_out + product_32;
    end

    // Sequential accumulator register with sticky saturation latch (G1-D02)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum_out         <= '0;
            sticky_saturation <= 1'b0;
        end else begin
            // Saturation flag clearing
            if (sat_clear) begin
                sticky_saturation <= 1'b0;
            end

            // Accumulator clearing
            if (accum_clear) begin
                accum_out <= '0;
            end else if (enable && !bypass_mac) begin
                // Check positive saturation: sum_41 > SAT_MAX_POS
                if (sum_41 > 41'sh07F_FFFF_FFFF) begin
                    accum_out         <= SAT_MAX_POS;
                    sticky_saturation <= 1'b1;
                // Check negative saturation: sum_41 < SAT_MAX_NEG
                end else if (sum_41 < -41'sh080_0000_0000) begin
                    accum_out         <= SAT_MAX_NEG;
                    sticky_saturation <= 1'b1;
                end else begin
                    accum_out         <= sum_41[ACCUM_WIDTH-1:0];
                end
            end
        end
    end

endmodule

