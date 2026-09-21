`timescale 1ns/1ps

// Lightweight linear quality estimator for RTL control plumbing.
// It is a prototype; its coefficients were not learned from the Stage 3 model.
module quality_estimator #(
    parameter integer FIXED_W = 32,
    parameter integer FRAC_W  = 16,
    parameter integer COEFF_W = 16
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         features_valid,
    input  logic [FIXED_W-1:0]           sparsity,
    input  logic signed [FIXED_W-1:0]    mean,
    input  logic [FIXED_W-1:0]           variance,
    output logic                         estimate_valid,
    output logic [FIXED_W-1:0]           degradation_hat_16,
    output logic [FIXED_W-1:0]           degradation_hat_32,
    output logic [FIXED_W-1:0]           degradation_hat_64,
    // Appended ports preserve the original positional port ordering.
    input  logic [1:0]                   features_layer_id,
    output logic [1:0]                   estimate_layer_id
);
    localparam integer PRODUCT_W = FIXED_W + COEFF_W;
    localparam integer ACCUM_W   = PRODUCT_W + 2;

    // Q16.16 prototype coefficients and zero Q16.16 bias. They are deliberately
    // transparent placeholders, not trained or calibrated coefficients.
    localparam logic [COEFF_W-1:0] COEFF_SPARSE_16 = 16'd1200;
    localparam logic [COEFF_W-1:0] COEFF_MEAN_16   = 16'd300;
    localparam logic [COEFF_W-1:0] COEFF_VAR_16    = 16'd800;
    localparam logic [COEFF_W-1:0] COEFF_SPARSE_32 = 16'd600;
    localparam logic [COEFF_W-1:0] COEFF_MEAN_32   = 16'd150;
    localparam logic [COEFF_W-1:0] COEFF_VAR_32    = 16'd400;

    logic [FIXED_W-1:0] abs_mean;

    // Each operand is explicitly widened to PRODUCT_W before multiplication.
    // The resulting product therefore has at least FIXED_W+COEFF_W bits.
    logic [PRODUCT_W-1:0] sparsity_operand;
    logic [PRODUCT_W-1:0] abs_mean_operand;
    logic [PRODUCT_W-1:0] variance_operand;
    logic [PRODUCT_W-1:0] coeff_sparse_16_operand;
    logic [PRODUCT_W-1:0] coeff_mean_16_operand;
    logic [PRODUCT_W-1:0] coeff_var_16_operand;
    logic [PRODUCT_W-1:0] coeff_sparse_32_operand;
    logic [PRODUCT_W-1:0] coeff_mean_32_operand;
    logic [PRODUCT_W-1:0] coeff_var_32_operand;
    logic [PRODUCT_W-1:0] sparse_product_16;
    logic [PRODUCT_W-1:0] mean_product_16;
    logic [PRODUCT_W-1:0] variance_product_16;
    logic [PRODUCT_W-1:0] sparse_product_32;
    logic [PRODUCT_W-1:0] mean_product_32;
    logic [PRODUCT_W-1:0] variance_product_32;
    logic [ACCUM_W-1:0]   degradation_accum_16;
    logic [ACCUM_W-1:0]   degradation_accum_32;
    logic [ACCUM_W-1:0]   degradation_scaled_16;
    logic [ACCUM_W-1:0]   degradation_scaled_32;
    logic [FIXED_W-1:0]   degradation_16_next;
    logic [FIXED_W-1:0]   degradation_32_next;

    always_comb begin
        // Two's-complement absolute value in an unsigned vector also handles
        // the most-negative mean: its magnitude is 2^(FIXED_W-1), which fits.
        if (mean[FIXED_W-1])
            abs_mean = (~mean) + {{(FIXED_W-1){1'b0}}, 1'b1};
        else
            abs_mean = mean;

        sparsity_operand        = {{COEFF_W{1'b0}}, sparsity};
        abs_mean_operand        = {{COEFF_W{1'b0}}, abs_mean};
        variance_operand        = {{COEFF_W{1'b0}}, variance};
        coeff_sparse_16_operand = {{FIXED_W{1'b0}}, COEFF_SPARSE_16};
        coeff_mean_16_operand   = {{FIXED_W{1'b0}}, COEFF_MEAN_16};
        coeff_var_16_operand    = {{FIXED_W{1'b0}}, COEFF_VAR_16};
        coeff_sparse_32_operand = {{FIXED_W{1'b0}}, COEFF_SPARSE_32};
        coeff_mean_32_operand   = {{FIXED_W{1'b0}}, COEFF_MEAN_32};
        coeff_var_32_operand    = {{FIXED_W{1'b0}}, COEFF_VAR_32};

        sparse_product_16   = sparsity_operand * coeff_sparse_16_operand;
        mean_product_16     = abs_mean_operand * coeff_mean_16_operand;
        variance_product_16 = variance_operand * coeff_var_16_operand;
        sparse_product_32   = sparsity_operand * coeff_sparse_32_operand;
        mean_product_32     = abs_mean_operand * coeff_mean_32_operand;
        variance_product_32 = variance_operand * coeff_var_32_operand;

        degradation_accum_16 =
            {{(ACCUM_W-PRODUCT_W){1'b0}}, sparse_product_16} +
            {{(ACCUM_W-PRODUCT_W){1'b0}}, mean_product_16} +
            {{(ACCUM_W-PRODUCT_W){1'b0}}, variance_product_16};
        degradation_accum_32 =
            {{(ACCUM_W-PRODUCT_W){1'b0}}, sparse_product_32} +
            {{(ACCUM_W-PRODUCT_W){1'b0}}, mean_product_32} +
            {{(ACCUM_W-PRODUCT_W){1'b0}}, variance_product_32};

        degradation_scaled_16 = degradation_accum_16 >> FRAC_W;
        degradation_scaled_32 = degradation_accum_32 >> FRAC_W;
        if (|degradation_scaled_16[ACCUM_W-1:FIXED_W])
            degradation_16_next = {FIXED_W{1'b1}};
        else
            degradation_16_next = degradation_scaled_16[FIXED_W-1:0];
        if (|degradation_scaled_32[ACCUM_W-1:FIXED_W])
            degradation_32_next = {FIXED_W{1'b1}};
        else
            degradation_32_next = degradation_scaled_32[FIXED_W-1:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            estimate_valid      <= 1'b0;
            estimate_layer_id   <= '0;
            degradation_hat_16  <= '0;
            degradation_hat_32  <= '0;
            degradation_hat_64  <= '0;
        end else begin
            estimate_valid <= features_valid;
            if (features_valid) begin
                estimate_layer_id  <= features_layer_id;
                degradation_hat_16 <= degradation_16_next;
                degradation_hat_32 <= degradation_32_next;
                // 64 PE is the baseline configuration in this Stage 8A
                // prototype. D64=0 is a baseline convention, not a learned value.
                degradation_hat_64 <= '0;
            end
        end
    end
endmodule
