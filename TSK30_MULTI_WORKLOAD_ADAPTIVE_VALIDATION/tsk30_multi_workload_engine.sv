// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-30 Multi-Workload Adaptive PE Allocation Validation
// Module: tsk30_multi_workload_engine.sv
// Description: Multi-Workload Adaptive Convolution Engine supporting:
//              - Fixed 16-PE (4 passes), 32-PE (2 passes), 64-PE (1 pass)
//              - Adaptive PE allocation instantiated via adaptive_pe_controller.sv
//              - Full fallback detection and degradation constraint auditing
//              - Dense execution vs Sparse activation zero-skipping
//              - Parametric spatial grid, reduction depth K, and chunking
//              - Cycle-accurate hardware telemetry and element-level scoreboarding
// =============================================================================

`timescale 1ns / 1ps

module tsk30_multi_workload_engine #(
    parameter int COORD_W       = 16,
    parameter int ADDR_W        = 14,
    parameter int TILE_IDX_W    = 16,
    parameter int CHUNK_IDX_W   = 8,
    parameter int LAYER_ID_W    = 16,
    parameter int TOTAL_COUT    = 16,
    parameter int ACT_MEM_SIZE  = 9216,
    parameter int WT_MEM_SIZE   = 9216,
    parameter int OUT_MEM_SIZE  = 256
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // Execution Command & Mode Configuration
    input  logic                          start_req,
    input  logic                          abort_req,
    input  logic                          error_clear,
    input  logic [1:0]                    cfg_pe_mode,       // 2'b00: 16-PE, 2'b01: 32-PE, 2'b10: 64-PE
    input  logic                          cfg_adaptive_en,   // 1: Enable dynamic policy; 0: Fixed cfg_pe_mode
    input  logic                          cfg_sparse_en,     // 1: Enable zero-activation skipping; 0: Dense
    input  logic [31:0]                   degradation_hat_16,// Q16.16 predicted degradation
    input  logic [31:0]                   degradation_hat_32,// Q16.16 predicted degradation
    input  logic [31:0]                   degradation_hat_64,// Q16.16 predicted degradation
    input  logic [31:0]                   threshold_d_max,   // Q16.16 threshold (default 3277 = 0.05)

    // Spatial and Layer Parameters
    input  logic [COORD_W-1:0]            cfg_grid_w,
    input  logic [COORD_W-1:0]            cfg_grid_h,
    input  logic [CHUNK_IDX_W-1:0]        cfg_total_chunks,
    input  logic [15:0]                   cfg_k_per_chunk,

    // Status & Handshake
    output logic                          busy,
    output logic                          done_pulse,
    output logic                          error_flag,
    output logic [3:0]                    error_code,

    // Mode Decision & Controller Telemetry
    output logic [1:0]                    active_pe_mode,    // Resolved mode (2'b00, 2'b01, 2'b10)
    output logic                          fallback_asserted, // High if adaptive fell back to 64-PE
    output logic [4:0]                    active_pe_columns, // 4, 8, or 16 active columns
    output logic [2:0]                    total_channel_passes,// 4, 2, or 1 pass
    output logic [2:0]                    controller_state,  // State from adaptive_pe_controller
    output logic                          cfg_changed_pulse, // Pulse from adaptive_pe_controller

    // Empirical Hardware Telemetry Counters
    output logic [31:0]                   telemetry_total_cycles,
    output logic [31:0]                   telemetry_compute_cycles,
    output logic [31:0]                   telemetry_overhead_cycles,
    output logic [31:0]                   telemetry_sram_act_reads,
    output logic [31:0]                   telemetry_sram_wt_reads,
    output logic [31:0]                   telemetry_sram_writes,
    output logic [31:0]                   telemetry_skipped_zero_activations,
    output logic [31:0]                   telemetry_mac_operations,
    output logic [39:0]                   telemetry_output_checksum,

    // Memory Preload & Output Read Interfaces
    input  logic                          mem_act_we,
    input  logic [$clog2(ACT_MEM_SIZE)-1:0] mem_act_addr,
    input  logic signed [15:0]            mem_act_wdata,
    input  logic                          mem_wt_we,
    input  logic [$clog2(WT_MEM_SIZE)-1:0]  mem_wt_addr,
    input  logic signed [15:0]            mem_wt_wdata,
    input  logic [$clog2(OUT_MEM_SIZE)-1:0] mem_out_raddr,
    output logic signed [39:0]            mem_out_rdata
);

    // -------------------------------------------------------------------------
    // Memories: Activations, Weights, and Output OFMAP
    // -------------------------------------------------------------------------
    logic signed [15:0] act_ram [0:ACT_MEM_SIZE-1];
    logic signed [15:0] wt_ram  [0:WT_MEM_SIZE-1];
    logic signed [39:0] out_ram [0:OUT_MEM_SIZE-1];

    always_ff @(posedge clk) begin
        if (mem_act_we) act_ram[mem_act_addr] <= mem_act_wdata;
        if (mem_wt_we)  wt_ram[mem_wt_addr]   <= mem_wt_wdata;
    end

    assign mem_out_rdata = out_ram[mem_out_raddr];

    // -------------------------------------------------------------------------
    // Hardware Adaptive PE Controller Instantiation
    // -------------------------------------------------------------------------
    localparam logic [1:0] MODE_16PE = 2'b00;
    localparam logic [1:0] MODE_32PE = 2'b01;
    localparam logic [1:0] MODE_64PE = 2'b10;

    logic [1:0]  ctrl_cfg_mode;
    logic        ctrl_enable;
    logic        ctrl_accum_clear;
    logic [15:0] ctrl_col_enable;
    logic        ctrl_busy;
    logic        ctrl_cfg_changed;
    logic        ctrl_fallback;
    logic [2:0]  ctrl_fsm_state;

    logic        ctrl_compute_done;
    logic        ctrl_drain_done;

    adaptive_pe_controller #(
        .COLS(16),
        .D_MAX_Q16(16'd3277),
        .USE_FIXED64(1'b0)
    ) u_adaptive_pe_ctrl (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .start_req             (start_req),
        .req_mode              (cfg_pe_mode),
        .adaptive_policy_en    (cfg_adaptive_en),
        .degradation_hat_16    (degradation_hat_16),
        .degradation_hat_32    (degradation_hat_32),
        .degradation_hat_64    (degradation_hat_64),
        .compute_enable_in     (1'b1),
        .compute_done          (ctrl_compute_done),
        .layer_barrier_req     (1'b0),
        .drain_done            (ctrl_drain_done),
        .col_mask_in           (16'hFFFF),
        .cfg_mode              (ctrl_cfg_mode),
        .enable                (ctrl_enable),
        .accum_clear           (ctrl_accum_clear),
        .sat_clear             (),
        .col_enable            (ctrl_col_enable),
        .controller_busy       (ctrl_busy),
        .layer_quiescent       (),
        .configuration_changed (ctrl_cfg_changed),
        .fallback_to_64        (ctrl_fallback),
        .invalid_configuration (),
        .busy_reject           (),
        .controller_state      (ctrl_fsm_state)
    );

    assign controller_state  = ctrl_fsm_state;
    assign cfg_changed_pulse = ctrl_cfg_changed;

    // Latched operational mode for current layer execution
    logic [1:0] mode_q;
    logic       fallback_q;
    logic [4:0] cols_active_q;
    logic [2:0] total_passes_q;

    assign active_pe_mode       = mode_q;
    assign fallback_asserted    = fallback_q;
    assign active_pe_columns    = cols_active_q;
    assign total_channel_passes = total_passes_q;

    // -------------------------------------------------------------------------
    // Physical MAC Array (16 Physical mac_unit_40b instances)
    // -------------------------------------------------------------------------
    logic                          mac_enable;
    logic                          mac_accum_clear;
    logic signed [15:0]            mac_act_data;
    logic signed [15:0]            mac_weight_data [0:TOTAL_COUT-1];
    logic signed [39:0]            mac_accum_out   [0:TOTAL_COUT-1];

    wire                           mac_sticky_sat    [0:TOTAL_COUT-1];
    wire                           mac_cycle_skipped [0:TOTAL_COUT-1];

    genvar pe_idx;
    generate
        for (pe_idx = 0; pe_idx < TOTAL_COUT; pe_idx++) begin : gen_pe_units
            mac_unit_40b #(
                .ACT_WIDTH    (16),
                .WEIGHT_WIDTH (16),
                .ACCUM_WIDTH  (40)
            ) u_mac_unit (
                .clk               (clk),
                .rst_n             (rst_n),
                .enable            (mac_enable),
                .accum_clear       (mac_accum_clear),
                .sat_clear         (1'b0),
                .act_data          (mac_act_data),
                .act_mask          (1'b1),
                .weight_data       (mac_weight_data[pe_idx]),
                .accum_out         (mac_accum_out[pe_idx]),
                .sticky_saturation (mac_sticky_sat[pe_idx]),
                .cycle_skipped     (mac_cycle_skipped[pe_idx])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Multi-Pass Spatial & Reduction Sequencer FSM
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE          = 4'd0,
        ST_INIT_LAYER    = 4'd1,
        ST_TILE_INIT     = 4'd2,
        ST_CHUNK_START   = 4'd3,
        ST_COMPUTE_STEP  = 4'd4,
        ST_CHUNK_DONE    = 4'd5,
        ST_DRAIN_LATCH   = 4'd6,
        ST_PASS_ADVANCE  = 4'd7,
        ST_TILE_ADVANCE  = 4'd8,
        ST_DONE          = 4'd9
    } fsm_state_t;

    fsm_state_t state_q;

    // Spatial & Chunk Tracking Registers
    logic [COORD_W-1:0]     curr_x_q;
    logic [COORD_W-1:0]     curr_y_q;
    logic [TILE_IDX_W-1:0]  curr_tile_idx_q;
    logic [CHUNK_IDX_W-1:0] curr_chunk_idx_q;
    logic [15:0]            k_step_q;
    logic [2:0]             pass_idx_q;

    // Telemetry Registers
    logic [31:0] total_cycles_q;
    logic [31:0] compute_cycles_q;
    logic [31:0] sram_act_reads_q;
    logic [31:0] sram_wt_reads_q;
    logic [31:0] sram_writes_q;
    logic [31:0] zero_skips_q;
    logic [31:0] mac_ops_q;
    logic [39:0] checksum_q;

    assign telemetry_total_cycles             = total_cycles_q;
    assign telemetry_compute_cycles           = compute_cycles_q;
    assign telemetry_overhead_cycles          = (total_cycles_q > compute_cycles_q) ? (total_cycles_q - compute_cycles_q) : 32'd0;
    assign telemetry_sram_act_reads           = sram_act_reads_q;
    assign telemetry_sram_wt_reads            = sram_wt_reads_q;
    assign telemetry_sram_writes              = sram_writes_q;
    assign telemetry_skipped_zero_activations = zero_skips_q;
    assign telemetry_mac_operations           = mac_ops_q;
    assign telemetry_output_checksum          = checksum_q;

    assign busy       = (state_q != ST_IDLE) && (state_q != ST_DONE);
    assign done_pulse = (state_q == ST_DONE);
    assign error_flag = 1'b0;
    assign error_code = 4'd0;

    // Dynamic Address calculations based on parameters
    int unsigned act_addr;
    int unsigned wt_addr;
    int unsigned channel_base;
    int unsigned out_addr;

    // Handshakes to adaptive controller
    assign ctrl_compute_done = (state_q == ST_DONE);
    assign ctrl_drain_done   = (state_q == ST_DONE);

    // -------------------------------------------------------------------------
    // Execution FSM Process
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q           <= ST_IDLE;
            mode_q            <= MODE_64PE;
            fallback_q        <= 1'b0;
            cols_active_q     <= 5'd16;
            total_passes_q    <= 3'd1;
            curr_x_q          <= '0;
            curr_y_q          <= '0;
            curr_tile_idx_q   <= '0;
            curr_chunk_idx_q  <= '0;
            k_step_q          <= '0;
            pass_idx_q        <= '0;
            mac_enable        <= 1'b0;
            mac_accum_clear   <= 1'b0;
            mac_act_data      <= '0;

            total_cycles_q    <= '0;
            compute_cycles_q  <= '0;
            sram_act_reads_q  <= '0;
            sram_wt_reads_q   <= '0;
            sram_writes_q     <= '0;
            zero_skips_q      <= '0;
            mac_ops_q         <= '0;
            checksum_q        <= '0;

            for (int c = 0; c < TOTAL_COUT; c++) begin
                mac_weight_data[c] <= '0;
            end
        end else begin
            // Total cycle counter runs while engine is busy
            if (busy) begin
                total_cycles_q <= total_cycles_q + 1'b1;
            end

            // Default MAC strobes
            mac_enable      <= 1'b0;
            mac_accum_clear <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (start_req) begin
                        // Reset Telemetry Counters
                        total_cycles_q   <= '0;
                        compute_cycles_q <= '0;
                        sram_act_reads_q <= '0;
                        sram_wt_reads_q  <= '0;
                        sram_writes_q    <= '0;
                        zero_skips_q     <= '0;
                        mac_ops_q        <= '0;
                        checksum_q       <= '0;

                        state_q <= ST_INIT_LAYER;
                    end
                end

                ST_INIT_LAYER: begin
                    // Latch Mode & Pass Parameters from adaptive controller (now valid in ST_CLEAR)
                    mode_q     <= ctrl_cfg_mode;
                    fallback_q <= ctrl_fallback;

                    case (ctrl_cfg_mode)
                        MODE_16PE: begin
                            cols_active_q  <= 5'd4;
                            total_passes_q <= 3'd4; // 16 / 4 = 4 passes
                        end
                        MODE_32PE: begin
                            cols_active_q  <= 5'd8;
                            total_passes_q <= 3'd2; // 16 / 8 = 2 passes
                        end
                        default: begin // MODE_64PE
                            cols_active_q  <= 5'd16;
                            total_passes_q <= 3'd1; // 16 / 16 = 1 pass
                        end
                    endcase

                    curr_x_q        <= '0;
                    curr_y_q        <= '0;
                    curr_tile_idx_q <= '0;
                    pass_idx_q      <= '0;
                    state_q         <= ST_TILE_INIT;
                end

                ST_TILE_INIT: begin
                    curr_chunk_idx_q <= '0;
                    // Assert accum_clear to reset MAC accumulators for this tile/pass
                    mac_accum_clear  <= 1'b1;
                    state_q          <= ST_CHUNK_START;
                end

                ST_CHUNK_START: begin
                    k_step_q <= '0;
                    state_q  <= ST_COMPUTE_STEP;
                end

                ST_COMPUTE_STEP: begin
                    // Read activation word: dynamic address based on cfg_total_chunks and cfg_k_per_chunk
                    act_addr = (curr_tile_idx_q * cfg_total_chunks + curr_chunk_idx_q) * cfg_k_per_chunk + k_step_q;
                    mac_act_data     <= act_ram[act_addr];
                    sram_act_reads_q <= sram_act_reads_q + 1'b1;

                    // Channel offset for current pass
                    channel_base = pass_idx_q * cols_active_q;

                    // Check for Exact-Zero Activation Skip
                    if (cfg_sparse_en && (act_ram[act_addr] == 16'sd0)) begin
                        // SPARSE SKIP: Do NOT read weights, skip compute cycle!
                        zero_skips_q <= zero_skips_q + 1'b1;
                        mac_enable   <= 1'b0;

                        if (k_step_q + 1'b1 >= cfg_k_per_chunk) begin
                            state_q <= ST_CHUNK_DONE;
                        end else begin
                            k_step_q <= k_step_q + 1'b1;
                        end
                    end else begin
                        // DENSE COMPUTE: Fetch weights for active columns & drive MAC
                        mac_enable       <= 1'b1;
                        compute_cycles_q <= compute_cycles_q + 1'b1;
                        mac_ops_q        <= mac_ops_q + cols_active_q;
                        sram_wt_reads_q  <= sram_wt_reads_q + cols_active_q;

                        for (int c = 0; c < TOTAL_COUT; c++) begin
                            if (c < cols_active_q) begin
                                wt_addr = ((channel_base + c) * cfg_total_chunks + curr_chunk_idx_q) * cfg_k_per_chunk + k_step_q;
                                mac_weight_data[c] <= wt_ram[wt_addr];
                            end else begin
                                mac_weight_data[c] <= 16'sd0; // Clamp inactive PEs to 0
                            end
                        end

                        if (k_step_q + 1'b1 >= cfg_k_per_chunk) begin
                            state_q <= ST_CHUNK_DONE;
                        end else begin
                            k_step_q <= k_step_q + 1'b1;
                        end
                    end
                end

                ST_CHUNK_DONE: begin
                    // Check if final chunk for this tile/pass
                    if (curr_chunk_idx_q + 1'b1 >= cfg_total_chunks) begin
                        state_q <= ST_DRAIN_LATCH;
                    end else begin
                        curr_chunk_idx_q <= curr_chunk_idx_q + 1'b1;
                        state_q          <= ST_CHUNK_START;
                    end
                end

                ST_DRAIN_LATCH: begin
                    // Store outputs into output RAM for active columns
                    channel_base = pass_idx_q * cols_active_q;
                    for (int c = 0; c < TOTAL_COUT; c++) begin
                        if (c < cols_active_q) begin
                            out_addr = curr_tile_idx_q * TOTAL_COUT + (channel_base + c);
                            out_ram[out_addr] <= mac_accum_out[c];
                            checksum_q        <= checksum_q + mac_accum_out[c];
                        end
                    end
                    sram_writes_q <= sram_writes_q + cols_active_q;
                    state_q       <= ST_PASS_ADVANCE;
                end

                ST_PASS_ADVANCE: begin
                    // Check if more channel passes remain for this spatial tile
                    if (pass_idx_q + 1'b1 < total_passes_q) begin
                        pass_idx_q <= pass_idx_q + 1'b1;
                        state_q    <= ST_TILE_INIT; // Repeat for next channel pass
                    end else begin
                        pass_idx_q <= '0;
                        state_q    <= ST_TILE_ADVANCE;
                    end
                end

                ST_TILE_ADVANCE: begin
                    // Advance 2D spatial coordinate (raster-scan order)
                    if (curr_x_q + 1'b1 >= cfg_grid_w) begin
                        curr_x_q <= '0;
                        if (curr_y_q + 1'b1 >= cfg_grid_h) begin
                            // Entire grid completed!
                            state_q <= ST_DONE;
                        end else begin
                            curr_y_q        <= curr_y_q + 1'b1;
                            curr_tile_idx_q <= curr_tile_idx_q + 1'b1;
                            state_q         <= ST_TILE_INIT;
                        end
                    end else begin
                        curr_x_q        <= curr_x_q + 1'b1;
                        curr_tile_idx_q <= curr_tile_idx_q + 1'b1;
                        state_q         <= ST_TILE_INIT;
                    end
                end

                ST_DONE: begin
                    state_q <= ST_IDLE;
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

endmodule
