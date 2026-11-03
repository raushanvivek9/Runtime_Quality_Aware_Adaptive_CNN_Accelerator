// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-27A Autonomous Spatial Tile Sequencer
// Module: spatial_tile_sequencer.sv
// Description: Synthesizable Autonomous Spatial Feature-Map Tile Sequencer.
//              Traverses a 2D spatial feature map (W_out x H_out) autonomously,
//              generating per-tile coordinates, calculating SRAM pointers,
//              and dispatching commands to downstream accelerator execution units
//              via robust ready/valid handshakes without requiring per-pixel
//              host or testbench intervention.
// =============================================================================

`timescale 1ns / 1ps

module spatial_tile_sequencer #(
    parameter int COORD_W    = 16,
    parameter int ADDR_W     = 16,
    parameter int TILE_IDX_W = 16,
    parameter int LAYER_ID_W = 16
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // -------------------------------------------------------------------------
    // 1. Host Configuration and Control Interface
    // -------------------------------------------------------------------------
    input  logic                          start_req,          // 1-cycle pulse to start autonomous sequence
    input  logic                          abort_req,          // 1-cycle pulse to abort active execution
    input  logic                          error_clear,        // 1-cycle pulse to clear latched error

    input  logic [COORD_W-1:0]            cfg_grid_w,         // Output feature-map width (W_out > 0)
    input  logic [COORD_W-1:0]            cfg_grid_h,         // Output feature-map height (H_out > 0)
    input  logic [7:0]                    cfg_step_x,         // Horizontal coordinate step/stride (> 0, default 1)
    input  logic [7:0]                    cfg_step_y,         // Vertical coordinate step/stride (> 0, default 1)
    input  logic [ADDR_W-1:0]             cfg_base_ifmap,     // Base SRAM address for IFMAP
    input  logic [ADDR_W-1:0]             cfg_base_ofmap,     // Base SRAM address for OFMAP
    input  logic [ADDR_W-1:0]             cfg_stride_ifmap_x, // Address increment per horizontal step
    input  logic [ADDR_W-1:0]             cfg_stride_ifmap_y, // Address increment per vertical row step
    input  logic [ADDR_W-1:0]             cfg_stride_ofmap,   // OFMAP address increment per tile
    input  logic [LAYER_ID_W-1:0]         cfg_layer_id,       // Layer identifier forwarded to core
    input  logic [1:0]                    cfg_pe_mode,        // PE allocation mode (00: 16-PE, 01: 32-PE, 10: 64-PE)
    input  logic [15:0]                   cfg_k_total,        // Reduction depth forwarded to core

    // -------------------------------------------------------------------------
    // 2. Status, Progress and Telemetry Interface
    // -------------------------------------------------------------------------
    output logic                          busy,               // High while autonomously sequencing
    output logic                          done_pulse,         // 1-cycle pulse upon complete grid execution
    output logic                          error_flag,         // High when an error condition is latched
    output logic [3:0]                    error_code,         // Diagnostic error code
    output logic                          busy_reject,        // 1-cycle pulse if start_req received while busy
    output logic [3:0]                    fsm_state,          // Current FSM state for debug

    output logic [COORD_W-1:0]            current_x,          // Current spatial X coordinate (0 .. W_out-1)
    output logic [COORD_W-1:0]            current_y,          // Current spatial Y coordinate (0 .. H_out-1)
    output logic [TILE_IDX_W-1:0]         current_tile_idx,   // Linear tile counter (0 .. total_tiles-1)
    output logic [TILE_IDX_W-1:0]         total_tiles_count,  // Total tiles in current grid
    output logic [7:0]                    progress_pct,       // Execution progress percentage (0..100)

    // -------------------------------------------------------------------------
    // 3. Downstream Core Command & Handshake Interface
    // -------------------------------------------------------------------------
    output logic                          cmd_valid,          // Valid command offered to downstream core
    input  logic                          cmd_ready,          // Downstream core ready to accept command
    input  logic                          step_done,          // Downstream core completed current spatial tile

    output logic [LAYER_ID_W-1:0]         cmd_layer_id,
    output logic [1:0]                    cmd_pe_mode,
    output logic [15:0]                   cmd_k_total,
    output logic [ADDR_W-1:0]             cmd_ifmap_addr,     // Computed SRAM IFMAP address for current tile
    output logic [ADDR_W-1:0]             cmd_ofmap_addr,     // Computed SRAM OFMAP address for current tile
    output logic [COORD_W-1:0]            cmd_spatial_x,      // Tile X coordinate
    output logic [COORD_W-1:0]            cmd_spatial_y,      // Tile Y coordinate
    output logic [TILE_IDX_W-1:0]         cmd_tile_idx,       // Tile linear index
    output logic                          cmd_last_tile       // Asserted high on the final tile of the grid
);

    // -------------------------------------------------------------------------
    // Error Code Definitions
    // -------------------------------------------------------------------------
    localparam logic [3:0] ERR_NONE          = 4'd0;
    localparam logic [3:0] ERR_ZERO_WIDTH    = 4'd1; // Grid width must be > 0
    localparam logic [3:0] ERR_ZERO_HEIGHT   = 4'd2; // Grid height must be > 0
    localparam logic [3:0] ERR_ZERO_STEP     = 4'd3; // Step X and Step Y must be > 0
    localparam logic [3:0] ERR_BUSY_REJECT   = 4'd4; // start_req rejected because sequencer is busy
    localparam logic [3:0] ERR_ABORTED       = 4'd5; // Execution was aborted by upstream host

    // -------------------------------------------------------------------------
    // FSM State Encoding
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE      = 4'd0, // Quiescent, awaiting start_req
        ST_VALIDATE  = 4'd1, // Parameter validation and bounds computation
        ST_DISPATCH  = 4'd2, // Drive cmd_valid high, await cmd_ready
        ST_WAIT_STEP = 4'd3, // Await step_done pulse from downstream core
        ST_ADVANCE   = 4'd4, // Advance coordinates and compute next pointers
        ST_DONE      = 4'd5, // Pulse done upon grid completion
        ST_ERROR     = 4'd6  // Latched error hold state
    } seq_state_t;

    seq_state_t state_q, state_d;

    // -------------------------------------------------------------------------
    // Internal Registers
    // -------------------------------------------------------------------------
    logic [COORD_W-1:0]    grid_w_q, grid_w_d;
    logic [COORD_W-1:0]    grid_h_q, grid_h_d;
    logic [7:0]            step_x_q, step_x_d;
    logic [7:0]            step_y_q, step_y_d;
    logic [ADDR_W-1:0]     base_ifmap_q, base_ifmap_d;
    logic [ADDR_W-1:0]     base_ofmap_q, base_ofmap_d;
    logic [ADDR_W-1:0]     stride_ifmap_x_q, stride_ifmap_x_d;
    logic [ADDR_W-1:0]     stride_ifmap_y_q, stride_ifmap_y_d;
    logic [ADDR_W-1:0]     stride_ofmap_q, stride_ofmap_d;
    logic [LAYER_ID_W-1:0] layer_id_q, layer_id_d;
    logic [1:0]            pe_mode_q, pe_mode_d;
    logic [15:0]           k_total_q, k_total_d;

    logic [COORD_W-1:0]    coord_x_q, coord_x_d;
    logic [COORD_W-1:0]    coord_y_q, coord_y_d;
    logic [TILE_IDX_W-1:0] tile_idx_q, tile_idx_d;
    logic [TILE_IDX_W-1:0] total_tiles_q, total_tiles_d;

    logic [ADDR_W-1:0]     curr_ifmap_addr_q, curr_ifmap_addr_d;
    logic [ADDR_W-1:0]     curr_ofmap_addr_q, curr_ofmap_addr_d;
    logic [ADDR_W-1:0]     row_start_ifmap_q, row_start_ifmap_d;

    logic                  error_flag_q, error_flag_d;
    logic [3:0]            error_code_q, error_code_d;
    logic                  busy_reject_q, busy_reject_d;
    logic                  done_pulse_q, done_pulse_d;

    // -------------------------------------------------------------------------
    // Output Assignments
    // -------------------------------------------------------------------------
    assign busy              = (state_q != ST_IDLE) && (state_q != ST_ERROR);
    assign done_pulse        = done_pulse_q;
    assign error_flag        = error_flag_q;
    assign error_code        = error_code_q;
    assign busy_reject       = busy_reject_q;
    assign fsm_state         = state_q;

    assign current_x         = coord_x_q;
    assign current_y         = coord_y_q;
    assign current_tile_idx  = tile_idx_q;
    assign total_tiles_count = total_tiles_q;

    // Progress percentage calculation: (tile_idx * 100) / total_tiles
    always_comb begin
        if (total_tiles_q > '0) begin
            progress_pct = 8'((32'(tile_idx_q) * 32'd100) / 32'(total_tiles_q));
        end else begin
            progress_pct = 8'd0;
        end
    end

    // Downstream Command Outputs
    assign cmd_valid         = (state_q == ST_DISPATCH);
    assign cmd_layer_id      = layer_id_q;
    assign cmd_pe_mode       = pe_mode_q;
    assign cmd_k_total       = k_total_q;
    assign cmd_ifmap_addr    = curr_ifmap_addr_q;
    assign cmd_ofmap_addr    = curr_ofmap_addr_q;
    assign cmd_spatial_x     = coord_x_q;
    assign cmd_spatial_y     = coord_y_q;
    assign cmd_tile_idx      = tile_idx_q;
    assign cmd_last_tile     = (tile_idx_q + 1'b1 >= total_tiles_q);

    // -------------------------------------------------------------------------
    // Combinational Next-State and Datapath Logic
    // -------------------------------------------------------------------------
    always_comb begin
        // Default: hold current registers
        state_d             = state_q;
        grid_w_d            = grid_w_q;
        grid_h_d            = grid_h_q;
        step_x_d            = step_x_q;
        step_y_d            = step_y_q;
        base_ifmap_d        = base_ifmap_q;
        base_ofmap_d        = base_ofmap_q;
        stride_ifmap_x_d    = stride_ifmap_x_q;
        stride_ifmap_y_d    = stride_ifmap_y_q;
        stride_ofmap_d      = stride_ofmap_q;
        layer_id_d          = layer_id_q;
        pe_mode_d           = pe_mode_q;
        k_total_d           = k_total_q;

        coord_x_d           = coord_x_q;
        coord_y_d           = coord_y_q;
        tile_idx_d          = tile_idx_q;
        total_tiles_d       = total_tiles_q;

        curr_ifmap_addr_d   = curr_ifmap_addr_q;
        curr_ofmap_addr_d   = curr_ofmap_addr_q;
        row_start_ifmap_d   = row_start_ifmap_q;

        error_flag_d        = error_flag_q;
        error_code_d        = error_code_q;
        busy_reject_d       = 1'b0;
        done_pulse_d        = 1'b0;

        // Global Abort Check (highest priority when active)
        if (abort_req && (state_q != ST_IDLE) && (state_q != ST_ERROR)) begin
            error_flag_d = 1'b1;
            error_code_d = ERR_ABORTED;
            state_d      = ST_ERROR;
        end else begin
            case (state_q)
                // -------------------------------------------------------------
                // ST_IDLE: Await start request
                // -------------------------------------------------------------
                ST_IDLE: begin
                    if (start_req) begin
                        // Latch all incoming configuration parameters
                        grid_w_d         = cfg_grid_w;
                        grid_h_d         = cfg_grid_h;
                        step_x_d         = (cfg_step_x != 8'd0) ? cfg_step_x : 8'd1;
                        step_y_d         = (cfg_step_y != 8'd0) ? cfg_step_y : 8'd1;
                        base_ifmap_d     = cfg_base_ifmap;
                        base_ofmap_d     = cfg_base_ofmap;
                        stride_ifmap_x_d = cfg_stride_ifmap_x;
                        stride_ifmap_y_d = cfg_stride_ifmap_y;
                        stride_ofmap_d   = cfg_stride_ofmap;
                        layer_id_d       = cfg_layer_id;
                        pe_mode_d        = cfg_pe_mode;
                        k_total_d        = cfg_k_total;

                        error_flag_d     = 1'b0;
                        error_code_d     = ERR_NONE;

                        state_d          = ST_VALIDATE;
                    end
                end

                // -------------------------------------------------------------
                // ST_VALIDATE: Validate configuration parameters
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
                    end else if (step_x_q == 8'd0 || step_y_q == 8'd0) begin
                        error_flag_d = 1'b1;
                        error_code_d = ERR_ZERO_STEP;
                        state_d      = ST_ERROR;
                    end else begin
                        // Compute total tiles: ceil(W / step_x) * ceil(H / step_y)
                        total_tiles_d = TILE_IDX_W'(((grid_w_q + step_x_q - 1) / step_x_q) * ((grid_h_q + step_y_q - 1) / step_y_q));

                        // Initialize coordinate and address state
                        coord_x_d         = '0;
                        coord_y_d         = '0;
                        tile_idx_d        = '0;
                        curr_ifmap_addr_d = base_ifmap_q;
                        curr_ofmap_addr_d = base_ofmap_q;
                        row_start_ifmap_d = base_ifmap_q;

                        // Start while busy lockout check
                        if (start_req) begin
                            busy_reject_d = 1'b1;
                        end

                        state_d = ST_DISPATCH;
                    end
                end

                // -------------------------------------------------------------
                // ST_DISPATCH: Assert cmd_valid, wait for cmd_ready
                // -------------------------------------------------------------
                ST_DISPATCH: begin
                    // Lockout: reject any new start_req while actively dispatching
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end

                    // Downstream handshake accepted
                    if (cmd_ready) begin
                        state_d = ST_WAIT_STEP;
                    end
                end

                // -------------------------------------------------------------
                // ST_WAIT_STEP: Await step_done from downstream core
                // -------------------------------------------------------------
                ST_WAIT_STEP: begin
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end

                    if (step_done) begin
                        // Check if final tile was completed
                        if (tile_idx_q + 1'b1 >= total_tiles_q) begin
                            state_d = ST_DONE;
                        end else begin
                            state_d = ST_ADVANCE;
                        end
                    end
                end

                // -------------------------------------------------------------
                // ST_ADVANCE: Advance 2D coordinates and update memory pointers
                // -------------------------------------------------------------
                ST_ADVANCE: begin
                    if (start_req) begin
                        busy_reject_d = 1'b1;
                    end

                    tile_idx_d        = tile_idx_q + 1'b1;
                    curr_ofmap_addr_d = curr_ofmap_addr_q + stride_ofmap_q;

                    // Horizontal step check
                    if (coord_x_q + step_x_q < grid_w_q) begin
                        coord_x_d         = coord_x_q + step_x_q;
                        curr_ifmap_addr_d = curr_ifmap_addr_q + stride_ifmap_x_q;
                    end else begin
                        // End of row: roll over to start of next row
                        coord_x_d         = '0;
                        coord_y_d         = coord_y_q + step_y_q;
                        row_start_ifmap_d = row_start_ifmap_q + stride_ifmap_y_q;
                        curr_ifmap_addr_d = row_start_ifmap_q + stride_ifmap_y_q;
                    end

                    state_d = ST_DISPATCH;
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
                        error_flag_d = 1'b0;
                        error_code_d = ERR_NONE;
                        state_d      = ST_IDLE;
                    end else if (start_req) begin
                        // Retry with new parameters
                        grid_w_d         = cfg_grid_w;
                        grid_h_d         = cfg_grid_h;
                        step_x_d         = (cfg_step_x != 8'd0) ? cfg_step_x : 8'd1;
                        step_y_d         = (cfg_step_y != 8'd0) ? cfg_step_y : 8'd1;
                        base_ifmap_d     = cfg_base_ifmap;
                        base_ofmap_d     = cfg_base_ofmap;
                        stride_ifmap_x_d = cfg_stride_ifmap_x;
                        stride_ifmap_y_d = cfg_stride_ifmap_y;
                        stride_ofmap_d   = cfg_stride_ofmap;
                        layer_id_d       = cfg_layer_id;
                        pe_mode_d        = cfg_pe_mode;
                        k_total_d        = cfg_k_total;

                        error_flag_d     = 1'b0;
                        error_code_d     = ERR_NONE;

                        state_d          = ST_VALIDATE;
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
            state_q           <= ST_IDLE;
            grid_w_q          <= '0;
            grid_h_q          <= '0;
            step_x_q          <= 8'd1;
            step_y_q          <= 8'd1;
            base_ifmap_q      <= '0;
            base_ofmap_q      <= '0;
            stride_ifmap_x_q  <= '0;
            stride_ifmap_y_q  <= '0;
            stride_ofmap_q    <= '0;
            layer_id_q        <= '0;
            pe_mode_q         <= 2'b10;
            k_total_q         <= '0;

            coord_x_q         <= '0;
            coord_y_q         <= '0;
            tile_idx_q        <= '0;
            total_tiles_q     <= '0;

            curr_ifmap_addr_q <= '0;
            curr_ofmap_addr_q <= '0;
            row_start_ifmap_q <= '0;

            error_flag_q      <= 1'b0;
            error_code_q      <= ERR_NONE;
            busy_reject_q     <= 1'b0;
            done_pulse_q      <= 1'b0;
        end else begin
            state_q           <= state_d;
            grid_w_q          <= grid_w_d;
            grid_h_q          <= grid_h_d;
            step_x_q          <= step_x_d;
            step_y_q          <= step_y_d;
            base_ifmap_q      <= base_ifmap_d;
            base_ofmap_q      <= base_ofmap_d;
            stride_ifmap_x_q  <= stride_ifmap_x_d;
            stride_ifmap_y_q  <= stride_ifmap_y_d;
            stride_ofmap_q    <= stride_ofmap_d;
            layer_id_q        <= layer_id_d;
            pe_mode_q         <= pe_mode_d;
            k_total_q         <= k_total_d;

            coord_x_q         <= coord_x_d;
            coord_y_q         <= coord_y_d;
            tile_idx_q        <= tile_idx_d;
            total_tiles_q     <= total_tiles_d;

            curr_ifmap_addr_q <= curr_ifmap_addr_d;
            curr_ofmap_addr_q <= curr_ofmap_addr_d;
            row_start_ifmap_q <= row_start_ifmap_d;

            error_flag_q      <= error_flag_d;
            error_code_q      <= error_code_d;
            busy_reject_q     <= busy_reject_d;
            done_pulse_q      <= done_pulse_d;
        end
    end

endmodule
