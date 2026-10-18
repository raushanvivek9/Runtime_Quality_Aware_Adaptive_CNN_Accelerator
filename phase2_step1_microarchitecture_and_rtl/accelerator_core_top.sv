// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Module: accelerator_core_top.sv
// Description: Fully Integrated Top-Level Accelerator Core with 5,184-Byte SRAM,
//              Stall-on-Busy Drain FSM, Sticky K-Progress Diagnostics & 40b MAC
// Specification: Ratified Decisions DEC-P2-01 through DEC-P2-07 & Gate 1 Authorization
// =============================================================================

`timescale 1ns / 1ps

module accelerator_core_top #(
    parameter int ACT_WIDTH    = 16,
    parameter int WEIGHT_WIDTH = 16,
    parameter int ACCUM_WIDTH  = 40,
    parameter int K_WIDTH      = 16,
    parameter int TAG_WIDTH    = 8,
    parameter int SRAM_ADDR_W  = 11,
    parameter int SRAM_DATA_W  = 32
)(
    input  logic                          clk,
    input  logic                          rst_n,
    
    // Slot allocation interface
    input  logic                          slot_alloc_req,
    input  logic [K_WIDTH-1:0]            slot_k_total,
    output logic                          slot_alloc_ready,
    output logic [2:0]                    slot_fsm_state,
    
    // Inbound flit interface
    input  logic                          flit_valid,
    input  logic [TAG_WIDTH-1:0]          flit_tag,
    input  logic [K_WIDTH-1:0]            flit_k_idx,
    input  logic                          flit_is_skip,
    input  logic signed [ACT_WIDTH-1:0]   flit_act_data,
    input  logic                          flit_act_mask, // 1 = non-zero, 0 = exact zero
    input  logic signed [WEIGHT_WIDTH-1:0] flit_weight_data,
    
    // Flit acceptance / status
    output logic                          flit_accepted,
    output logic                          stale_flit_rejected,
    output logic                          seq_error,
    
    // Barrier synchronization (D-10) & Drain Handshake (DEC-P2-03 Option A)
    input  logic                          layer_barrier_req,
    input  logic                          drain_fifo_empty = 1'b1,
    output logic                          slot_quiescent,
    output logic                          drain_enable,
    
    // Datapath outputs
    output logic signed [ACCUM_WIDTH-1:0] accum_result,
    output logic                          sticky_saturation,
    output logic [K_WIDTH-1:0]            k_resolved,
    output logic [K_WIDTH-1:0]            k_executed,
    output logic [K_WIDTH-1:0]            k_skipped,
    output logic                          slot_done,

    // Completion Handshake Interface (Owner Decision Choice B, Pinout Freeze Waiver)
    output logic                          completion_valid,
    input  logic                          completion_ready = 1'b1,

    // Saturation Control (DEC-P2-02 Option B)
    input  logic                          sat_clear = 1'b0,

    // K-Progress Diagnostic & Persistence (DEC-P2-05 Option B)
    input  logic                          seq_error_clear = 1'b0,
    output logic                          sticky_seq_error,
    output logic [K_WIDTH-1:0]            err_failed_k_idx,
    output logic [K_WIDTH-1:0]            err_expected_k_idx,

    // SRAM Interface (DEC-P2-01 Option B / D-11)
    // Port A: Ingestion / Writeback Write Port
    input  logic                          sram_we_a = 1'b0,
    input  logic [SRAM_ADDR_W-1:0]        sram_addr_a = '0,
    input  logic [SRAM_DATA_W-1:0]        sram_din_a = '0,
    input  logic [3:0]                    sram_byte_we_a = 4'd0,
    output logic                          sram_ready_a,

    // Port B: Compute Fetch Read Port
    input  logic                          sram_re_b = 1'b0,
    input  logic [SRAM_ADDR_W-1:0]        sram_addr_b = '0,
    output logic [SRAM_DATA_W-1:0]        sram_dout_b,
    output logic                          sram_rvalid_b,
    output logic                          sram_ready_b,
    output logic                          sram_oob_err
);

    // Internal interconnect signals
    logic        accum_clear;
    logic        internal_drain_enable;
    logic [7:0]  active_gen_tag;
    logic        mac_exec_trigger;
    logic        cycle_skipped;

    assign drain_enable = internal_drain_enable;

    // 1. Slot Lifecycle Controller (D-10, G1-D03, DEC-P2-03 Option A)
    slot_control_unit #(
        .SLOT_ID_WIDTH(4),
        .TAG_WIDTH(TAG_WIDTH)
    ) u_slot_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .alloc_req(slot_alloc_req),
        .alloc_ready(slot_alloc_ready),
        .flit_valid(flit_valid),
        .flit_tag(flit_tag),
        .flit_accepted(flit_accepted),
        .stale_flit_rejected(stale_flit_rejected),
        .slot_computation_done(slot_done),
        .layer_barrier_req(layer_barrier_req),
        .drain_fifo_empty(drain_fifo_empty),
        .slot_quiescent(slot_quiescent),
        .completion_valid(completion_valid),
        .completion_ready(completion_ready),
        .accum_clear(accum_clear),
        .drain_enable(internal_drain_enable),
        .active_gen_tag(active_gen_tag),
        .fsm_state(slot_fsm_state)
    );

    // 2. Resolved-K Progress Tracker (D-09, G1-D04, DEC-P2-05 Option B)
    k_progress_tracker #(
        .K_WIDTH(K_WIDTH)
    ) u_k_tracker (
        .clk(clk),
        .rst_n(rst_n),
        .slot_start(slot_alloc_req && slot_alloc_ready),
        .k_total(slot_k_total),
        .flit_valid(flit_accepted),
        .flit_k_idx(flit_k_idx),
        .flit_is_skip(flit_is_skip),
        .k_expected(),
        .k_resolved(k_resolved),
        .k_executed(k_executed),
        .k_skipped(k_skipped),
        .slot_done(slot_done),
        .seq_error(seq_error),
        .mac_exec_trigger(mac_exec_trigger),
        .seq_error_clear(seq_error_clear),
        .sticky_seq_error(sticky_seq_error),
        .err_failed_k_idx(err_failed_k_idx),
        .err_expected_k_idx(err_expected_k_idx)
    );

    // 3. 40-Bit Saturating MAC Unit with Exact-Zero Bypass (AMD-01..05, G1-D02, DEC-P2-07)
    mac_unit_40b #(
        .ACT_WIDTH(ACT_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) u_mac (
        .clk(clk),
        .rst_n(rst_n),
        .enable(mac_exec_trigger),
        .accum_clear(accum_clear),
        .sat_clear(sat_clear),
        .act_data(flit_act_data),
        .act_mask(flit_act_mask),
        .weight_data(flit_weight_data),
        .accum_out(accum_result),
        .sticky_saturation(sticky_saturation),
        .cycle_skipped(cycle_skipped)
    );

    // 4. Dual-Bank 5,184-Byte Physical SRAM Array (D-11, DEC-P2-01 Option B)
    hybrid_sram_bank #(
        .TOTAL_BYTES(5184),
        .DATA_WIDTH(SRAM_DATA_W),
        .ADDR_WIDTH(SRAM_ADDR_W)
    ) u_sram (
        .clk(clk),
        .rst_n(rst_n),
        .we_a(sram_we_a),
        .addr_a(sram_addr_a),
        .din_a(sram_din_a),
        .byte_we_a(sram_byte_we_a),
        .sram_ready_a(sram_ready_a),
        .re_b(sram_re_b),
        .addr_b(sram_addr_b),
        .dout_b(sram_dout_b),
        .sram_rvalid_b(sram_rvalid_b),
        .sram_ready_b(sram_ready_b),
        .sram_oob_err(sram_oob_err)
    );

endmodule
