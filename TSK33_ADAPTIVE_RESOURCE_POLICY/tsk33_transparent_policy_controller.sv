// =============================================================================
// Module: tsk33_transparent_policy_controller
// Project: Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation
// Description:
//   Transparent, deterministic hardware resource allocation controller for
//   Neural_Acc. Replaces obsolete degradation-estimate comparators with explicit,
//   measurable latency budgets, resource caps, and optimization objectives:
//
//   Policy 0 (Policy A: Minimum-Resource / Energy-Priority):
//     Selects the smallest PE configuration (16-PE, 32-PE, 64-PE) that satisfies:
//       1. Total Latency <= latency_budget_cycles
//       2. Active PEs   <= max_active_pe_limit
//
//   Policy 1 (Policy B: Minimum-Latency / Performance-Priority):
//     Selects the fastest PE configuration (lowest latency) that satisfies:
//       1. Active PEs <= max_active_pe_limit
//
//   Fallback Rule:
//     If no configuration satisfies both constraints, asserts fallback_asserted = 1'b1
//     and selects the configuration that best respects the active PE limit.
//
//   Safety & Invalid Cap Enforcement (TSK-35A Correction):
//     If max_active_pe_limit < 16 (e.g. 0 or 15), no physical hardware mode
//     is supported. The controller asserts invalid_pe_limit = 1'b1, deasserts
//     execution_enable = 1'b0, drives resolved_pe_mode = 2'b11 (INVALID), and
//     clears active_pe_count = 0, positively blocking unauthorized compute execution.
// =============================================================================

`timescale 1ns / 1ps

module tsk33_transparent_policy_controller #(
    parameter int LATENCY_16PE_CYCLES = 38225,
    parameter int LATENCY_32PE_CYCLES = 19121,
    parameter int LATENCY_64PE_CYCLES = 9569
)(
    input  logic        clk,
    input  logic        rst_n,

    // Command Handshake
    input  logic        cmd_valid,
    output logic        cmd_ready,

    // Policy Configuration Descriptors
    input  logic        policy_select,          // 0 = Policy A (Min-Resource), 1 = Policy B (Min-Latency)
    input  logic [31:0] latency_budget_cycles,  // Maximum permitted total execution cycles
    input  logic [7:0]  max_active_pe_limit,    // Maximum active PEs allowed (16, 32, 64)

    // Resolved Mode Outputs
    output logic [1:0]  resolved_pe_mode,       // 00: 16-PE, 01: 32-PE, 10: 64-PE, 11: INVALID/BLOCKED
    output logic [7:0]  active_pe_count,        // 16, 32, 64 (0 when invalid)
    output logic [3:0]  channel_passes,         // 4, 2, 1 (0 when invalid)
    output logic        fallback_asserted,      // Asserted when constraints could not be jointly met
    output logic        budget_violation,       // Asserted if selected mode exceeds latency budget
    output logic        invalid_pe_limit,       // Asserted when max_active_pe_limit < 16
    output logic        execution_enable        // 1 = Valid configuration permitted to execute; 0 = Blocked/Invalid
);

    // Feasibility evaluation
    logic feas_16;
    logic feas_32;
    logic feas_64;
    logic pe_limit_valid;

    always_comb begin
        pe_limit_valid = (max_active_pe_limit >= 8'd16);
        feas_16        = (LATENCY_16PE_CYCLES <= latency_budget_cycles) && (max_active_pe_limit >= 8'd16);
        feas_32        = (LATENCY_32PE_CYCLES <= latency_budget_cycles) && (max_active_pe_limit >= 8'd32);
        feas_64        = (LATENCY_64PE_CYCLES <= latency_budget_cycles) && (max_active_pe_limit >= 8'd64);
    end

    // Combinational Mode Selection Logic
    logic [1:0] next_pe_mode;
    logic       next_fallback;
    logic       next_violation;
    logic       next_invalid;
    logic       next_exec_en;

    always_comb begin
        next_pe_mode   = 2'b10; // Default 64-PE
        next_fallback  = 1'b0;
        next_violation = 1'b0;
        next_invalid   = 1'b0;
        next_exec_en   = 1'b1;

        if (!pe_limit_valid) begin
            // -------------------------------------------------------------
            // TSK-35A CORRECTION: INVALID RESOURCE CAP (Pmax < 16)
            // No physical hardware configuration can satisfy P <= Pmax.
            // Explicitly assert invalid_pe_limit, deassert execution_enable,
            // and drive resolved_pe_mode = 2'b11 to block downstream compute!
            // -------------------------------------------------------------
            next_pe_mode   = 2'b11; // 2'b11: Explicit INVALID / NO_MODE encoding
            next_fallback  = 1'b1;  // Constraint cannot be satisfied
            next_violation = 1'b1;  // Resource constraint violated
            next_invalid   = 1'b1;  // Explicit invalid PE limit flag
            next_exec_en   = 1'b0;  // BLOCK execution to prevent unauthorized hardware compute!
        end else if (policy_select == 1'b0) begin
            // -------------------------------------------------------------
            // POLICY A: Minimum-Resource Allocation (Energy Priority)
            // Objective: Choose smallest feasible active PE count
            // -------------------------------------------------------------
            next_invalid = 1'b0;
            next_exec_en = 1'b1;

            if (feas_16) begin
                next_pe_mode   = 2'b00; // 16-PE
                next_fallback  = 1'b0;
                next_violation = 1'b0;
            end else if (feas_32) begin
                next_pe_mode   = 2'b01; // 32-PE
                next_fallback  = 1'b0;
                next_violation = 1'b0;
            end else if (feas_64) begin
                next_pe_mode   = 2'b10; // 64-PE
                next_fallback  = 1'b0;
                next_violation = 1'b0;
            end else begin
                // Infeasible jointly: deadline exceeded, but PE limit is valid (>= 16).
                // Fallback to highest throughput mode allowed by PE limit.
                next_fallback  = 1'b1;
                next_violation = 1'b1;
                if (max_active_pe_limit >= 8'd64) begin
                    next_pe_mode = 2'b10; // 64-PE (fastest)
                end else if (max_active_pe_limit >= 8'd32) begin
                    next_pe_mode = 2'b01; // 32-PE
                end else begin
                    next_pe_mode = 2'b00; // 16-PE
                end
            end
        end else begin
            // -------------------------------------------------------------
            // POLICY B: Minimum-Latency Allocation (Throughput Priority)
            // Objective: Choose fastest feasible mode respecting PE limit
            // -------------------------------------------------------------
            next_invalid = 1'b0;
            next_exec_en = 1'b1;

            if (max_active_pe_limit >= 8'd64) begin
                next_pe_mode   = 2'b10; // 64-PE (9,569 cycles)
                next_fallback  = 1'b0;
                next_violation = (LATENCY_64PE_CYCLES > latency_budget_cycles);
            end else if (max_active_pe_limit >= 8'd32) begin
                next_pe_mode   = 2'b01; // 32-PE (19,121 cycles)
                next_fallback  = 1'b0;
                next_violation = (LATENCY_32PE_CYCLES > latency_budget_cycles);
            end else begin // max_active_pe_limit >= 8'd16
                next_pe_mode   = 2'b00; // 16-PE (38,225 cycles)
                next_fallback  = 1'b0;
                next_violation = (LATENCY_16PE_CYCLES > latency_budget_cycles);
            end
        end
    end

    // Sequential Output Registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resolved_pe_mode  <= 2'b10;
            active_pe_count   <= 8'd64;
            channel_passes    <= 4'd1;
            fallback_asserted <= 1'b0;
            budget_violation  <= 1'b0;
            invalid_pe_limit  <= 1'b0;
            execution_enable  <= 1'b0; // Inactive / quiescent upon reset
            cmd_ready         <= 1'b1;
        end else begin
            cmd_ready <= 1'b1;
            if (cmd_valid && cmd_ready) begin
                resolved_pe_mode  <= next_pe_mode;
                fallback_asserted <= next_fallback;
                budget_violation  <= next_violation;
                invalid_pe_limit  <= next_invalid;
                execution_enable  <= next_exec_en;

                case (next_pe_mode)
                    2'b00: begin
                        active_pe_count <= 8'd16;
                        channel_passes  <= 4'd4;
                    end
                    2'b01: begin
                        active_pe_count <= 8'd32;
                        channel_passes  <= 4'd2;
                    end
                    2'b10: begin
                        active_pe_count <= 8'd64;
                        channel_passes  <= 4'd1;
                    end
                    default: begin // 2'b11: INVALID / BLOCKED
                        active_pe_count <= 8'd0;
                        channel_passes  <= 4'd0;
                    end
                endcase
            end
        end
    end

endmodule
