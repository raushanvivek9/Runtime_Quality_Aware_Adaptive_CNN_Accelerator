// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-05 Pipelined Layer Command Sequencer
// Module: layer_command_sequencer.sv
// Description: Synthesizable Layer Command Sequencer coordinating layer-level
//              accelerator operations using explicit, robust handshakes across
//              the Adaptive PE Controller, Ping-Pong Buffer Subsystem, and
//              Compute Datapath.
// Specification: TSK-05 Specification, Ratified Microarchitectural Decisions
// =============================================================================

`timescale 1ns / 1ps

module layer_command_sequencer #(
    parameter int LAYER_ID_W   = 16,
    parameter int K_WIDTH      = 16,
    parameter int DEGRADE_W    = 32
)(
    input  logic                     clk,
    input  logic                     rst_n,

    // -------------------------------------------------------------------------
    // 1. Upstream Layer Command Interface (Ready / Valid Handshake)
    // -------------------------------------------------------------------------
    input  logic                     cmd_valid,
    output logic                     cmd_ready,
    input  logic [LAYER_ID_W-1:0]    cmd_layer_id,
    input  logic [1:0]               cmd_pe_mode,           // 2'b00: 16-PE, 2'b01: 32-PE, 2'b10: 64-PE, 2'b11: Invalid
    input  logic                     cmd_adaptive_en,       // 1: Enable adaptive degradation policy
    input  logic [DEGRADE_W-1:0]     cmd_degradation_hat_16,
    input  logic [DEGRADE_W-1:0]     cmd_degradation_hat_32,
    input  logic [DEGRADE_W-1:0]     cmd_degradation_hat_64,
    input  logic                     cmd_use_ping_pong,     // 1: Synchronize with ping-pong buffer controller
    input  logic                     cmd_req_buf_id,        // Expected buffer ID (0: Buffer A, 1: Buffer B)
    input  logic [K_WIDTH-1:0]       cmd_k_total,           // Total reduction steps / flits for layer (> 0)

    // -------------------------------------------------------------------------
    // 2. Downstream Adaptive PE Controller Interface (adaptive_pe_controller.sv)
    // -------------------------------------------------------------------------
    output logic                     pe_start_req,          // Request to configure / start PE controller
    output logic [1:0]               pe_req_mode,
    output logic                     pe_adaptive_policy_en,
    output logic [DEGRADE_W-1:0]     pe_degradation_hat_16,
    output logic [DEGRADE_W-1:0]     pe_degradation_hat_32,
    output logic [DEGRADE_W-1:0]     pe_degradation_hat_64,
    input  logic                     pe_controller_busy,    // High when PE controller is managing active execution
    input  logic                     pe_layer_quiescent,    // High when PE array is completely quiescent
    input  logic                     pe_configuration_changed, // 1-cycle pulse upon mode change
    input  logic                     pe_invalid_configuration, // Asserted if mode 2'b11 was requested
    output logic                     pe_compute_done,       // Pulse notifying PE controller compute is complete
    output logic                     pe_drain_done,         // Pulse notifying PE controller drain is complete
    output logic                     pe_layer_barrier_req,  // Signals barrier at end of layer

    // -------------------------------------------------------------------------
    // 3. Downstream Ping-Pong Buffer Controller Interface (ping_pong_buffer_controller.sv)
    // -------------------------------------------------------------------------
    input  logic                     buf_consumer_ready,    // Buffer has valid data ready for consumption
    input  logic                     buf_consumer_buf_id,   // Current ready buffer ID (0: A, 1: B)
    output logic                     buf_consumer_start,    // Pulse to start consuming buffer
    output logic                     buf_consumer_done,     // Pulse to release consumed buffer (mark EMPTY)
    input  logic                     buf_consumer_active,   // Buffer controller actively consuming

    // -------------------------------------------------------------------------
    // 4. Downstream Compute Datapath / Slot Tracker Interface
    // -------------------------------------------------------------------------
    output logic                     compute_start,         // 1-cycle pulse to start slot/datapath execution
    output logic [K_WIDTH-1:0]       compute_k_total,       // Reduction length forwarded to datapath
    input  logic                     compute_done,          // Datapath computation complete (e.g. slot_done)
    input  logic                     drain_done,            // Partial sum drain complete (e.g. drain_fifo_empty)
    input  logic                     drain_error,           // Drain error occurred (e.g. OFMAP address violation)

    // -------------------------------------------------------------------------
    // 5. Upstream Status, Notification & Diagnostic Interface
    // -------------------------------------------------------------------------
    output logic                     layer_done_pulse,      // 1-cycle pulse upon layer completion
    output logic [LAYER_ID_W-1:0]    layer_done_id,         // Layer ID of completed layer
    output logic                     sequencer_busy,        // High while processing any command
    output logic [3:0]               sequencer_state,       // Diagnostic current FSM state
    output logic                     error_flag,            // High when an error condition is held
    output logic [3:0]               error_code,            // Diagnostic error code
    input  logic                     error_clear            // Upstream pulse to clear error state
);

    // -------------------------------------------------------------------------
    // Error Code Definitions
    // -------------------------------------------------------------------------
    localparam logic [3:0] ERR_NONE            = 4'd0;
    localparam logic [3:0] ERR_INVALID_PE_MODE = 4'd1; // Requested mode 2'b11 is unsupported
    localparam logic [3:0] ERR_ZERO_K_TOTAL    = 4'd2; // Reduction length k_total must be > 0
    localparam logic [3:0] ERR_PE_CFG_REJECT   = 4'd3; // Adaptive PE controller rejected configuration
    localparam logic [3:0] ERR_BUFFER_MISMATCH = 4'd4; // Offered buffer ID does not match requested
    localparam logic [3:0] ERR_OFMAP_DRAIN     = 4'd5; // OFMAP drain fault / address violation

    // -------------------------------------------------------------------------
    // FSM State Encoding
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE       = 4'd0, // Ready to accept a new layer command
        ST_VALIDATE   = 4'd1, // Validate command parameters
        ST_WAIT_BUF   = 4'd2, // Wait for ping-pong buffer consumer readiness
        ST_CONFIGURE  = 4'd3, // Issue configuration handshake to Adaptive PE Controller
        ST_START_COMP = 4'd4, // Issue compute start to datapath and ping-pong controller
        ST_WAIT_COMP  = 4'd5, // Await compute completion from datapath (slot_done)
        ST_DRAIN      = 4'd6, // Await partial sum drain & PE array quiescence
        ST_COMPLETE   = 4'd7, // Assert layer_done_pulse and report completion
        ST_ERROR      = 4'd8  // Hold error state until error_clear or reset
    } seq_state_t;

    seq_state_t state_q, state_d;

    // -------------------------------------------------------------------------
    // Registered Command Storage
    // -------------------------------------------------------------------------
    logic [LAYER_ID_W-1:0] layer_id_q,       layer_id_d;
    logic [1:0]            pe_mode_q,        pe_mode_d;
    logic                  adaptive_en_q,    adaptive_en_d;
    logic [DEGRADE_W-1:0]  deg_hat_16_q,     deg_hat_16_d;
    logic [DEGRADE_W-1:0]  deg_hat_32_q,     deg_hat_32_d;
    logic [DEGRADE_W-1:0]  deg_hat_64_q,     deg_hat_64_d;
    logic                  use_ping_pong_q,  use_ping_pong_d;
    logic                  req_buf_id_q,     req_buf_id_d;
    logic [K_WIDTH-1:0]    k_total_q,        k_total_d;

    // Registered Status & Error Registers
    logic [LAYER_ID_W-1:0] done_id_q;
    logic                  error_flag_q,     error_flag_d;
    logic [3:0]            error_code_q,     error_code_d;

    // -------------------------------------------------------------------------
    // Combinational Output Assignments (Exact State Phase Alignment)
    // -------------------------------------------------------------------------
    assign cmd_ready              = (state_q == ST_IDLE) || (state_q == ST_COMPLETE);
    assign sequencer_busy         = (state_q != ST_IDLE);
    assign sequencer_state        = state_q;

    assign layer_done_pulse       = (state_q == ST_COMPLETE);
    assign layer_done_id          = (state_q == ST_COMPLETE) ? layer_id_q : done_id_q;
    assign error_flag             = error_flag_q;
    assign error_code             = error_code_q;

    // Forwarded configuration signals to Adaptive PE Controller
    assign pe_req_mode            = pe_mode_q;
    assign pe_adaptive_policy_en  = adaptive_en_q;
    assign pe_degradation_hat_16  = deg_hat_16_q;
    assign pe_degradation_hat_32  = deg_hat_32_q;
    assign pe_degradation_hat_64  = deg_hat_64_q;

    // Forwarded datapath reduction length
    assign compute_k_total        = k_total_q;

    // Handshake control outputs
    assign pe_start_req           = (state_q == ST_CONFIGURE);
    assign pe_compute_done        = (state_q == ST_WAIT_COMP) && compute_done;
    assign pe_drain_done          = (state_q == ST_DRAIN) && drain_done && pe_layer_quiescent;
    assign pe_layer_barrier_req   = (state_q == ST_DRAIN);

    assign buf_consumer_start     = (state_q == ST_START_COMP) && use_ping_pong_q;
    assign buf_consumer_done      = (state_q == ST_DRAIN) && drain_done && pe_layer_quiescent && use_ping_pong_q;

    assign compute_start          = (state_q == ST_START_COMP);

    // -------------------------------------------------------------------------
    // Next-State Logic
    // -------------------------------------------------------------------------
    always_comb begin
        // Retain current registers by default
        state_d         = state_q;
        layer_id_d      = layer_id_q;
        pe_mode_d       = pe_mode_q;
        adaptive_en_d   = adaptive_en_q;
        deg_hat_16_d    = deg_hat_16_q;
        deg_hat_32_d    = deg_hat_32_q;
        deg_hat_64_d    = deg_hat_64_q;
        use_ping_pong_d = use_ping_pong_q;
        req_buf_id_d    = req_buf_id_q;
        k_total_d       = k_total_q;

        error_flag_d    = error_flag_q;
        error_code_d    = error_code_q;

        case (state_q)
            // -----------------------------------------------------------------
            // ST_IDLE: Await new layer command from upstream
            // -----------------------------------------------------------------
            ST_IDLE: begin
                if (cmd_valid) begin
                    // Latch all incoming command fields
                    layer_id_d      = cmd_layer_id;
                    pe_mode_d       = cmd_pe_mode;
                    adaptive_en_d   = cmd_adaptive_en;
                    deg_hat_16_d    = cmd_degradation_hat_16;
                    deg_hat_32_d    = cmd_degradation_hat_32;
                    deg_hat_64_d    = cmd_degradation_hat_64;
                    use_ping_pong_d = cmd_use_ping_pong;
                    req_buf_id_d    = cmd_req_buf_id;
                    k_total_d       = cmd_k_total;

                    error_flag_d    = 1'b0;
                    error_code_d    = ERR_NONE;

                    state_d         = ST_VALIDATE;
                end
            end

            // -----------------------------------------------------------------
            // ST_VALIDATE: Check command parameters for legal values
            // -----------------------------------------------------------------
            ST_VALIDATE: begin
                // Check 1: PE mode 2'b11 is unsupported
                if (pe_mode_q == 2'b11) begin
                    error_flag_d = 1'b1;
                    error_code_d = ERR_INVALID_PE_MODE;
                    state_d      = ST_ERROR;
                // Check 2: k_total must be greater than zero
                end else if (k_total_q == '0) begin
                    error_flag_d = 1'b1;
                    error_code_d = ERR_ZERO_K_TOTAL;
                    state_d      = ST_ERROR;
                end else begin
                    // Valid parameters: check if buffer synchronization is required
                    if (use_ping_pong_q) begin
                        state_d = ST_WAIT_BUF;
                    end else begin
                        state_d = ST_CONFIGURE;
                    end
                end
            end

            // -----------------------------------------------------------------
            // ST_WAIT_BUF: Wait for required Ping-Pong Buffer readiness
            // -----------------------------------------------------------------
            ST_WAIT_BUF: begin
                if (buf_consumer_ready) begin
                    // Optional buffer ID qualification
                    if (buf_consumer_buf_id == req_buf_id_q) begin
                        state_d = ST_CONFIGURE;
                    end else begin
                        // Target buffer mismatch (offered buffer does not match requested)
                        error_flag_d = 1'b1;
                        error_code_d = ERR_BUFFER_MISMATCH;
                        state_d      = ST_ERROR;
                    end
                end
                // If not ready, hold in ST_WAIT_BUF (deterministic backpressure)
            end

            // -----------------------------------------------------------------
            // ST_CONFIGURE: Issue configuration request to Adaptive PE Controller
            // -----------------------------------------------------------------
            ST_CONFIGURE: begin
                // Check for immediate controller error rejection
                if (pe_invalid_configuration) begin
                    error_flag_d = 1'b1;
                    error_code_d = ERR_PE_CFG_REJECT;
                    state_d      = ST_ERROR;
                end else begin
                    // Controller advances from ST_CLEAR -> ST_COMPUTE
                    state_d = ST_START_COMP;
                end
            end

            // -----------------------------------------------------------------
            // ST_START_COMP: Issue compute trigger to datapath and buffer consumer
            // -----------------------------------------------------------------
            ST_START_COMP: begin
                state_d = ST_WAIT_COMP;
            end

            // -----------------------------------------------------------------
            // ST_WAIT_COMP: Await compute completion from datapath
            // -----------------------------------------------------------------
            ST_WAIT_COMP: begin
                if (drain_error) begin
                    error_flag_d = 1'b1;
                    error_code_d = ERR_OFMAP_DRAIN;
                    state_d      = ST_ERROR;
                end else if (compute_done) begin
                    state_d = ST_DRAIN;
                end
            end

            // -----------------------------------------------------------------
            // ST_DRAIN: Await partial sum drain & quiescent datapath
            // -----------------------------------------------------------------
            ST_DRAIN: begin
                if (drain_error) begin
                    error_flag_d = 1'b1;
                    error_code_d = ERR_OFMAP_DRAIN;
                    state_d      = ST_ERROR;
                end else if (drain_done && pe_layer_quiescent) begin
                    state_d = ST_COMPLETE;
                end
            end

            // -----------------------------------------------------------------
            // ST_COMPLETE: Issue 1-cycle completion pulse with layer ID
            // -----------------------------------------------------------------
            ST_COMPLETE: begin
                if (cmd_valid) begin
                    // Latch new command immediately (pipelined back-to-back chaining)
                    layer_id_d      = cmd_layer_id;
                    pe_mode_d       = cmd_pe_mode;
                    adaptive_en_d   = cmd_adaptive_en;
                    deg_hat_16_d    = cmd_degradation_hat_16;
                    deg_hat_32_d    = cmd_degradation_hat_32;
                    deg_hat_64_d    = cmd_degradation_hat_64;
                    use_ping_pong_d = cmd_use_ping_pong;
                    req_buf_id_d    = cmd_req_buf_id;
                    k_total_d       = cmd_k_total;

                    error_flag_d    = 1'b0;
                    error_code_d    = ERR_NONE;

                    state_d         = ST_VALIDATE;
                end else begin
                    state_d         = ST_IDLE; // Advance cleanly to IDLE when no pending command
                end
            end

            // -----------------------------------------------------------------
            // ST_ERROR: Error hold state until error_clear or reset
            // -----------------------------------------------------------------
            ST_ERROR: begin
                if (error_clear) begin
                    error_flag_d = 1'b0;
                    error_code_d = ERR_NONE;
                    state_d      = ST_IDLE;
                end
            end

            default: state_d = ST_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Sequential Registers
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q         <= ST_IDLE;
            layer_id_q      <= '0;
            pe_mode_q       <= 2'b10; // Safe default: 64-PE
            adaptive_en_q   <= 1'b0;
            deg_hat_16_q    <= '0;
            deg_hat_32_q    <= '0;
            deg_hat_64_q    <= '0;
            use_ping_pong_q <= 1'b0;
            req_buf_id_q    <= 1'b0;
            k_total_q       <= '0;

            done_id_q       <= '0;
            error_flag_q    <= 1'b0;
            error_code_q    <= ERR_NONE;
        end else begin
            state_q         <= state_d;
            layer_id_q      <= layer_id_d;
            pe_mode_q       <= pe_mode_d;
            adaptive_en_q   <= adaptive_en_d;
            deg_hat_16_q    <= deg_hat_16_d;
            deg_hat_32_q    <= deg_hat_32_d;
            deg_hat_64_q    <= deg_hat_64_d;
            use_ping_pong_q <= use_ping_pong_d;
            req_buf_id_q    <= req_buf_id_d;
            k_total_q       <= k_total_d;

            if (state_q == ST_COMPLETE) begin
                done_id_q   <= layer_id_q;
            end

            error_flag_q    <= error_flag_d;
            error_code_q    <= error_code_d;
        end
    end

endmodule
