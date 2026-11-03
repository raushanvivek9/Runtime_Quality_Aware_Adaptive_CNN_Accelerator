// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-21 Requantization Unit
// Module: requantization_unit.sv
// Description: Synthesizable Requantization and Activation Packing Unit.
//              Converts 40-bit signed accumulator outputs into 16-bit activations
//              with configurable bit right-shifting, symmetric rounding,
//              optional ReLU activation, and signed saturation.
//              Packs two 16-bit activations into a 32-bit word for direct SRAM write.
// =============================================================================

`timescale 1ns / 1ps

module requantization_unit #(
    parameter int ACCUM_WIDTH   = 40,
    parameter int ACT_WIDTH     = 16,
    parameter int DATA_WIDTH    = 32
)(
    input  logic                                clk,
    input  logic                                rst_n,

    // Runtime Configuration
    input  logic [4:0]                          cfg_scale_shift, // 0..31 bit shift
    input  logic                                cfg_round_en,    // 1: Add round offset 2^(S-1)
    input  logic                                cfg_relu_en,     // 1: Apply ReLU (max(0, x))
    input  logic signed [ACT_WIDTH-1:0]         cfg_clip_min,    // typically -32768
    input  logic signed [ACT_WIDTH-1:0]         cfg_clip_max,    // typically +32767

    // Stream Input: 40-bit Accumulator
    input  logic                                in_valid,
    output logic                                in_ready,
    input  logic signed [ACCUM_WIDTH-1:0]       in_accum,

    // Stream Output: Individual 16-bit Activation
    output logic                                out_act_valid,
    input  logic                                out_act_ready,
    output logic signed [ACT_WIDTH-1:0]         out_act,

    // Stream Output: Packed 32-bit SRAM Word (2x 16-bit activations)
    output logic                                out_word_valid,
    input  logic                                out_word_ready,
    output logic [DATA_WIDTH-1:0]               out_word,

    // Performance & Diagnostic Counters
    output logic [31:0]                         stat_inputs_processed,
    output logic [31:0]                         stat_words_packed,
    output logic [31:0]                         stat_clips_min,
    output logic [31:0]                         stat_clips_max,
    output logic [31:0]                         stat_relu_zeros
);

    // Default clipping bounds if left 0
    wire signed [ACT_WIDTH-1:0] effective_clip_min =
        (cfg_clip_min == '0 && cfg_clip_max == '0) ? -16'sd32768 : cfg_clip_min;
    wire signed [ACT_WIDTH-1:0] effective_clip_max =
        (cfg_clip_min == '0 && cfg_clip_max == '0) ? 16'sd32767 : cfg_clip_max;

    // -------------------------------------------------------------------------
    // 1. Requantization Datapath (Combinational Scaling, Rounding, Saturation)
    // -------------------------------------------------------------------------
    logic signed [ACCUM_WIDTH:0] shifted_val;
    logic signed [ACCUM_WIDTH:0] round_offset;
    logic signed [ACCUM_WIDTH:0] val_with_round;
    logic signed [ACT_WIDTH-1:0] saturated_val;
    logic                        clipped_min_flag;
    logic                        clipped_max_flag;
    logic                        relu_zero_flag;

    always_comb begin
        // Compute rounding offset: 2^(S-1) if S > 0 and round enabled
        round_offset = '0;
        if (cfg_round_en && (cfg_scale_shift > 5'd0)) begin
            round_offset = (41'sd1 <<< (cfg_scale_shift - 1'b1));
        end

        // Add rounding offset to sign-extended accumulator
        val_with_round = $signed(in_accum) + round_offset;

        // Perform arithmetic right shift
        shifted_val = val_with_round >>> cfg_scale_shift;

        // Saturation logic
        clipped_min_flag = 1'b0;
        clipped_max_flag = 1'b0;
        relu_zero_flag   = 1'b0;

        if (shifted_val > $signed(effective_clip_max)) begin
            saturated_val    = effective_clip_max;
            clipped_max_flag = 1'b1;
        end else if (shifted_val < $signed(effective_clip_min)) begin
            saturated_val    = effective_clip_min;
            clipped_min_flag = 1'b1;
        end else begin
            saturated_val = shifted_val[ACT_WIDTH-1:0];
        end

        // Optional ReLU
        if (cfg_relu_en && (saturated_val < 16'sd0)) begin
            saturated_val  = 16'sd0;
            relu_zero_flag = 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // 2. Packing State Machine & Flow Control
    // -------------------------------------------------------------------------
    // Buffer to hold lower 16-bit activation until upper 16-bit activation arrives
    logic signed [ACT_WIDTH-1:0] pack_lo_q, pack_lo_d;
    logic                        pack_has_lo_q, pack_has_lo_d;
    logic [DATA_WIDTH-1:0]       out_word_q, out_word_d;
    logic                        out_word_valid_q, out_word_valid_d;

    // Backpressure: input is ready if output word buffer is not stalled
    assign in_ready       = (!out_word_valid_q) || out_word_ready;
    assign out_act_valid  = in_valid && in_ready;
    assign out_act        = saturated_val;
    assign out_word_valid = out_word_valid_q;
    assign out_word       = out_word_q;

    always_comb begin
        pack_lo_d        = pack_lo_q;
        pack_has_lo_d    = pack_has_lo_q;
        out_word_d       = out_word_q;
        out_word_valid_d = out_word_valid_q;

        // Clear word valid when consumer accepts
        if (out_word_valid && out_word_ready) begin
            out_word_valid_d = 1'b0;
        end

        // Ingest new accumulator value
        if (in_valid && in_ready) begin
            if (!pack_has_lo_q) begin
                // First activation of pair: store in low slot
                pack_lo_d     = saturated_val;
                pack_has_lo_d = 1'b1;
            end else begin
                // Second activation of pair: assemble 32-bit word {hi, lo}
                out_word_d       = {saturated_val, pack_lo_q};
                out_word_valid_d = 1'b1;
                pack_has_lo_d    = 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. Sequential Registers & Telemetry Tracking
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pack_lo_q              <= '0;
            pack_has_lo_q          <= 1'b0;
            out_word_q             <= '0;
            out_word_valid_q       <= 1'b0;
            stat_inputs_processed  <= '0;
            stat_words_packed      <= '0;
            stat_clips_min         <= '0;
            stat_clips_max         <= '0;
            stat_relu_zeros        <= '0;
        end else begin
            pack_lo_q        <= pack_lo_d;
            pack_has_lo_q    <= pack_has_lo_d;
            out_word_q       <= out_word_d;
            out_word_valid_q <= out_word_valid_d;

            if (in_valid && in_ready) begin
                stat_inputs_processed <= stat_inputs_processed + 1'b1;
                if (clipped_min_flag) stat_clips_min <= stat_clips_min + 1'b1;
                if (clipped_max_flag) stat_clips_max <= stat_clips_max + 1'b1;
                if (relu_zero_flag)   stat_relu_zeros <= stat_relu_zeros + 1'b1;
            end

            if (out_word_valid && out_word_ready) begin
                stat_words_packed <= stat_words_packed + 1'b1;
            end
        end
    end

endmodule
