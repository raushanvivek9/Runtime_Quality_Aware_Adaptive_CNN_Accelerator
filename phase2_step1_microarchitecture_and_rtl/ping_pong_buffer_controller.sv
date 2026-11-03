// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-04 Ping-Pong Buffer Controller
// Module: ping_pong_buffer_controller.sv
// Description: Synthesizable Ping-Pong Buffer Controller coordinating two logical
//              buffers (A and B) for overlapping data ingestion and computation.
//              Provides strict buffer ownership tracking, mutual exclusion,
//              backpressure, and simultaneous event resolution.
// Specification: TSK-04 Specification, Ratified Decision D-10 & D-11
// =============================================================================

`timescale 1ns / 1ps

module ping_pong_buffer_controller #(
    parameter bit RESET_DEFAULT_PROD_BUF = 1'b0, // 0: Buffer A, 1: Buffer B
    parameter bit RESET_DEFAULT_CONS_BUF = 1'b0  // 0: Buffer A, 1: Buffer B
)(
    input  logic        clk,
    input  logic        rst_n,

    // -------------------------------------------------------------------------
    // Producer Interface (Data Ingestion / DMA / Host Write Channel)
    // -------------------------------------------------------------------------
    output logic        producer_ready,       // High when current target buffer is available (EMPTY)
    input  logic        producer_start,       // Request to start writing into target buffer
    input  logic        producer_done,        // Notification that writing to buffer is complete
    output logic        producer_buf_id,      // 0: Buffer A, 1: Buffer B (target for producer)
    output logic        producer_active,      // High when a buffer is currently being produced
    output logic        producer_stall,       // High when producer requests start but buffer is unavailable
    output logic        producer_err_start,   // Pulse when producer_start is asserted illegally

    // -------------------------------------------------------------------------
    // Consumer Interface (Datapath / PE Array / Compute Read Channel)
    // -------------------------------------------------------------------------
    output logic        consumer_ready,       // High when current target buffer has valid data (READY)
    input  logic        consumer_start,       // Request to start reading from target buffer
    input  logic        consumer_done,        // Notification that reading from buffer is complete
    output logic        consumer_buf_id,      // 0: Buffer A, 1: Buffer B (target for consumer)
    output logic        consumer_active,      // High when a buffer is currently being consumed
    output logic        consumer_stall,       // High when consumer requests start but buffer is not ready
    output logic        consumer_err_start,   // Pulse when consumer_start is asserted illegally

    // -------------------------------------------------------------------------
    // Buffer Status & Invariant Diagnostics
    // -------------------------------------------------------------------------
    output logic [1:0]  buf_state_a,          // 2'b00: EMPTY, 2'b01: PRODUCING, 2'b10: READY, 2'b11: CONSUMING
    output logic [1:0]  buf_state_b,          // 2'b00: EMPTY, 2'b01: PRODUCING, 2'b10: READY, 2'b11: CONSUMING
    output logic        buf_a_empty,
    output logic        buf_a_producing,
    output logic        buf_a_ready,
    output logic        buf_a_consuming,
    output logic        buf_b_empty,
    output logic        buf_b_producing,
    output logic        buf_b_ready,
    output logic        buf_b_consuming,
    output logic        switch_event_pulse,   // 1-cycle pulse upon buffer completion / state change
    output logic        invariant_violation,  // Asserted if internal safety invariants are violated
    output logic [31:0] total_produced_count, // Total buffers successfully produced
    output logic [31:0] total_consumed_count  // Total buffers successfully consumed
);

    // -------------------------------------------------------------------------
    // Buffer Ownership State Encoding (4-state lifecycle per buffer)
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        BUF_EMPTY     = 2'b00, // Unallocated; empty and available for producer write
        BUF_PRODUCING = 2'b01, // Producer is actively writing to this buffer
        BUF_READY     = 2'b10, // Production complete; data valid and waiting for consumer
        BUF_CONSUMING = 2'b11  // Consumer is actively reading from this buffer
    } buf_state_t;

    buf_state_t state_a_q, state_a_d;
    buf_state_t state_b_q, state_b_d;

    // Pointer registers tracking next target buffer in the ping-pong sequence
    logic prod_buf_ptr_q, prod_buf_ptr_d;
    logic cons_buf_ptr_q, cons_buf_ptr_d;

    // Active execution tracking registers
    logic prod_active_q, prod_active_d;
    logic cons_active_q, cons_active_d;
    logic prod_active_buf_q, prod_active_buf_d;
    logic cons_active_buf_q, cons_active_buf_d;

    // Output assignments for buffer states
    assign buf_state_a = state_a_q;
    assign buf_state_b = state_b_q;

    assign buf_a_empty     = (state_a_q == BUF_EMPTY);
    assign buf_a_producing = (state_a_q == BUF_PRODUCING);
    assign buf_a_ready     = (state_a_q == BUF_READY);
    assign buf_a_consuming = (state_a_q == BUF_CONSUMING);

    assign buf_b_empty     = (state_b_q == BUF_EMPTY);
    assign buf_b_producing = (state_b_q == BUF_PRODUCING);
    assign buf_b_ready     = (state_b_q == BUF_READY);
    assign buf_b_consuming = (state_b_q == BUF_CONSUMING);

    // Producer / Consumer active status
    assign producer_active = prod_active_q;
    assign consumer_active = cons_active_q;

    // Buffer selection: if active, drive the actively locked buffer; otherwise drive the next target
    assign producer_buf_id = prod_active_q ? prod_active_buf_q : prod_buf_ptr_q;
    assign consumer_buf_id = cons_active_q ? cons_active_buf_q : cons_buf_ptr_q;

    // -------------------------------------------------------------------------
    // Combinational Readiness & Backpressure Logic
    // -------------------------------------------------------------------------
    // Producer is ready when:
    // 1. Not currently in an active production transaction (unless single-cycle chained transfer)
    // 2. The target buffer pointed to by prod_buf_ptr is BUF_EMPTY
    wire target_prod_buf_empty = (prod_buf_ptr_q == 1'b0) ? (state_a_q == BUF_EMPTY)
                                                          : (state_b_q == BUF_EMPTY);

    assign producer_ready = (!prod_active_q) && target_prod_buf_empty;
    assign producer_stall = producer_start && (!producer_ready);

    // Consumer is ready when:
    // 1. Not currently in an active consumption transaction (unless single-cycle chained transfer)
    // 2. The target buffer pointed to by cons_buf_ptr is BUF_READY
    wire target_cons_buf_ready = (cons_buf_ptr_q == 1'b0) ? (state_a_q == BUF_READY)
                                                          : (state_b_q == BUF_READY);

    assign consumer_ready = (!cons_active_q) && target_cons_buf_ready;
    assign consumer_stall = consumer_start && (!consumer_ready);

    // -------------------------------------------------------------------------
    // Next-State & Handshake Transition Logic
    // -------------------------------------------------------------------------
    logic prod_start_valid;
    logic prod_done_valid;
    logic cons_start_valid;
    logic cons_done_valid;

    always_comb begin
        // Defaults: retain current registered state
        state_a_d         = state_a_q;
        state_b_d         = state_b_q;
        prod_buf_ptr_d    = prod_buf_ptr_q;
        cons_buf_ptr_d    = cons_buf_ptr_q;
        prod_active_d     = prod_active_q;
        cons_active_d     = cons_active_q;
        prod_active_buf_d = prod_active_buf_q;
        cons_active_buf_d = cons_active_buf_q;

        producer_err_start = 1'b0;
        consumer_err_start = 1'b0;

        prod_start_valid = 1'b0;
        prod_done_valid  = 1'b0;
        cons_start_valid = 1'b0;
        cons_done_valid  = 1'b0;

        // ---------------------------------------------------------------------
        // 1. Producer Transaction Processing
        // ---------------------------------------------------------------------
        // Producer Done (retire active transaction)
        if (producer_done) begin
            if (prod_active_q) begin
                prod_done_valid = 1'b1;
                // Transition active buffer from PRODUCING -> READY
                if (prod_active_buf_q == 1'b0) begin
                    state_a_d = BUF_READY;
                end else begin
                    state_b_d = BUF_READY;
                end
                prod_active_d  = 1'b0;
                prod_buf_ptr_d = ~prod_active_buf_q; // Toggle pointer to next candidate buffer
            end
        end

        // Producer Start (allocate buffer to producer)
        if (producer_start) begin
            if (producer_ready) begin
                prod_start_valid = 1'b1;
                prod_active_d    = 1'b1;
                prod_active_buf_d = prod_buf_ptr_q;

                // Transition target buffer from EMPTY -> PRODUCING
                if (prod_buf_ptr_q == 1'b0) begin
                    state_a_d = BUF_PRODUCING;
                end else begin
                    state_b_d = BUF_PRODUCING;
                end
            end else if (producer_done && prod_active_q) begin
                // Support single-cycle chained transfer: retiring buffer X and starting buffer Y
                // Check if the other buffer Y is EMPTY
                logic next_buf_id;
                next_buf_id = ~prod_active_buf_q;
                if ((next_buf_id == 1'b0 && state_a_q == BUF_EMPTY) ||
                    (next_buf_id == 1'b1 && state_b_q == BUF_EMPTY)) begin
                    prod_start_valid  = 1'b1;
                    prod_active_d     = 1'b1;
                    prod_active_buf_d = next_buf_id;
                    if (next_buf_id == 1'b0) state_a_d = BUF_PRODUCING;
                    else                     state_b_d = BUF_PRODUCING;
                end else begin
                    producer_err_start = 1'b1;
                end
            end else begin
                // Illegal start request (target buffer not empty or producer busy)
                producer_err_start = 1'b1;
            end
        end

        // ---------------------------------------------------------------------
        // 2. Consumer Transaction Processing
        // ---------------------------------------------------------------------
        // Consumer Done (retire active transaction)
        if (consumer_done) begin
            if (cons_active_q) begin
                cons_done_valid = 1'b1;
                // Transition active buffer from CONSUMING -> EMPTY (available for reuse)
                if (cons_active_buf_q == 1'b0) begin
                    state_a_d = BUF_EMPTY;
                end else begin
                    state_b_d = BUF_EMPTY;
                end
                cons_active_d  = 1'b0;
                cons_buf_ptr_d = ~cons_active_buf_q; // Toggle pointer to next candidate buffer
            end
        end

        // Consumer Start (allocate buffer to consumer)
        if (consumer_start) begin
            if (consumer_ready) begin
                cons_start_valid  = 1'b1;
                cons_active_d     = 1'b1;
                cons_active_buf_d = cons_buf_ptr_q;

                // Transition target buffer from READY -> CONSUMING
                if (cons_buf_ptr_q == 1'b0) begin
                    state_a_d = BUF_CONSUMING;
                end else begin
                    state_b_d = BUF_CONSUMING;
                end
            end else if (consumer_done && cons_active_q) begin
                // Support single-cycle chained transfer: retiring buffer X and starting buffer Y
                logic next_buf_id;
                next_buf_id = ~cons_active_buf_q;
                if ((next_buf_id == 1'b0 && state_a_q == BUF_READY) ||
                    (next_buf_id == 1'b1 && state_b_q == BUF_READY)) begin
                    cons_start_valid  = 1'b1;
                    cons_active_d     = 1'b1;
                    cons_active_buf_d = next_buf_id;
                    if (next_buf_id == 1'b0) state_a_d = BUF_CONSUMING;
                    else                     state_b_d = BUF_CONSUMING;
                end else begin
                    consumer_err_start = 1'b1;
                end
            end else begin
                // Illegal start request (target buffer not ready or consumer busy)
                consumer_err_start = 1'b1;
            end
        end
    end

    // Pulse whenever a buffer completes production or consumption
    assign switch_event_pulse = prod_done_valid | cons_done_valid;

    // -------------------------------------------------------------------------
    // Sequential Registers & Counters
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_a_q            <= BUF_EMPTY;
            state_b_q            <= BUF_EMPTY;
            prod_buf_ptr_q       <= RESET_DEFAULT_PROD_BUF;
            cons_buf_ptr_q       <= RESET_DEFAULT_CONS_BUF;
            prod_active_q        <= 1'b0;
            cons_active_q        <= 1'b0;
            prod_active_buf_q    <= RESET_DEFAULT_PROD_BUF;
            cons_active_buf_q    <= RESET_DEFAULT_CONS_BUF;
            total_produced_count <= '0;
            total_consumed_count <= '0;
        end else begin
            state_a_q         <= state_a_d;
            state_b_q         <= state_b_d;
            prod_buf_ptr_q    <= prod_buf_ptr_d;
            cons_buf_ptr_q    <= cons_buf_ptr_d;
            prod_active_q     <= prod_active_d;
            cons_active_q     <= cons_active_d;
            prod_active_buf_q <= prod_active_buf_d;
            cons_active_buf_q <= cons_active_buf_d;

            if (prod_done_valid) begin
                total_produced_count <= total_produced_count + 1'b1;
            end
            if (cons_done_valid) begin
                total_consumed_count <= total_consumed_count + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Invariant Checking & Verification Monitor
    // -------------------------------------------------------------------------
    // Safety Invariants:
    // 1. producer_active must match exactly one buffer in BUF_PRODUCING
    // 2. consumer_active must match exactly one buffer in BUF_CONSUMING
    // 3. No buffer may be simultaneously in both producing and consuming (guaranteed by enum)
    // 4. Invariant violation asserts if active flags diverge from actual buffer states
    wire inv_prod_mismatch = prod_active_q ^ ((state_a_q == BUF_PRODUCING) || (state_b_q == BUF_PRODUCING));
    wire inv_cons_mismatch = cons_active_q ^ ((state_a_q == BUF_CONSUMING) || (state_b_q == BUF_CONSUMING));
    wire inv_dual_prod     = (state_a_q == BUF_PRODUCING) && (state_b_q == BUF_PRODUCING);
    wire inv_dual_cons     = (state_a_q == BUF_CONSUMING) && (state_b_q == BUF_CONSUMING);

    assign invariant_violation = inv_prod_mismatch | inv_cons_mismatch | inv_dual_prod | inv_dual_cons;

endmodule

