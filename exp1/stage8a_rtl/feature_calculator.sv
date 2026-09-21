`timescale 1ns/1ps

module feature_calculator #(
    parameter integer COUNT_W = 32,
    parameter integer SUM_W   = 48,
    parameter integer SUMSQ_W = 64,
    parameter integer FIXED_W = 32,
    parameter integer FRAC_W  = 16
) (
    input  logic                         stats_valid,
    input  logic [COUNT_W-1:0]           element_count,
    input  logic [COUNT_W-1:0]           zero_count,
    input  logic signed [SUM_W-1:0]      sum,
    input  logic [SUMSQ_W-1:0]           sum_square,
    output logic                         features_valid,
    output logic [FIXED_W-1:0]           sparsity,
    output logic signed [FIXED_W-1:0]    mean,
    output logic [FIXED_W-1:0]           variance,
    // Appended ports preserve the original positional port ordering.
    input  logic [1:0]                   stats_layer_id,
    output logic [1:0]                   features_layer_id
);
    localparam integer COUNT_SCALED_W  = COUNT_W + FRAC_W;
    localparam integer SUM_SCALED_W    = SUM_W + FRAC_W;
    localparam integer SECOND_MOMENT_W = SUMSQ_W + FRAC_W + 1;
    localparam integer MEAN_PRODUCT_W  = 2 * SUM_SCALED_W;
    localparam integer VAR_CALC_W      = MEAN_PRODUCT_W + 1;

    localparam logic signed [FIXED_W-1:0] MEAN_MAX =
        {1'b0, {(FIXED_W-1){1'b1}}};
    localparam logic signed [FIXED_W-1:0] MEAN_MIN =
        {1'b1, {(FIXED_W-1){1'b0}}};
    localparam logic signed [VAR_CALC_W-1:0] VARIANCE_MAX_EXT =
        {{(VAR_CALC_W-FIXED_W){1'b0}}, {FIXED_W{1'b1}}};
    localparam logic [COUNT_SCALED_W-1:0] SPARSITY_MAX_EXT =
        {{(COUNT_SCALED_W-FIXED_W){1'b0}}, {FIXED_W{1'b1}}};

    logic [COUNT_SCALED_W-1:0]      zero_scaled;
    logic [COUNT_SCALED_W-1:0]      sparsity_scaled;
    logic signed [SUM_SCALED_W-1:0] sum_scaled;
    logic signed [SUM_SCALED_W-1:0] count_for_mean;
    logic signed [SUM_SCALED_W-1:0] mean_scaled_wide;
    logic signed [MEAN_PRODUCT_W-1:0] mean_operand_wide;
    logic signed [MEAN_PRODUCT_W-1:0] mean_product_wide;
    logic signed [MEAN_PRODUCT_W-1:0] mean_square_scaled_wide;

    logic [SECOND_MOMENT_W-1:0]     sum_square_scaled;
    logic signed [SECOND_MOMENT_W-1:0] count_for_second_moment;
    logic [SECOND_MOMENT_W-1:0]     second_moment_scaled_wide;
    logic signed [VAR_CALC_W-1:0]   second_moment_ext;
    logic signed [VAR_CALC_W-1:0]   mean_square_ext;
    logic signed [VAR_CALC_W-1:0]   variance_wide;

    always_comb begin
        // A completed zero-length layer is still valid: all features are zero
        // and no division is attempted.
        features_valid    = stats_valid;
        features_layer_id = stats_layer_id;
        sparsity          = '0;
        mean              = '0;
        variance          = '0;

        zero_scaled                = '0;
        sparsity_scaled            = '0;
        sum_scaled                 = '0;
        count_for_mean             = '0;
        mean_scaled_wide           = '0;
        mean_operand_wide          = '0;
        mean_product_wide          = '0;
        mean_square_scaled_wide    = '0;
        sum_square_scaled          = '0;
        count_for_second_moment    = '0;
        second_moment_scaled_wide  = '0;
        second_moment_ext          = '0;
        mean_square_ext            = '0;
        variance_wide              = '0;

        if (element_count != '0) begin
            // First widen, then shift. In particular, zero_count << FRAC_W is
            // never evaluated in the original COUNT_W width.
            zero_scaled     = zero_count;
            zero_scaled     = zero_scaled << FRAC_W;
            sparsity_scaled = zero_scaled / element_count;
            if (sparsity_scaled > SPARSITY_MAX_EXT)
                sparsity = {FIXED_W{1'b1}};
            else
                sparsity = sparsity_scaled[FIXED_W-1:0];

            // The signed numerator and signed positive divisor preserve the
            // sign of a negative mean under integer division.
            sum_scaled       = sum;
            sum_scaled       = sum_scaled <<< FRAC_W;
            count_for_mean   = $signed({1'b0, element_count});
            mean_scaled_wide = sum_scaled / count_for_mean;
            if (mean_scaled_wide > MEAN_MAX)
                mean = MEAN_MAX;
            else if (mean_scaled_wide < MEAN_MIN)
                mean = MEAN_MIN;
            else
                mean = mean_scaled_wide[FIXED_W-1:0];

            // E[x^2] uses an unsigned, widened numerator. Its added leading
            // zero makes conversion to the signed variance domain safe.
            sum_square_scaled = {1'b0, sum_square};
            sum_square_scaled = sum_square_scaled << FRAC_W;
            count_for_second_moment = $signed({1'b0, element_count});
            second_moment_scaled_wide =
                sum_square_scaled / count_for_second_moment;

            // mean_scaled_wide is SUM_SCALED_W bits. Both operands are first
            // extended to 2*SUM_SCALED_W bits before multiplying, so the
            // product cannot be truncated to the 32-bit output feature width.
            mean_operand_wide       = mean_scaled_wide;
            mean_product_wide       = mean_operand_wide * mean_operand_wide;
            mean_square_scaled_wide = mean_product_wide >>> FRAC_W;

            second_moment_ext = $signed({1'b0, second_moment_scaled_wide});
            mean_square_ext   = mean_square_scaled_wide;
            variance_wide     = second_moment_ext - mean_square_ext;

            // Truncation can make a mathematically non-negative variance a
            // small negative number; clamp that case. Saturate values outside
            // unsigned Q16.16's 32-bit range rather than wrap.
            if (variance_wide < 0)
                variance = '0;
            else if (variance_wide > VARIANCE_MAX_EXT)
                variance = {FIXED_W{1'b1}};
            else
                variance = variance_wide[FIXED_W-1:0];
        end
    end
endmodule
