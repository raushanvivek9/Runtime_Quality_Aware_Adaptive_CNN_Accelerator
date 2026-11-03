// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Module: adaptive_pe_controller.sv
// Description: Synthesizable Adaptive Processing Element (PE) Controller
//              Coordinates dynamic PE allocation (16, 32, 64 PEs) for pe_array_40b,
//              enforcing safe mode transitions, atomic accumulator clearing,
//              layer-boundary synchronization, and busy-state lockouts.
// Specification: TSK-02, Ratified Decision D-10 & Stage 8A/8B/8C Baseline
// =============================================================================

`timescale 1ns / 1ps

module adaptive_pe_controller #(
    parameter int COLS        = 16,
    parameter int D_MAX_Q16   = 16'd3277, // Ratified Q16.16 threshold (0.05) from Stage 8A
    parameter bit USE_FIXED64 = 1'b0      // Fallback/override to fixed 64-PE mode
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // Command & Workload Configuration Interface
    input  logic                  start_req,          // Request to start a new layer/workload
    input  logic [1:0]            req_mode,           // 2'b00: 16 PE, 2'b01: 32 PE, 2'b10: 64 PE
    input  logic                  adaptive_policy_en, // 1: evaluate degradation metrics; 0: use req_mode
    input  logic [31:0]           degradation_hat_16, // Q16.16 predicted degradation for 16-PE
    input  logic [31:0]           degradation_hat_32, // Q16.16 predicted degradation for 32-PE
    input  logic [31:0]           degradation_hat_64, // Q16.16 predicted degradation for 64-PE (baseline)

    // Compute execution flow control
    input  logic                  compute_enable_in,  // Upstream compute trigger / flit valid
    input  logic                  compute_done,       // Layer computation complete (e.g. slot_done)
    input  logic                  layer_barrier_req,  // Request synchronization at layer barrier
    input  logic                  drain_done,         // Drain completed (e.g. drain_fifo_empty)
    input  logic [COLS-1:0]       col_mask_in,        // Upstream per-column qualification (default '1)

    // Array Datapath Control Interface (directly drives pe_array_40b)
    output logic [1:0]            cfg_mode,           // Latched PE configuration mode
    output logic                  enable,             // Array compute enable (gated during non-compute)
    output logic                  accum_clear,        // Clear partial sum accumulators to 0
    output logic                  sat_clear,          // Clear sticky saturation flags
    output logic [COLS-1:0]       col_enable,         // Qualified per-column enable mask

    // Controller Status & Handshake Interface
    output logic                  controller_busy,    // High when controller is actively managing compute
    output logic                  layer_quiescent,    // High when system is idle or quiescent at barrier
    output logic                  configuration_changed, // 1-cycle pulse upon mode change
    output logic                  fallback_to_64,     // High if adaptive policy fell back to 64 PE
    output logic                  invalid_configuration, // High if an unsupported mode (2'b11) was requested
    output logic                  busy_reject,        // 1-cycle pulse if start_req arrives while busy
    output logic [2:0]            controller_state    // Current FSM state for diagnostics
);

    // Mode definitions matching pe_array_40b
    localparam logic [1:0] MODE_16PE   = 2'b00;
    localparam logic [1:0] MODE_32PE   = 2'b01;
    localparam logic [1:0] MODE_64PE   = 2'b10;
    localparam logic [1:0] MODE_INVALID = 2'b11;

    // FSM State Encoding
    typedef enum logic [2:0] {
        ST_IDLE      = 3'b000, // Quiescent idle state, ready for new request
        ST_CLEAR     = 3'b001, // Single-cycle state asserting accum_clear and latching config
        ST_COMPUTE   = 3'b010, // Active computation state (passes enable to array)
        ST_DRAIN     = 3'b011, // Waiting for partial sum drain to complete
        ST_QUIESCENT = 3'b100, // Layer boundary synchronization quiescent state
        ST_ERROR     = 3'b101  // Error hold state for invalid configuration request
    } ctrl_state_t;

    ctrl_state_t state_q, state_d;

    // Internal registered state
    logic [1:0]  cfg_mode_q, cfg_mode_d;
    logic        cfg_changed_q, cfg_changed_d;
    logic        fallback_q, fallback_d;
    logic        invalid_cfg_q, invalid_cfg_d;
    logic        busy_reject_q, busy_reject_d;

    // Combinational mode resolution based on policy or direct request
    logic [1:0]  resolved_mode;
    logic        resolved_fallback;
    logic        resolved_invalid;

    always_comb begin
        resolved_fallback = 1'b0;
        resolved_invalid  = 1'b0;

        if (USE_FIXED64) begin
            resolved_mode     = MODE_64PE;
            resolved_fallback = 1'b0;
        end else if (adaptive_policy_en) begin
            // Ratified Stage 8A Decision Policy:
            // Select smallest safe PE allocation where predicted degradation <= D_MAX
            if (degradation_hat_16 <= D_MAX_Q16) begin
                resolved_mode = MODE_16PE;
            end else if (degradation_hat_32 <= D_MAX_Q16) begin
                resolved_mode = MODE_32PE;
            end else begin
                // Conservative fallback to 64 PEs when neither 16 nor 32 PE meets constraint
                resolved_mode     = MODE_64PE;
                resolved_fallback = 1'b1;
            end
        end else begin
            // Direct software / layer descriptor request
            resolved_mode = req_mode;
            if (req_mode == MODE_INVALID) begin
                resolved_invalid = 1'b1;
            end
        end
    end

    // FSM Next-State and Output Logic
    always_comb begin
        state_d       = state_q;
        cfg_mode_d    = cfg_mode_q;
        cfg_changed_d = 1'b0;
        fallback_d    = fallback_q;
        invalid_cfg_d = invalid_cfg_q;
        busy_reject_d = 1'b0;

        // Default datapath controls
        enable      = 1'b0;
        accum_clear = 1'b0;
        sat_clear   = 1'b0;
        col_enable  = col_mask_in;

        case (state_q)
            ST_IDLE: begin
                if (start_req) begin
                    if (resolved_invalid) begin
                        invalid_cfg_d = 1'b1;
                        cfg_mode_d    = MODE_INVALID;
                        state_d       = ST_ERROR;
                    end else begin
                        invalid_cfg_d = 1'b0;
                        fallback_d    = resolved_fallback;
                        cfg_changed_d = (resolved_mode != cfg_mode_q);
                        cfg_mode_d    = resolved_mode;
                        state_d       = ST_CLEAR;
                    end
                end
            end

            ST_CLEAR: begin
                // Exactly 1 cycle pulse to clear accumulators and reset saturation
                accum_clear = 1'b1;
                sat_clear   = 1'b1;
                enable      = 1'b0;

                // Reject any redundant start_req arriving while initiating clear
                if (start_req) begin
                    busy_reject_d = 1'b1;
                end

                // Unconditionally proceed to computation
                state_d = ST_COMPUTE;
            end

            ST_COMPUTE: begin
                // Gate enable strictly during active compute
                enable      = compute_enable_in;
                accum_clear = 1'b0;
                sat_clear   = 1'b0;

                // Lockout: reject any new configuration request while computing
                if (start_req) begin
                    busy_reject_d = 1'b1;
                end

                if (compute_done || layer_barrier_req) begin
                    state_d = ST_DRAIN;
                end
            end

            ST_DRAIN: begin
                enable      = 1'b0;
                accum_clear = 1'b0;

                // Lockout: reject start_req during drain
                if (start_req) begin
                    busy_reject_d = 1'b1;
                end

                if (drain_done) begin
                    state_d = ST_QUIESCENT;
                end
            end

            ST_QUIESCENT: begin
                enable      = 1'b0;
                accum_clear = 1'b0;

                // System is quiescent at barrier; can accept next layer request immediately
                if (start_req) begin
                    if (resolved_invalid) begin
                        invalid_cfg_d = 1'b1;
                        cfg_mode_d    = MODE_INVALID;
                        state_d       = ST_ERROR;
                    end else begin
                        invalid_cfg_d = 1'b0;
                        fallback_d    = resolved_fallback;
                        cfg_changed_d = (resolved_mode != cfg_mode_q);
                        cfg_mode_d    = resolved_mode;
                        state_d       = ST_CLEAR;
                    end
                end else begin
                    state_d = ST_IDLE;
                end
            end

            ST_ERROR: begin
                enable      = 1'b0;
                accum_clear = 1'b0;
                cfg_mode_d  = MODE_INVALID;

                // Recovery from error state when a valid new request is issued
                if (start_req && !resolved_invalid) begin
                    invalid_cfg_d = 1'b0;
                    fallback_d    = resolved_fallback;
                    cfg_changed_d = (resolved_mode != cfg_mode_q);
                    cfg_mode_d    = resolved_mode;
                    state_d       = ST_CLEAR;
                end
            end

            default: state_d = ST_IDLE;
        endcase
    end

    // Sequential State Registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q        <= ST_IDLE;
            cfg_mode_q     <= MODE_64PE; // Safe default configuration: 64 PEs
            cfg_changed_q  <= 1'b0;
            fallback_q     <= 1'b0;
            invalid_cfg_q  <= 1'b0;
            busy_reject_q  <= 1'b0;
        end else begin
            state_q        <= state_d;
            cfg_mode_q     <= cfg_mode_d;
            cfg_changed_q  <= cfg_changed_d;
            fallback_q     <= fallback_d;
            invalid_cfg_q  <= invalid_cfg_d;
            busy_reject_q  <= busy_reject_d;
        end
    end

    // Status and diagnostic assignments
    assign cfg_mode              = cfg_mode_q;
    assign controller_state      = state_q;
    assign controller_busy       = (state_q == ST_CLEAR) || (state_q == ST_COMPUTE) || (state_q == ST_DRAIN);
    assign layer_quiescent       = (state_q == ST_IDLE) || (state_q == ST_QUIESCENT);
    assign configuration_changed = cfg_changed_q;
    assign fallback_to_64        = fallback_q;
    assign invalid_configuration = invalid_cfg_q;
    assign busy_reject           = busy_reject_q;

endmodule

