// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-27C Spatial Sequencer Integration & Multi-Chunk Accumulation
// Module: tsk27c_spatial_accumulation_controller.sv
// Description: Synthesizable Autonomous Spatial Feature-Map and Multi-Chunk
//              Reduction Controller. Integrates the 2D spatial tile sequencer
//              with strict accumulator preservation semantics across multi-pass
//              K-reductions:
//                1. Chunk 0: Clears accumulators, executes compute, suppresses drain.
//                2. Chunks 1..N-2: Preserves partial sums, executes compute, suppresses drain.
//                3. Chunk N-1: Preserves partial sums, executes compute, requests exactly 1 drain.
//                4. Tile Advance: Coordinates advance only after the final chunk drain completes.
// Baseline RTL: All original baseline RTL files remain 100% untouched.
// =============================================================================

`timescale 1ns / 1ps

module tsk27c_spatial_accumulation_controller #(
    parameter int COORD_W     = 16,
    parameter int ADDR_W      = 16,
    parameter int TILE_IDX_W  = 16,
    parameter int CHUNK_IDX_W = 8,
    parameter int LAYER_ID_W  = 16
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // -------------------------------------------------------------------------
    // 1. Host Configuration & Control Interface
    // -------------------------------------------------------------------------
    input  logic                          start_req,          // 1-cycle pulse to start full autonomous run
    input  logic                          abort_req,          // 1-cycle pulse to abort active execution
    input  logic                          error_clear,        // 1-cycle pulse to clear latched error

    input  logic [COORD_W-1:0]            cfg_grid_w,         // Output grid width (W_out > 0)
    input  logic [COORD_W-1:0]            cfg_grid_h,         // Output grid height (H_out > 0)
    input  logic [7:0]                    cfg_step_x,         // Horizontal step (> 0, default 1)
    input  logic [7:0]                    cfg_step_y,         // Vertical step (> 0, default 1)
    input  logic [CHUNK_IDX_W-1:0]        cfg_total_chunks,   // Reduction chunks per tile (N_chunks >= 1)
    input  logic [15:0]                   cfg_k_per_chunk,    // K reduction depth per chunk
    input  logic [ADDR_W-1:0]             cfg_base_ifmap,     // Base SRAM address for IFMAP
    input  logic [ADDR_W-1:0]             cfg_base_ofmap,     // Base SRAM address for OFMAP
    input  logic [ADDR_W-1:0]             cfg_stride_ifmap_x, // Address stride per horizontal tile step
    input  logic [ADDR_W-1:0]             cfg_stride_ifmap_y, // Address stride per vertical row step
    input  logic [ADDR_W-1:0]             cfg_stride_ifmap_chunk, // Address stride between consecutive K chunks
    input  logic [ADDR_W-1:0]             cfg_stride_ofmap,   // OFMAP address stride per spatial tile
    input  logic [LAYER_ID_W-1:0]         cfg_layer_id,
    input  logic [1:0]                    cfg_pe_mode,

    // -------------------------------------------------------------------------
    // 2. Host Status, Telemetry & Diagnostics Interface
    // -------------------------------------------------------------------------
    output logic                          busy,               // High while active
    output logic                          done_pulse,         // 1-cycle pulse upon completing full feature map
    output logic                          error_flag,         // High when error is latched
    output logic [3:0]                    error_code,         // Diagnostic error code
    output logic                          busy_reject,        // 1-cycle pulse if start_req received while busy
    output logic [3:0]                    fsm_state,          // Diagnostic current FSM state

    output logic [COORD_W-1:0]            current_x,          // Current spatial X coordinate
    output logic [COORD_W-1:0]            current_y,          // Current spatial Y coordinate
    output logic [TILE_IDX_W-1:0]         current_tile_idx,   // Linear spatial tile index (0..total_tiles-1)
    output logic [TILE_IDX_W-1:0]         total_tiles_count,  // Total spatial tiles in grid
    output logic [CHUNK_IDX_W-1:0]        current_chunk_idx,  // Current chunk index (0..N_chunks-1)
    output logic [CHUNK_IDX_W-1:0]        total_chunks_count, // Total reduction chunks per tile
    output logic                          is_first_chunk,     // High during Chunk 0
    output logic                          is_last_chunk,      // High during Chunk N-1
    output logic [31:0]                   total_reductions_executed, // Running counter of chunk computations

    // -------------------------------------------------------------------------
    // 3. Downstream Core & Datapath Execution Interface
    // -------------------------------------------------------------------------
    output logic                          core_accum_clear,   // Asserted strictly on Chunk 0
    output logic                          core_compute_valid, // Valid chunk compute command to core/feeder
    input  logic                          core_cmd_ready,     // Core ready to accept compute command
    input  logic                          core_compute_done,  // Core completed chunk datapath compute

    output logic                          core_drain_req,     // Asserted strictly on Chunk N-1 after compute
    input  logic                          core_drain_ready,   // Drain controller ready to accept drain request
    input  logic                          core_drain_done,    // Drain controller completed OFMAP writeout

    output logic [ADDR_W-1:0]             core_ifmap_addr,    // Target SRAM IFMAP address for this chunk
    output logic [ADDR_W-1:0]             core_ofmap_addr,    // Target SRAM OFMAP address for this tile
    output logic [15:0]                   core_k_len,         // Reduction length for this chunk
    output logic [1:0]                    core_pe_mode,
    output logic [LAYER_ID_W-1:0]         core_layer_id
);

    // -------------------------------------------------------------------------
    // Error Code Definitions
    // -------------------------------------------------------------------------
    localparam logic [3:0] ERR_NONE          = 4'd0;
    localparam logic [3:0] ERR_ZERO_WIDTH    = 4'd1;
    localparam logic [3:0] ERR_ZERO_HEIGHT   = 4'd2;
    localparam logic [3:0] ERR_ZERO_CHUNKS   = 4'd3;
    localparam logic [3:0] ERR_ZERO_STEP     = 4'd4;
    localparam logic [3:0] ERR_BUSY_REJECT   = 4'd5;
    localparam logic [3:0] ERR_ABORTED       = 4'd6;

    // -------------------------------------------------------------------------
    // FSM State Encoding
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE             = 4'd0, // Quiescent, awaiting start_req
        ST_VALIDATE         = 4'd1, // Validate parameters and bounds
        ST_SPATIAL_START    = 4'd2, // Trigger start pulse to spatial_tile_sequencer
        ST_SPATIAL_WAIT     = 4'd3, // Await next tile dispatch from spatial sequencer
        ST_CHUNK_INIT       = 4'd4, // Evaluate chunk_idx: pulse accum_clear if chunk 0
        ST_COMPUTE_DISPATCH = 4'd5, // Assert core_compute_valid, await core_cmd_ready
        ST_COMPUTE_WAIT     = 4'd6, // Await core_compute_done from datapath
        ST_CHUNK_EVAL       = 4'd7, // Check if intermediate or final chunk
        ST_DRAIN_DISPATCH   = 4'd8, // Assert core_drain_req on final chunk
        ST_DRAIN_WAIT       = 4'd9, // Await core_drain_done
        ST_TILE_ADVANCE     = 4'd10,// Pulse step_done to spatial sequencer
        ST_DONE             = 4'd11,// Pulse done_pulse upon full grid completion
        ST_ERROR            = 4'd12 // Error hold state
    } ctrl_state_t;

    ctrl_state_t state_q, state_d;

    // -------------------------------------------------------------------------
    // Internal Registers
    // -------------------------------------------------------------------------
    logic [COORD_W-1:0]     grid_w_q, grid_w_d;
    logic [COORD_W-1:0]     grid_h_q, grid_h_d;
    logic [7:0]             step_x_q, step_x_d;
    logic [7:0]             step_y_q, step_y_d;
    logic [CHUNK_IDX_W-1:0] total_chunks_q, total_chunks_d;
    logic [15:0]            k_per_chunk_q, k_per_chunk_d;
    logic [ADDR_W-1:0]      base_ifmap_q, base_ifmap_d;
    logic [ADDR_W-1:0]      base_ofmap_q, base_ofmap_d;
    logic [ADDR_W-1:0]      stride_ifmap_x_q, stride_ifmap_x_d;
    logic [ADDR_W-1:0]      stride_ifmap_y_q, stride_ifmap_y_d;
    logic [ADDR_W-1:0]      stride_ifmap_chunk_q, stride_ifmap_chunk_d;
    logic [ADDR_W-1:0]      stride_ofmap_q, stride_ofmap_d;
    logic [LAYER_ID_W-1:0]  layer_id_q, layer_id_d;
    logic [1:0]             pe_mode_q, pe_mode_d;

    logic [CHUNK_IDX_W-1:0] chunk_idx_q, chunk_idx_d;
    logic [ADDR_W-1:0]      tile_ifmap_base_q, tile_ifmap_base_d;
    logic [ADDR_W-1:0]      tile_ofmap_base_q, tile_ofmap_base_d;
    logic [ADDR_W-1:0]      curr_chunk_addr_q, curr_chunk_addr_d;
    logic [COORD_W-1:0]     latched_x_q, latched_x_d;
    logic [COORD_W-1:0]     latched_y_q, latched_y_d;
    logic [TILE_IDX_W-1:0]  latched_tile_idx_q, latched_tile_idx_d;
    logic                   latched_last_tile_q, latched_last_tile_d;

    logic [31:0]            reductions_cnt_q, reductions_cnt_d;
    logic                   error_flag_q, error_flag_d;
    logic [3:0]             error_code_q, error_code_d;
    logic                   busy_reject_q, busy_reject_d;
    logic                   done_pulse_q, done_pulse_d;

    // Signals interfacing with instantiated spatial_tile_sequencer
    logic                   seq_start_req;
    logic                   seq_abort_req;
    logic                   seq_error_clear;
    logic                   seq_busy;
    logic                   seq_done_pulse;
    logic                   seq_error_flag;
    logic [3:0]             seq_error_code;
    logic                   seq_busy_reject;
    logic [3:0]             seq_fsm_state;
    logic [COORD_W-1:0]     seq_current_x;
    logic [COORD_W-1:0]     seq_current_y;
    logic [TILE_IDX_W-1:0]  seq_current_tile_idx;
    logic [TILE_IDX_W-1:0]  seq_total_tiles_count;
    logic [7:0]             seq_progress_pct;

    logic                   seq_cmd_valid;
    logic                   seq_cmd_ready;
    logic                   seq_step_done;
    logic [LAYER_ID_W-1:0]  seq_cmd_layer_id;
    logic [1:0]             seq_cmd_pe_mode;
    logic [15:0]            seq_cmd_k_total;
    logic [ADDR_W-1:0]      seq_cmd_ifmap_addr;
    logic [ADDR_W-1:0]      seq_cmd_ofmap_addr;
    logic [COORD_W-1:0]     seq_cmd_spatial_x;
    logic [COORD_W-1:0]     seq_cmd_spatial_y;
    logic [TILE_IDX_W-1:0]  seq_cmd_tile_idx;
    logic                   seq_cmd_last_tile;

    // -------------------------------------------------------------------------
    // Instantiation of Standalone Spatial Tile Sequencer (TSK-27A)
    // -------------------------------------------------------------------------
    spatial_tile_sequencer #(
        .COORD_W    (COORD_W),
        .ADDR_W     (ADDR_W),
        .TILE_IDX_W (TILE_IDX_W),
        .LAYER_ID_W (LAYER_ID_W)
    ) u_spatial_seq (
        .clk                (clk),
        .rst_n              (rst_n),
        .start_req          (seq_start_req),
        .abort_req          (seq_abort_req),
        .error_clear        (seq_error_clear),
        .cfg_grid_w         (grid_w_q),
        .cfg_grid_h         (grid_h_q),
        .cfg_step_x         (step_x_q),
        .cfg_step_y         (step_y_q),
        .cfg_base_ifmap     (base_ifmap_q),
        .cfg_base_ofmap     (base_ofmap_q),
        .cfg_stride_ifmap_x (stride_ifmap_x_q),
        .cfg_stride_ifmap_y (stride_ifmap_y_q),
        .cfg_stride_ofmap   (stride_ofmap_q),
        .cfg_layer_id       (layer_id_q),
        .cfg_pe_mode        (pe_mode_q),
        .cfg_k_total        (k_per_chunk_q),
        .busy               (seq_busy),
        .done_pulse         (seq_done_pulse),
        .error_flag         (seq_error_flag),
        .error_code         (seq_error_code),
        .busy_reject        (seq_busy_reject),
        .fsm_state          (seq_fsm_state),
        .current_x          (seq_current_x),
        .current_y          (seq_current_y),
        .current_tile_idx   (seq_current_tile_idx),
        .total_tiles_count  (seq_total_tiles_count),
        .progress_pct       (seq_progress_pct),
        .cmd_valid          (seq_cmd_valid),
        .cmd_ready          (seq_cmd_ready),
        .step_done          (seq_step_done),
        .cmd_layer_id       (seq_cmd_layer_id),
        .cmd_pe_mode        (seq_cmd_pe_mode),
        .cmd_k_total        (seq_cmd_k_total),
        .cmd_ifmap_addr     (seq_cmd_ifmap_addr),
        .cmd_ofmap_addr     (seq_cmd_ofmap_addr),
        .cmd_spatial_x      (seq_cmd_spatial_x),
        .cmd_spatial_y      (seq_cmd_spatial_y),
        .cmd_tile_idx       (seq_cmd_tile_idx),
        .cmd_last_tile      (seq_cmd_last_tile)
    );

    // -------------------------------------------------------------------------
    // Output Assignments
    // -------------------------------------------------------------------------
    assign busy                      = (state_q != ST_IDLE) && (state_q != ST_ERROR);
    assign done_pulse                = done_pulse_q;
    assign error_flag                = error_flag_q;
    assign error_code                = error_code_q;
    assign busy_reject               = busy_reject_q;
    assign fsm_state                 = state_q;

    assign current_x                 = latched_x_q;
    assign current_y                 = latched_y_q;
    assign current_tile_idx          = latched_tile_idx_q;
    assign total_tiles_count         = seq_total_tiles_count;
    assign current_chunk_idx         = chunk_idx_q;
    assign total_chunks_count        = total_chunks_q;
    assign is_first_chunk            = (chunk_idx_q == '0);
    assign is_last_chunk             = (chunk_idx_q + 1'b1 >= total_chunks_q);
    assign total_reductions_executed = reductions_cnt_q;

    // Core Datapath Outputs
    // Accumulator clear is asserted STRICTLY during Chunk 0 in ST_CHUNK_INIT
    assign core_accum_clear          = (state_q == ST_CHUNK_INIT) && (chunk_idx_q == '0);
    assign core_compute_valid        = (state_q == ST_COMPUTE_DISPATCH);
    assign core_drain_req            = (state_q == ST_DRAIN_DISPATCH);
    assign core_ifmap_addr           = curr_chunk_addr_q;
    assign core_ofmap_addr           = tile_ofmap_base_q;
    assign core_k_len                = k_per_chunk_q;
    assign core_pe_mode              = pe_mode_q;
    assign core_layer_id             = layer_id_q;

    // -------------------------------------------------------------------------
    // Next-State and Control Logic
    // -------------------------------------------------------------------------
    always_comb begin
        // Default: hold registers
        state_d              = state_q;
        grid_w_d             = grid_w_q;
        grid_h_d             = grid_h_q;
        step_x_d             = step_x_q;
        step_y_d             = step_y_q;
        total_chunks_d       = total_chunks_q;
        k_per_chunk_d        = k_per_chunk_q;
        base_ifmap_d         = base_ifmap_q;
        base_ofmap_d         = base_ofmap_q;
        stride_ifmap_x_d     = stride_ifmap_x_q;
        stride_ifmap_y_d     = stride_ifmap_y_q;
        stride_ifmap_chunk_d = stride_ifmap_chunk_q;
        stride_ofmap_d       = stride_ofmap_q;
        layer_id_d           = layer_id_q;
        pe_mode_d            = pe_mode_q;

        chunk_idx_d          = chunk_idx_q;
        tile_ifmap_base_d    = tile_ifmap_base_q;
        tile_ofmap_base_d    = tile_ofmap_base_q;
        curr_chunk_addr_d    = curr_chunk_addr_q;
        latched_x_d          = latched_x_q;
        latched_y_d          = latched_y_q;
        latched_tile_idx_d   = latched_tile_idx_q;
        latched_last_tile_d  = latched_last_tile_q;

        reductions_cnt_d     = reductions_cnt_q;
        error_flag_d         = error_flag_q;
        error_code_d         = error_code_q;
        busy_reject_d        = 1'b0;
        done_pulse_d         = 1'b0;

        seq_start_req        = 1'b0;
        seq_abort_req        = 1'b0;
        seq_error_clear      = 1'b0;
        seq_cmd_ready        = 1'b0;
        seq_step_done        = 1'b0;

        // Global Abort Check
        if (abort_req && (state_q != ST_IDLE) && (state_q != ST_ERROR)) begin
            seq_abort_req = 1'b1;
            error_flag_d  = 1'b1;
            error_code_d  = ERR_ABORTED;
            state_d       = ST_ERROR;
        end else begin
            case (state_q)
                // -------------------------------------------------------------
                // ST_IDLE: Await host start request
                // -------------------------------------------------------------
                ST_IDLE: begin
                    if (start_req) begin
                        grid_w_d             = cfg_grid_w;
                        grid_h_d             = cfg_grid_h;
                        step_x_d             = (cfg_step_x != 8'd0) ? cfg_step_x : 8'd1;
                        step_y_d             = (cfg_step_y != 8'd0) ? cfg_step_y : 8'd1;
                        total_chunks_d       = cfg_total_chunks;
                        k_per_chunk_d        = cfg_k_per_chunk;
                        base_ifmap_d         = cfg_base_ifmap;
                        base_ofmap_d         = cfg_base_ofmap;
                        stride_ifmap_x_d     = cfg_stride_ifmap_x;
                        stride_ifmap_y_d     = cfg_stride_ifmap_y;
                        stride_ifmap_chunk_d = cfg_stride_ifmap_chunk;
                        stride_ofmap_d       = cfg_stride_ofmap;
                        layer_id_d           = cfg_layer_id;
                        pe_mode_d            = cfg_pe_mode;

                        error_flag_d         = 1'b0;
                        error_code_d         = ERR_NONE;
                        reductions_cnt_d     = '0;
                        chunk_idx_d          = '0;

                        state_d              = ST_VALIDATE;
                    end
                end

                // -------------------------------------------------------------
                // ST_VALIDATE: Validate parameters
                // -------------------------------------------------------------
                ST_VALIDATE: begin
                    if (grid_w_q == '0) begin
                        error_flag_d = 1'b1;
                        error_code_d = ERR_ZERO_WIDTH;
                        state_d      = ST_ERROR;
                    end else if (grid_h_q == '0) begin
                        error_flag_d = 1'b1;
                        error_code_d = ERR_ZERO_HEIGHT;
                        state_d      = ST_ERROR;
                    end else if (total_chunks_q == '0) begin
                        error_flag_d = 1'b1;
                        error_code_d = ERR_ZERO_CHUNKS;
                        state_d      = ST_ERROR;
                    end else if (step_x_q == 8'd0 || step_y_q == 8'd0) begin
                        error_flag_d = 1'b1;
                        error_code_d = ERR_ZERO_STEP;
                        state_d      = ST_ERROR;
                    end else begin
                        if (start_req) begin
                            busy_reject_d = 1'b1;
                        end
                        state_d = ST_SPATIAL_START;
                    end
                end

                // -------------------------------------------------------------
                // ST_SPATIAL_START: Pulse start to spatial tile sequencer
                // -------------------------------------------------------------
                ST_SPATIAL_START: begin
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end
                    seq_start_req = 1'b1;
                    state_d       = ST_SPATIAL_WAIT;
                end

                // -------------------------------------------------------------
                // ST_SPATIAL_WAIT: Await valid spatial tile from sequencer
                // -------------------------------------------------------------
                ST_SPATIAL_WAIT: begin
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end

                    if (seq_cmd_valid) begin
                        // Latch tile coordinates and base pointers
                        latched_x_d         = seq_cmd_spatial_x;
                        latched_y_d         = seq_cmd_spatial_y;
                        latched_tile_idx_d  = seq_cmd_tile_idx;
                        latched_last_tile_d = seq_cmd_last_tile;
                        tile_ifmap_base_d   = seq_cmd_ifmap_addr;
                        tile_ofmap_base_d   = seq_cmd_ofmap_addr;
                        curr_chunk_addr_d   = seq_cmd_ifmap_addr;
                        chunk_idx_d         = '0;

                        // Handshake accepted
                        seq_cmd_ready       = 1'b1;
                        state_d             = ST_CHUNK_INIT;
                    end
                end

                // -------------------------------------------------------------
                // ST_CHUNK_INIT: Prepare chunk (accum_clear asserted on chunk 0)
                // -------------------------------------------------------------
                ST_CHUNK_INIT: begin
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end
                    // Calculate chunk address: tile_ifmap_base + (chunk_idx * stride_chunk)
                    curr_chunk_addr_d = tile_ifmap_base_q + ADDR_W'(chunk_idx_q * stride_ifmap_chunk_q);
                    state_d           = ST_COMPUTE_DISPATCH;
                end

                // -------------------------------------------------------------
                // ST_COMPUTE_DISPATCH: Offer chunk compute command to core
                // -------------------------------------------------------------
                ST_COMPUTE_DISPATCH: begin
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end

                    if (core_cmd_ready) begin
                        state_d = ST_COMPUTE_WAIT;
                    end
                end

                // -------------------------------------------------------------
                // ST_COMPUTE_WAIT: Await datapath computation completion
                // -------------------------------------------------------------
                ST_COMPUTE_WAIT: begin
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end

                    if (core_compute_done) begin
                        reductions_cnt_d = reductions_cnt_q + 1'b1;
                        state_d          = ST_CHUNK_EVAL;
                    end
                end

                // -------------------------------------------------------------
                // ST_CHUNK_EVAL: Evaluate chunk progress
                // -------------------------------------------------------------
                ST_CHUNK_EVAL: begin
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end

                    if (chunk_idx_q + 1'b1 < total_chunks_q) begin
                        // Intermediate chunk: advance chunk_idx, no clear, no drain!
                        chunk_idx_d = chunk_idx_q + 1'b1;
                        state_d     = ST_CHUNK_INIT;
                    end else begin
                        // Final chunk: request OFMAP output drain
                        state_d     = ST_DRAIN_DISPATCH;
                    end
                end

                // -------------------------------------------------------------
                // ST_DRAIN_DISPATCH: Offer drain request to OFMAP drain engine
                // -------------------------------------------------------------
                ST_DRAIN_DISPATCH: begin
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end

                    if (core_drain_ready) begin
                        state_d = ST_DRAIN_WAIT;
                    end
                end

                // -------------------------------------------------------------
                // ST_DRAIN_WAIT: Await OFMAP drain completion
                // -------------------------------------------------------------
                ST_DRAIN_WAIT: begin
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end

                    if (core_drain_done) begin
                        state_d = ST_TILE_ADVANCE;
                    end
                end

                // -------------------------------------------------------------
                // ST_TILE_ADVANCE: Signal step_done to spatial tile sequencer
                // -------------------------------------------------------------
                ST_TILE_ADVANCE: begin
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end

                    seq_step_done = 1'b1;
                    chunk_idx_d   = '0;

                    if (latched_last_tile_q) begin
                        state_d = ST_DONE;
                    end else begin
                        state_d = ST_SPATIAL_WAIT;
                    end
                end

                // -------------------------------------------------------------
                // ST_DONE: Pulse done and return to IDLE
                // -------------------------------------------------------------
                ST_DONE: begin
                    done_pulse_d = 1'b1;
                    state_d      = ST_IDLE;
                end

                // -------------------------------------------------------------
                // ST_ERROR: Error latch state
                // -------------------------------------------------------------
                ST_ERROR: begin
                    if (error_clear) begin
                        seq_error_clear = 1'b1;
                        error_flag_d    = 1'b0;
                        error_code_d    = ERR_NONE;
                        state_d         = ST_IDLE;
                    end
                end

                default: state_d = ST_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Sequential Registers
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q              <= ST_IDLE;
            grid_w_q             <= '0;
            grid_h_q             <= '0;
            step_x_q             <= 8'd1;
            step_y_q             <= 8'd1;
            total_chunks_q       <= 8'd1;
            k_per_chunk_q        <= '0;
            base_ifmap_q         <= '0;
            base_ofmap_q         <= '0;
            stride_ifmap_x_q     <= '0;
            stride_ifmap_y_q     <= '0;
            stride_ifmap_chunk_q <= '0;
            stride_ofmap_q       <= '0;
            layer_id_q           <= '0;
            pe_mode_q            <= 2'b10;

            chunk_idx_q          <= '0;
            tile_ifmap_base_q    <= '0;
            tile_ofmap_base_q    <= '0;
            curr_chunk_addr_q    <= '0;
            latched_x_q          <= '0;
            latched_y_q          <= '0;
            latched_tile_idx_q   <= '0;
            latched_last_tile_q  <= 1'b0;

            reductions_cnt_q     <= '0;
            error_flag_q         <= 1'b0;
            error_code_q         <= ERR_NONE;
            busy_reject_q        <= 1'b0;
            done_pulse_q         <= 1'b0;
        end else begin
            state_q              <= state_d;
            grid_w_q             <= grid_w_d;
            grid_h_q             <= grid_h_d;
            step_x_q             <= step_x_d;
            step_y_q             <= step_y_d;
            total_chunks_q       <= total_chunks_d;
            k_per_chunk_q        <= k_per_chunk_d;
            base_ifmap_q         <= base_ifmap_d;
            base_ofmap_q         <= base_ofmap_d;
            stride_ifmap_x_q     <= stride_ifmap_x_d;
            stride_ifmap_y_q     <= stride_ifmap_y_d;
            stride_ifmap_chunk_q <= stride_ifmap_chunk_d;
            stride_ofmap_q       <= stride_ofmap_d;
            layer_id_q           <= layer_id_d;
            pe_mode_q            <= pe_mode_d;

            chunk_idx_q          <= chunk_idx_d;
            tile_ifmap_base_q    <= tile_ifmap_base_d;
            tile_ofmap_base_q    <= tile_ofmap_base_d;
            curr_chunk_addr_q    <= curr_chunk_addr_d;
            latched_x_q          <= latched_x_d;
            latched_y_q          <= latched_y_d;
            latched_tile_idx_q   <= latched_tile_idx_d;
            latched_last_tile_q  <= latched_last_tile_d;

            reductions_cnt_q     <= reductions_cnt_d;
            error_flag_q         <= error_flag_d;
            error_code_q         <= error_code_d;
            busy_reject_q        <= busy_reject_d;
            done_pulse_q         <= done_pulse_d;
        end
    end

endmodule
