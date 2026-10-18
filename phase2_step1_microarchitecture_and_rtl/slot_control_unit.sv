// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Module: slot_control_unit.sv
// Description: Slot Lifecycle FSM, Generation Tag Verification & Barrier Sync
// Specification: Ratified Decision D-10 (Option 10-C) & Gate 1 Decision G1-D03
// =============================================================================

`timescale 1ns / 1ps

module slot_control_unit #(
    parameter int SLOT_ID_WIDTH = 4,
    parameter int TAG_WIDTH     = 8
)(
    input  logic                     clk,
    input  logic                     rst_n,
    
    // Slot allocation interface
    input  logic                     alloc_req,
    output logic                     alloc_ready,
    
    // Flit validation and generation tag interface (D-10, G1-D03)
    input  logic                     flit_valid,
    input  logic [TAG_WIDTH-1:0]     flit_tag,
    output logic                     flit_accepted,
    output logic                     stale_flit_rejected,
    
    // Progress interface
    input  logic                     slot_computation_done,
    
    // Layer drain barrier interface (D-10)
    input  logic                     layer_barrier_req,
    input  logic                     drain_fifo_empty,
    output logic                     slot_quiescent,
    
    // Completion handshake interface (Owner Decision Choice B)
    output logic                     completion_valid,
    input  logic                     completion_ready = 1'b1,
    
    // Datapath control signals
    output logic                     accum_clear,
    output logic                     drain_enable,
    output logic [TAG_WIDTH-1:0]     active_gen_tag,
    output logic [2:0]               fsm_state
);

    // 7-state slot lifecycle definition
    typedef enum logic [2:0] {
        ST_FREE      = 3'b000,
        ST_ALLOCATED = 3'b001,
        ST_COMPUTING = 3'b010,
        ST_DRAINING  = 3'b011,
        ST_QUIESCENT = 3'b100,
        ST_RELEASE   = 3'b101,
        ST_HANDSHAKE = 3'b110
    } slot_state_t;

    slot_state_t state_q, state_d;
    logic [TAG_WIDTH-1:0] gen_tag_q;

    assign fsm_state        = state_q;
    assign active_gen_tag   = gen_tag_q;
    assign alloc_ready      = (state_q == ST_FREE);
    assign slot_quiescent   = (state_q == ST_QUIESCENT) || (state_q == ST_FREE);
    assign completion_valid = (state_q == ST_HANDSHAKE);

    // Generation tag matching (D-10)
    wire tag_matches = (flit_tag == gen_tag_q);
    assign flit_accepted       = flit_valid && (state_q == ST_COMPUTING || state_q == ST_ALLOCATED) && tag_matches;
    assign stale_flit_rejected = flit_valid && !tag_matches;

    // FSM next-state logic
    always_comb begin
        state_d      = state_q;
        accum_clear  = 1'b0;
        drain_enable = 1'b0;

        case (state_q)
            ST_FREE: begin
                if (alloc_req) begin
                    state_d = ST_ALLOCATED;
                end
            end

            ST_ALLOCATED: begin
                // Initialize slot accumulator on first allocation
                accum_clear = 1'b1;
                state_d     = ST_COMPUTING;
            end

            ST_COMPUTING: begin
                if (slot_computation_done || layer_barrier_req) begin
                    state_d = ST_DRAINING;
                end
            end

            ST_DRAINING: begin
                drain_enable = 1'b1;
                if (drain_fifo_empty) begin
                    state_d = ST_HANDSHAKE;
                end
            end

            ST_HANDSHAKE: begin
                drain_enable = 1'b1;
                if (completion_ready) begin
                    state_d = ST_QUIESCENT;
                end
            end

            ST_QUIESCENT: begin
                // Synchronized barrier state: pipeline quiesced
                state_d = ST_RELEASE;
            end

            ST_RELEASE: begin
                // Return credit and reset to free
                state_d = ST_FREE;
            end

            default: state_d = ST_FREE;
        endcase
    end

    // Sequential state and generation tag tracking
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q   <= ST_FREE;
            gen_tag_q <= '0;
        end else begin
            state_q <= state_d;
            // Generation tag increments modulo 256 on each new allocation
            if (state_q == ST_FREE && alloc_req) begin
                gen_tag_q <= gen_tag_q + 1'b1;
            end
        end
    end

endmodule

