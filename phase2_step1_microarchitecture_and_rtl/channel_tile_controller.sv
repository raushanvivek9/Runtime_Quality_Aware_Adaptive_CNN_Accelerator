// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-21 Multi-Pass Channel Tiling Controller
// Module: channel_tile_controller.sv
// Description: Synthesizable Multi-Pass Channel Tiling Controller.
//              Coordinates multiple compute and drain passes for 16-PE (4 passes)
//              and 32-PE (2 passes) modes, ensuring 100% preservation of all
//              64 output channels (128 words) in multi-bank SRAM without truncation.
//              Supports arbitrary channel counts and tail tiles via custom pass configuration.
// =============================================================================

`timescale 1ns / 1ps

module channel_tile_controller #(
    parameter int SRAM_ADDR_W        = 14,
    parameter int TOTAL_OUTPUT_WORDS = 128 // 64 accumulators x 2 words/accum
)(
    input  logic                                clk,
    input  logic                                rst_n,

    // Control and Configuration Interface
    input  logic                                layer_start,
    input  logic [1:0]                          cfg_pe_mode, // 2'b00: 16-PE, 2'b01: 32-PE, 2'b10: 64-PE
    input  logic [SRAM_ADDR_W-1:0]              cfg_base_ofmap_addr,

    // Optional Custom Tiling & Tail Configuration
    input  logic [2:0]                          cfg_custom_passes, // 0: use default mode-based passes
    input  logic [7:0]                          cfg_custom_words_per_tile, // 0: use default mode-based words
    input  logic [7:0]                          cfg_tail_words, // words in final tail pass (if 0, uses regular words_per_tile)

    // Subsystem Handshake Inputs
    input  logic                                feeder_compute_done,
    input  logic                                ofmap_drain_done,

    // Subsystem Handshake Outputs
    output logic                                tile_start_feeder,
    output logic                                tile_start_drain,
    output logic [SRAM_ADDR_W-1:0]              current_ofmap_addr,
    output logic                                tile_accum_clear,

    // Status and Progress Tracking
    output logic [2:0]                          current_tile_pass,
    output logic [2:0]                          total_tile_passes,
    output logic [7:0]                          words_per_tile,
    output logic                                layer_all_tiles_done,
    output logic                                controller_busy,
    output logic [2:0]                          controller_state
);

    // FSM State Encoding
    typedef enum logic [2:0] {
        ST_IDLE        = 3'd0,
        ST_CLEAR_ACCUM = 3'd1,
        ST_FEEDER_RUN  = 3'd2,
        ST_DRAIN_RUN   = 3'd3,
        ST_CHECK_TILES = 3'd4,
        ST_ALL_DONE    = 3'd5
    } tile_state_t;

    tile_state_t state_q, state_d;

    // Registers
    logic [1:0]               mode_q, mode_d;
    logic [SRAM_ADDR_W-1:0]   base_addr_q, base_addr_d;
    logic [SRAM_ADDR_W-1:0]   curr_addr_q, curr_addr_d;
    logic [2:0]               pass_idx_q, pass_idx_d;
    logic [2:0]               total_passes_q, total_passes_d;
    logic [7:0]               words_tile_q, words_tile_d;
    logic [7:0]               tail_words_q, tail_words_d;
    logic                     feeder_done_latched_q, feeder_done_latched_d;
    logic                     drain_done_latched_q, drain_done_latched_d;

    assign current_tile_pass    = pass_idx_q;
    assign total_tile_passes    = total_passes_q;
    assign words_per_tile       = (pass_idx_q == (total_passes_q - 1'b1) && tail_words_q != 8'd0) ? tail_words_q : words_tile_q;
    assign controller_busy      = (state_q != ST_IDLE);
    assign controller_state     = state_q;
    assign current_ofmap_addr   = curr_addr_q;

    // Combinational Next-State Logic
    always_comb begin
        state_d               = state_q;
        mode_d                = mode_q;
        base_addr_d           = base_addr_q;
        curr_addr_d           = curr_addr_q;
        pass_idx_d            = pass_idx_q;
        total_passes_d        = total_passes_q;
        words_tile_d          = words_tile_q;
        tail_words_d          = tail_words_q;
        feeder_done_latched_d = feeder_done_latched_q;
        drain_done_latched_d  = drain_done_latched_q;

        tile_start_feeder     = 1'b0;
        tile_start_drain      = 1'b0;
        tile_accum_clear      = 1'b0;
        layer_all_tiles_done  = 1'b0;

        case (state_q)
            ST_IDLE: begin
                feeder_done_latched_d = 1'b0;
                drain_done_latched_d  = 1'b0;
                pass_idx_d            = '0;

                if (layer_start) begin
                    mode_d      = cfg_pe_mode;
                    base_addr_d = cfg_base_ofmap_addr;
                    curr_addr_d = cfg_base_ofmap_addr;

                    if (cfg_custom_passes != 3'd0) begin
                        total_passes_d = cfg_custom_passes;
                        words_tile_d   = (cfg_custom_words_per_tile != 8'd0) ? cfg_custom_words_per_tile : 8'd32;
                        tail_words_d   = (cfg_tail_words != 8'd0) ? cfg_tail_words : words_tile_d;
                    end else begin
                        case (cfg_pe_mode)
                            2'b00: begin // 16-PE: 4 passes x 32 words = 128 words
                                total_passes_d = 3'd4;
                                words_tile_d   = 8'd32;
                            end
                            2'b01: begin // 32-PE: 2 passes x 64 words = 128 words
                                total_passes_d = 3'd2;
                                words_tile_d   = 8'd64;
                            end
                            default: begin // 64-PE: 1 pass x 128 words = 128 words
                                total_passes_d = 3'd1;
                                words_tile_d   = 8'd128;
                            end
                        endcase
                        tail_words_d = words_tile_d;
                    end

                    state_d = ST_CLEAR_ACCUM;
                end
            end

            ST_CLEAR_ACCUM: begin
                tile_accum_clear      = 1'b1;
                feeder_done_latched_d = 1'b0;
                drain_done_latched_d  = 1'b0;
                state_d               = ST_FEEDER_RUN;
            end

            ST_FEEDER_RUN: begin
                // Trigger feeder compute on first entry to state
                if (!feeder_done_latched_q) begin
                    tile_start_feeder = 1'b1;
                end

                if (feeder_compute_done || feeder_done_latched_q) begin
                    feeder_done_latched_d = 1'b1;
                    state_d               = ST_DRAIN_RUN;
                end
            end

            ST_DRAIN_RUN: begin
                // Trigger OFMAP drain on first entry to state
                if (!drain_done_latched_q) begin
                    tile_start_drain = 1'b1;
                end

                if (ofmap_drain_done || drain_done_latched_q) begin
                    drain_done_latched_d = 1'b1;
                    state_d              = ST_CHECK_TILES;
                end
            end

            ST_CHECK_TILES: begin
                feeder_done_latched_d = 1'b0;
                drain_done_latched_d  = 1'b0;

                if (pass_idx_q + 1'b1 < total_passes_q) begin
                    pass_idx_d  = pass_idx_q + 1'b1;
                    curr_addr_d = curr_addr_q + words_tile_q;
                    state_d     = ST_CLEAR_ACCUM;
                end else begin
                    layer_all_tiles_done = 1'b1;
                    state_d              = ST_IDLE;
                end
            end

            default: state_d = ST_IDLE;
        endcase
    end

    // Sequential Registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q               <= ST_IDLE;
            mode_q                <= 2'b10;
            base_addr_q           <= '0;
            curr_addr_q           <= '0;
            pass_idx_q            <= '0;
            total_passes_q        <= 3'd1;
            words_tile_q          <= 8'd128;
            tail_words_q          <= 8'd128;
            feeder_done_latched_q <= 1'b0;
            drain_done_latched_q  <= 1'b0;
        end else begin
            state_q               <= state_d;
            mode_q                <= mode_d;
            base_addr_q           <= base_addr_d;
            curr_addr_q           <= curr_addr_d;
            pass_idx_q            <= pass_idx_d;
            total_passes_q        <= total_passes_d;
            words_tile_q          <= words_tile_d;
            tail_words_q          <= tail_words_d;
            feeder_done_latched_q <= feeder_done_latched_d;
            drain_done_latched_q  <= drain_done_latched_d;
        end
    end

endmodule
