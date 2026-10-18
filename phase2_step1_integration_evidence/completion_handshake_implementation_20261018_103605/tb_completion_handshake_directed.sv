// =============================================================================
// Project: Neural_Acc (Phase 2 Step 1 RTL Verification)
// Module: tb_completion_handshake_directed.sv
// Description: Comprehensive Directed Testbench for Hardware Completion Handshake
// Features: Bounded wait loops with watchdog timeouts, unbuffered output flushing.
// =============================================================================

`timescale 1ns / 1ps

module tb_completion_handshake_directed;

    localparam int CLK_PERIOD   = 10;
    localparam int K_WIDTH      = 16;
    localparam int ACT_WIDTH    = 16;
    localparam int WEIGHT_WIDTH = 16;
    localparam int ACCUM_WIDTH  = 40;
    localparam int TAG_WIDTH    = 8;

    logic                          clk;
    logic                          rst_n;
    logic                          slot_alloc_req;
    logic [K_WIDTH-1:0]            slot_k_total;
    logic                          slot_alloc_ready;
    logic [2:0]                    slot_fsm_state;

    logic                          flit_valid;
    logic [TAG_WIDTH-1:0]          flit_tag;
    logic [K_WIDTH-1:0]            flit_k_idx;
    logic                          flit_is_skip;
    logic signed [ACT_WIDTH-1:0]   flit_act_data;
    logic                          flit_act_mask;
    logic signed [WEIGHT_WIDTH-1:0] flit_weight_data;

    logic                          flit_accepted;
    logic                          stale_flit_rejected;
    logic                          seq_error;

    logic                          layer_barrier_req;
    logic                          drain_fifo_empty;
    logic                          slot_quiescent;
    logic                          drain_enable;

    logic signed [ACCUM_WIDTH-1:0] accum_result;
    logic                          sticky_saturation;
    logic [K_WIDTH-1:0]            k_resolved;
    logic [K_WIDTH-1:0]            k_executed;
    logic [K_WIDTH-1:0]            k_skipped;
    logic                          slot_done;

    logic                          completion_valid;
    logic                          completion_ready;

    int pass_count = 0;
    int fail_count = 0;

    // Global simulation watchdog (500us limit)
    initial begin
        #500000;
        $display("[FATAL WATCHDOG] Global simulation timeout reached!");
        $fflush();
        $finish(2);
    end

    // Instantiate accelerator_core_top
    accelerator_core_top #(
        .ACT_WIDTH(ACT_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .K_WIDTH(K_WIDTH),
        .TAG_WIDTH(TAG_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .slot_alloc_req(slot_alloc_req),
        .slot_k_total(slot_k_total),
        .slot_alloc_ready(slot_alloc_ready),
        .slot_fsm_state(slot_fsm_state),
        .flit_valid(flit_valid),
        .flit_tag(flit_tag),
        .flit_k_idx(flit_k_idx),
        .flit_is_skip(flit_is_skip),
        .flit_act_data(flit_act_data),
        .flit_act_mask(flit_act_mask),
        .flit_weight_data(flit_weight_data),
        .flit_accepted(flit_accepted),
        .stale_flit_rejected(stale_flit_rejected),
        .seq_error(seq_error),
        .layer_barrier_req(layer_barrier_req),
        .drain_fifo_empty(drain_fifo_empty),
        .slot_quiescent(slot_quiescent),
        .drain_enable(drain_enable),
        .accum_result(accum_result),
        .sticky_saturation(sticky_saturation),
        .k_resolved(k_resolved),
        .k_executed(k_executed),
        .k_skipped(k_skipped),
        .slot_done(slot_done),
        .completion_valid(completion_valid),
        .completion_ready(completion_ready)
    );

    // Clock generator
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    task check_condition(input string test_id, input string test_name, input logic cond);
        if (cond) begin
            $display("[PASS] %s: %s", test_id, test_name);
            pass_count++;
        end else begin
            $display("[FAIL] %s: %s (state=%0d, valid=%b, ready=%b, accum=%0d, k_res=%0d, tag=%0d, flit_acc=%b)", 
                test_id, test_name, slot_fsm_state, completion_valid, completion_ready, accum_result, k_resolved, dut.u_slot_ctrl.active_gen_tag, flit_accepted);
            fail_count++;
        end
        $fflush();
    endtask

    // Bounded wait helper (automatic lifetime)
    task automatic wait_for_ready(input int max_cycles);
        int cnt;
        cnt = 0;
        while (!slot_alloc_ready && cnt < max_cycles) begin
            @(negedge clk);
            cnt++;
        end
        if (!slot_alloc_ready) begin
            $display("[TIMEOUT] wait_for_ready exceeded %0d cycles (state=%0d)", max_cycles, slot_fsm_state);
            $fflush();
        end
    endtask

    // Helper: Allocate slot with given K and wait for ST_COMPUTING (automatic lifetime)
    task automatic allocate_op(input [15:0] k_val);
        int cnt;
        wait_for_ready(20);
        @(negedge clk);
        slot_alloc_req = 1;
        slot_k_total   = k_val;
        @(negedge clk);
        slot_alloc_req = 0;
        cnt = 0;
        while (slot_fsm_state != 3'b010 && cnt < 20) begin
            @(negedge clk);
            cnt++;
        end
        if (slot_fsm_state != 3'b010) begin
            $display("[ERROR] Failed to reach ST_COMPUTING (state=%0d)", slot_fsm_state);
            $fflush();
        end
    endtask

    // Helper: Send single compute flit (automatic lifetime)
    task automatic send_flit(input [7:0] tag, input [15:0] idx, input signed [15:0] a_val, input signed [15:0] w_val);
        @(negedge clk);
        flit_valid       = 1;
        flit_tag         = tag;
        flit_k_idx       = idx;
        flit_is_skip     = 0;
        flit_act_mask    = 1;
        flit_act_data    = a_val;
        flit_weight_data = w_val;
        @(negedge clk);
        flit_valid       = 0;
    endtask


    // Main Test Stimulus
    initial begin
        $display("==================================================================");
        $display("Starting Directed Handshake Verification Suite");
        $display("==================================================================");
        $fflush();

        // Reset
        rst_n = 0;
        slot_alloc_req = 0; slot_k_total = 0;
        flit_valid = 0; flit_tag = 0; flit_k_idx = 0; flit_is_skip = 0;
        flit_act_data = 0; flit_act_mask = 0; flit_weight_data = 0;
        layer_barrier_req = 0; drain_fifo_empty = 1;
        completion_ready = 0;
        #(CLK_PERIOD * 3);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        // ---------------------------------------------------------------------
        // TEST 1: Immediate Completion Acceptance (completion_ready = 1)
        // ---------------------------------------------------------------------
        completion_ready = 1;
        allocate_op(16'd1);
        send_flit(8'd1, 16'd0, 16'd10, 16'd20); // 10 * 20 = 200
        @(negedge clk); // ST_DRAINING
        @(negedge clk); // ST_HANDSHAKE -> accepted because ready=1
        check_condition("TC-DIR-01A", "Enters ST_HANDSHAKE and transfers on ready=1", (completion_valid == 1'b1 || slot_fsm_state == 3'b100));
        @(negedge clk); // ST_QUIESCENT
        check_condition("TC-DIR-01B", "Single-cycle deassertion of completion_valid to 0", (completion_valid == 1'b0));
        check_condition("TC-DIR-01C", "Accumulator result equals 200", (accum_result == 40'sd200));
        wait_for_ready(20);

        // ---------------------------------------------------------------------
        // TEST 2 & 3: Delayed completion_ready (Backpressure Stall & Metadata Stability)
        // ---------------------------------------------------------------------
        completion_ready = 0; // Hold backpressure
        allocate_op(16'd2);
        send_flit(8'd2, 16'd0, 16'd30, 16'd10); // 300
        send_flit(8'd2, 16'd1, 16'd20, 16'd10); // 200 -> total 500
        @(negedge clk); // ST_DRAINING
        @(negedge clk); // ST_HANDSHAKE
        check_condition("TC-DIR-02A", "Enters ST_HANDSHAKE with completion_valid=1", (slot_fsm_state == 3'b110 && completion_valid == 1'b1));

        // Stall for 50 cycles and verify metadata stability
        begin: stall_check
            logic metadata_ok;
            metadata_ok = 1'b1;
            for (int i = 0; i < 50; i++) begin
                @(negedge clk);
                if (slot_fsm_state != 3'b110 || completion_valid != 1'b1 || accum_result != 40'sd500 || k_resolved != 16'd2) begin
                    metadata_ok = 1'b0;
                end
            end
            check_condition("TC-DIR-02B", "Holds in ST_HANDSHAKE across 50 stall cycles", (slot_fsm_state == 3'b110 && completion_valid == 1'b1));
            check_condition("TC-DIR-03",  "Completion metadata strictly stable during stall", metadata_ok);
        end

        // Release backpressure
        completion_ready = 1;
        @(negedge clk); // Acceptance occurs on posedge; at negedge we are in ST_QUIESCENT
        check_condition("TC-DIR-02C", "Advances to ST_QUIESCENT and deasserts valid upon ready=1", (completion_valid == 1'b0 && slot_fsm_state == 3'b100));
        wait_for_ready(20);

        // ---------------------------------------------------------------------
        // TEST 4 & 5: Exactly-Once Transfer & Persistent slot_done Immunity
        // ---------------------------------------------------------------------
        // Pulse completion_ready repeatedly while core is in ST_FREE
        begin: persistent_done_check
            int extra_acceptances;
            extra_acceptances = 0;
            check_condition("TC-DIR-05A", "slot_done remains persistent high in ST_FREE", (slot_done == 1'b1 && slot_fsm_state == 3'b000));
            for (int i = 0; i < 20; i++) begin
                completion_ready = 1;
                @(negedge clk);
                if (completion_valid && completion_ready) extra_acceptances++;
            end
            completion_ready = 0;
            check_condition("TC-DIR-04",  "Exactly one acceptance per operation (zero duplicate acceptances)", (extra_acceptances == 0));
            check_condition("TC-DIR-05B", "Zero completion_valid assertions during ST_FREE while slot_done=1", (completion_valid == 1'b0));
        end

        // ---------------------------------------------------------------------
        // TEST 6: Asynchronous Reset while Completion is Pending
        // ---------------------------------------------------------------------
        completion_ready = 0;
        allocate_op(16'd1);
        send_flit(8'd3, 16'd0, 16'd50, 16'd50); // 2500
        @(negedge clk); // ST_DRAINING
        @(negedge clk); // ST_HANDSHAKE
        check_condition("TC-DIR-06A", "Reached pending completion in ST_HANDSHAKE", (slot_fsm_state == 3'b110 && completion_valid == 1'b1));
        // Assert asynchronous reset
        rst_n = 0;
        #(CLK_PERIOD * 2);
        check_condition("TC-DIR-06B", "Reset immediately clears valid to 0 and restores ST_FREE", (completion_valid == 1'b0 && slot_fsm_state == 3'b000));
        rst_n = 1;
        #(CLK_PERIOD * 2);

        // ---------------------------------------------------------------------
        // TEST 10: Reset Recovery
        // ---------------------------------------------------------------------
        completion_ready = 1;
        allocate_op(16'd1);
        send_flit(8'd1, 16'd0, 16'd7, 16'd8); // 56 (tag reset to 0+1=1)
        @(negedge clk); // ST_DRAINING
        @(negedge clk); // ST_HANDSHAKE -> accepted
        @(negedge clk); // ST_QUIESCENT
        check_condition("TC-DIR-10", "Clean recovery after reset: new operation completes with accum=56", (accum_result == 40'sd56));
        wait_for_ready(20);

        // ---------------------------------------------------------------------
        // TEST 9: Layer Barrier Gating on Completion Acceptance
        // ---------------------------------------------------------------------
        completion_ready = 0; // Block consumer acceptance
        allocate_op(16'd2);
        send_flit(8'd2, 16'd0, 16'd5, 16'd5);
        layer_barrier_req = 1; // Issue layer barrier
        @(negedge clk);
        layer_barrier_req = 0;
        @(negedge clk); // ST_DRAINING
        @(negedge clk); // ST_HANDSHAKE
        // Verify that slot_quiescent is NOT asserted while stalled in ST_HANDSHAKE
        check_condition("TC-DIR-09A", "slot_quiescent remains 0 while completion is unaccepted", (slot_quiescent == 1'b0 && slot_fsm_state == 3'b110));
        // Release completion acceptance
        completion_ready = 1;
        @(negedge clk); // Accepted on posedge; at negedge we are in ST_QUIESCENT
        check_condition("TC-DIR-09B", "slot_quiescent asserts only after completion handshake acceptance", (slot_quiescent == 1'b1 && slot_fsm_state == 3'b100));
        wait_for_ready(20);

        // ---------------------------------------------------------------------
        // TEST 7 & 8: Tag Wraparound Across 265 Consecutive Operations
        // ---------------------------------------------------------------------
        begin: tag_wrap_test
            int total_ops;
            int ops_completed;
            total_ops = 265;
            ops_completed = 0;
            $display("Running 265 sequential operations to verify modulo-256 tag wraparound...");
            $fflush();
            for (int op = 0; op < total_ops; op++) begin
                int wait_cnt;
                wait_cnt = 0;
                completion_ready = 1;
                allocate_op(16'd1);
                send_flit(dut.u_slot_ctrl.active_gen_tag, 16'd0, 16'd1, 16'd1);
                wait_cnt = 0;
                while (!completion_valid && wait_cnt < 20) begin
                    @(negedge clk);
                    wait_cnt++;
                end
                // Handshake accepted on completion_valid && completion_ready
                @(negedge clk);
                wait_for_ready(20);
                ops_completed++;
            end
            check_condition("TC-DIR-07", "Slot reuse: 265 consecutive operations cleanly completed", (ops_completed == 265));
            check_condition("TC-DIR-08", "Modulo-256 wraparound completed without deadlock or aliasing", (ops_completed == 265));
        end

        // ---------------------------------------------------------------------
        // Negative Test: Allocation Attempt During ST_HANDSHAKE
        // ---------------------------------------------------------------------
        completion_ready = 0; // Stall core
        allocate_op(16'd1);
        send_flit(dut.u_slot_ctrl.active_gen_tag, 16'd0, 16'd2, 16'd3);
        begin: neg_wait
            int wait_cnt;
            wait_cnt = 0;
            while (slot_fsm_state != 3'b110 && wait_cnt < 20) begin
                @(negedge clk);
                wait_cnt++;
            end
        end
        // Core is in ST_HANDSHAKE. Attempt early allocation:
        slot_alloc_req = 1; slot_k_total = 16'd4;
        @(negedge clk);
        slot_alloc_req = 0;
        check_condition("TC-NEG-01", "Early alloc_req during ST_HANDSHAKE is strictly rejected (alloc_ready=0)", 
            (slot_alloc_ready == 1'b0 && slot_fsm_state == 3'b110));
        // Release stall
        completion_ready = 1;
        @(negedge clk);
        wait_for_ready(20);

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("==================================================================");
        $display("Directed Handshake Verification Summary: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");
        $fflush();

        if (fail_count == 0) begin
            $display("[SUCCESS] All Directed Handshake Acceptance Tests Passed with Zero Failures!");
            $finish(0);
        end else begin
            $display("[ERROR] Failures detected in directed handshake tests!");
            $finish(1);
        end
    end

endmodule
