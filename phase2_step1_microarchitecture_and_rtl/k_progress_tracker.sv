// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Module: k_progress_tracker.sv
// Description: In-Order Scalar Resolved-K Progress Tracker
// Specification: Ratified Decision D-09 (Option 09-A) & Gate 1 Decision G1-D04
// =============================================================================

`timescale 1ns / 1ps

module k_progress_tracker #(
    parameter int K_WIDTH = 16
)(
    input  logic               clk,
    input  logic               rst_n,
    
    // Slot initialization
    input  logic               slot_start,
    input  logic [K_WIDTH-1:0] k_total,
    
    // Arriving flit token interface
    input  logic               flit_valid,
    input  logic [K_WIDTH-1:0] flit_k_idx,
    input  logic               flit_is_skip,
    
    // Status and progress outputs
    output logic [K_WIDTH-1:0] k_expected,
    output logic [K_WIDTH-1:0] k_resolved,
    output logic [K_WIDTH-1:0] k_executed,
    output logic [K_WIDTH-1:0] k_skipped,
    output logic               slot_done,
    output logic               seq_error,
    output logic               mac_exec_trigger,

    // Diagnostic & Persistence Interface (DEC-P2-05 Option B)
    input  logic               seq_error_clear,
    output logic               sticky_seq_error,
    output logic [K_WIDTH-1:0] err_failed_k_idx,
    output logic [K_WIDTH-1:0] err_expected_k_idx
);

    // In-order sequence comparison
    logic in_order;
    assign in_order = flit_valid && (flit_k_idx == k_expected);

    // Done signal when resolved counter equals requested reduction depth
    assign slot_done = (k_resolved == k_total) && (k_total > '0);

    // Sequence error when incoming flit violates strict monotonic in-order delivery
    assign seq_error = flit_valid && (flit_k_idx != k_expected);

    // MAC execution trigger (only for valid in-order compute flits)
    assign mac_exec_trigger = in_order && (!flit_is_skip);

    // Sticky error and diagnostic capture registers (DEC-P2-05 Option B)
    logic                   sticky_seq_error_q;
    logic [K_WIDTH-1:0]     err_failed_k_idx_q;
    logic [K_WIDTH-1:0]     err_expected_k_idx_q;

    assign sticky_seq_error   = sticky_seq_error_q;
    assign err_failed_k_idx   = err_failed_k_idx_q;
    assign err_expected_k_idx = err_expected_k_idx_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_expected <= '0;
            k_resolved <= '0;
            k_executed <= '0;
            k_skipped  <= '0;
        end else if (slot_start) begin
            k_expected <= '0;
            k_resolved <= '0;
            k_executed <= '0;
            k_skipped  <= '0;
        end else if (in_order && !slot_done) begin
            k_expected <= k_expected + 1'b1;
            k_resolved <= k_resolved + 1'b1;
            if (flit_is_skip) begin
                k_skipped  <= k_skipped + 1'b1;
            end else begin
                k_executed <= k_executed + 1'b1;
            end
        end
    end

    // Sequence error latching and diagnostic capture
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sticky_seq_error_q   <= 1'b0;
            err_failed_k_idx_q   <= '0;
            err_expected_k_idx_q <= '0;
        end else if (slot_start || seq_error_clear) begin
            sticky_seq_error_q   <= 1'b0;
            err_failed_k_idx_q   <= '0;
            err_expected_k_idx_q <= '0;
        end else if (seq_error && !sticky_seq_error_q) begin
            // First-fault capture: capture indices on initial violation
            sticky_seq_error_q   <= 1'b1;
            err_failed_k_idx_q   <= flit_k_idx;
            err_expected_k_idx_q <= k_expected;
        end
    end

endmodule

