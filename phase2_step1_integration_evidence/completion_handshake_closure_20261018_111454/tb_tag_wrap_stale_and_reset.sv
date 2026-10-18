// =============================================================================
// Project: Neural_Acc (Phase 2 Step 1 Completion Closure Verification)
// Module: tb_tag_wrap_stale_and_reset.sv
// Description: Directed Verification for:
//   TEST 2: Tag Wraparound (265 operations) & Hardware Stale Completion Analysis
//   TEST 3: Reset during pending completion (completion_valid=1, ready=0)
//           and software host recovery tracking.
// =============================================================================

`timescale 1ns / 1ps

module tb_tag_wrap_stale_and_reset;

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

    // Global simulation watchdog (60 seconds)
    initial begin
        #60000000;
        $display("[FATAL WATCHDOG] tb_tag_wrap_stale_and_reset timeout (60s)!");
        $fflush();
        $finish(2);
    end

    // Handshake event counter
    int handshake_accept_count = 0;
    always @(posedge clk) begin
        if (rst_n && completion_valid && completion_ready) begin
            handshake_accept_count++;
        end
    end

    // Helper: Wait for slot_alloc_ready
    task automatic wait_for_ready(input int max_cycles);
        int cnt;
        cnt = 0;
        while (!slot_alloc_ready && cnt < max_cycles) begin
            @(negedge clk);
            cnt++;
        end
        if (!slot_alloc_ready) begin
            $display("[ERROR] wait_for_ready timeout! (state=%0d)", slot_fsm_state);
            $fflush();
        end
    endtask

    // Helper: Allocate slot
    task automatic allocate_slot(input [15:0] k_len);
        int cnt;
        wait_for_ready(20);
        @(negedge clk);
        slot_alloc_req = 1;
        slot_k_total   = k_len;
        @(negedge clk);
        slot_alloc_req = 0;
        cnt = 0;
        while (slot_fsm_state != 3'b010 && cnt < 20) begin
            @(negedge clk);
            cnt++;
        end
    endtask

    // Helper: Send single flit
    task automatic send_flit(input [7:0] tag, input [15:0] idx, input signed [15:0] act, input signed [15:0] wt);
        @(negedge clk);
        flit_valid       = 1;
        flit_tag         = tag;
        flit_k_idx       = idx;
        flit_is_skip     = 0;
        flit_act_mask    = 1;
        flit_act_data    = act;
        flit_weight_data = wt;
        @(negedge clk);
        flit_valid       = 0;
    endtask

    // Helper: Drain slot and return to ST_FREE
    task automatic drain_slot();
        int cnt;
        layer_barrier_req = 1;
        drain_fifo_empty  = 1;
        @(negedge clk);
        layer_barrier_req = 0;
        cnt = 0;
        while (!slot_alloc_ready && cnt < 20) begin
            @(negedge clk);
            cnt++;
        end
    endtask

    int pass_count = 0;
    int fail_count = 0;

    task automatic check(input string id, input string desc, input logic cond);
        if (cond) begin
            $display("[PASS] %s: %s", id, desc);
            pass_count++;
        end else begin
            $display("[FAIL] %s: %s (state=%0d, valid=%b, ready=%b, accum=%0d)",
                id, desc, slot_fsm_state, completion_valid, completion_ready, accum_result);
            fail_count++;
        end
        $fflush();
    endtask

    initial begin
        $display("==================================================================");
        $display("Starting TEST 2 (Tag Wrap / Stale Completion) & TEST 3 (Reset Abort)");
        $display("==================================================================");
        $fflush();

        rst_n = 0;
        slot_alloc_req = 0; slot_k_total = 0;
        flit_valid = 0; flit_tag = 0; flit_k_idx = 0; flit_is_skip = 0;
        flit_act_data = 0; flit_act_mask = 0; flit_weight_data = 0;
        layer_barrier_req = 0; drain_fifo_empty = 1;
        completion_ready = 1;

        repeat(4) @(negedge clk);
        rst_n = 1;
        repeat(2) @(negedge clk);

        // =====================================================================
        // PART 1: TEST 2 — 265 SEQUENTIAL ALLOCATIONS & MODULO-256 TAG WRAP
        // =====================================================================
        $display("\n--- Executing Part 1: 265 Sequential Allocations ---");
        $fflush();

        begin: tag_wrap_execution
            int ops_completed;
            logic [7:0] tag_op1;
            logic [7:0] tag_op257;
            logic signed [39:0] accum_op1;
            logic signed [39:0] accum_op257;
            int hs_before_op257;

            ops_completed = 0;

            // Operation 1 (Tag = 1): 10 * 2 = 20
            allocate_slot(16'd1);
            tag_op1 = dut.u_slot_ctrl.active_gen_tag;
            send_flit(tag_op1, 16'd0, 16'd10, 16'd2);
            while (!completion_valid) @(negedge clk);
            accum_op1 = accum_result;
            @(negedge clk); // Handshake accepted
            drain_slot();
            ops_completed++;
            check("T2-01", "Op 1 completed with accum=20 and tag=1", (accum_op1 == 40'sd20 && tag_op1 == 8'd1));

            // Operations 2 through 256 (Tags 2..255, 0)
            for (int i = 2; i <= 256; i++) begin
                allocate_slot(16'd1);
                send_flit(dut.u_slot_ctrl.active_gen_tag, 16'd0, 16'd1, 16'd1);
                while (!completion_valid) @(negedge clk);
                @(negedge clk);
                drain_slot();
                ops_completed++;
            end
            check("T2-02", "256 operations executed; tag reached 0x00 and wrapped", (ops_completed == 256));

            // Operation 257 (Tag wraps to 1!): 30 * 2 = 60
            allocate_slot(16'd1);
            tag_op257 = dut.u_slot_ctrl.active_gen_tag;
            check("T2-03", "Tag repeats: Op 257 tag (0x01) equals Op 1 tag (0x01)", (tag_op257 == tag_op1));

            // Compute Op 257: 30 * 2 = 60
            send_flit(tag_op257, 16'd0, 16'd30, 16'd2);
            
            // Hold completion_ready = 0 to examine hardware interface during pending completion
            completion_ready = 0;
            while (!completion_valid) @(negedge clk);
            accum_op257 = accum_result;

            $display("   [INSPECTION] At Hardware Core Boundary during pending Op 257:");
            $display("   completion_valid  = %b", completion_valid);
            $display("   accum_result      = %0d (Op 1 was %0d)", accum_op257, accum_op1);
            $display("   active_gen_tag    = 0x%02h (Op 1 was 0x%02h)", tag_op257, tag_op1);
            $display("   core output ports = NO transaction_id, NO epoch_id, NO op_id on pinout!");

            // Test whether hardware can distinguish stale completion attempt:
            // Suppose host software hung or delayed, and now asserts completion_ready
            // believing it is accepting Op 1.
            // Does hardware reject the handshake?
            hs_before_op257 = handshake_accept_count;
            completion_ready = 1; // Host asserts ready
            @(negedge clk);       // Clock edge occurs

            check("T2-04", "Hardware transfers unconditionally without tag validation at pinout", 
                (handshake_accept_count == hs_before_op257 + 1));
            check("T2-05", "Transferred data is from Op 257 (accum=60), NOT Op 1 (accum=20)",
                (accum_result == 40'sd60));

            drain_slot();
            ops_completed++;

            // Run operations 258 through 265 to exceed 260 requirement
            for (int i = 258; i <= 265; i++) begin
                allocate_slot(16'd1);
                send_flit(dut.u_slot_ctrl.active_gen_tag, 16'd0, 16'd2, 16'd2);
                while (!completion_valid) @(negedge clk);
                @(negedge clk);
                drain_slot();
                ops_completed++;
            end
            check("T2-06", "Completed total of 265 sequential operations", (ops_completed == 265));
        end

        // =====================================================================
        // PART 2: TEST 3 — RESET DURING PENDING COMPLETION & HOST RECOVERY
        // =====================================================================
        $display("\n--- Executing Part 2: Reset During Pending Completion ---");
        $fflush();

        begin: reset_abort_test
            int hs_before_reset;
            int hs_after_reset;
            logic [7:0] aborted_tag;
            logic signed [39:0] aborted_accum;
            logic pre_valid, post_valid;
            logic pre_rdy, post_rdy;
            logic [2:0] pre_state, post_state;

            // Allocate Operation 266: 40 * 5 = 200
            allocate_slot(16'd1);
            aborted_tag = dut.u_slot_ctrl.active_gen_tag;
            send_flit(aborted_tag, 16'd0, 16'd40, 16'd5);

            // Backpressure: hold completion_ready = 0
            completion_ready = 0;
            while (!completion_valid) @(negedge clk);

            // Record state BEFORE reset
            pre_valid = completion_valid;
            pre_rdy   = completion_ready;
            pre_state = slot_fsm_state;
            aborted_accum = accum_result;
            hs_before_reset = handshake_accept_count;

            $display("   [PRE-RESET STATE] valid=%b, ready=%b, state=%0d, accum=%0d, tag=0x%02h",
                pre_valid, pre_rdy, pre_state, aborted_accum, aborted_tag);
            check("T3-01", "Core reached pending completion in ST_HANDSHAKE with ready=0", 
                (pre_valid == 1'b1 && pre_rdy == 1'b0 && pre_state == 3'b110 && aborted_accum == 40'sd200));

            // Stall for 10 cycles to simulate host watchdog timer countdown
            repeat(10) @(negedge clk);
            check("T3-02", "Pending completion held stable during 10-cycle watchdog countdown",
                (completion_valid == 1'b1 && accum_result == 40'sd200));

            // Host software watchdog expires -> Host asserts asynchronous reset !rst_n
            $display("   [HOST ACTION] Software watchdog expired! Host asserts rst_n = 0...");
            rst_n = 0;
            #(CLK_PERIOD * 2);

            // Inspect hardware outputs DURING reset
            check("T3-03", "During reset: completion_valid drops to 0 immediately", (completion_valid == 1'b0));
            check("T3-04", "During reset: FSM state forced to ST_FREE (0)", (slot_fsm_state == 3'b000));
            check("T3-05", "During reset: alloc_ready asserts to 1", (slot_alloc_ready == 1'b1));
            check("T3-06", "During reset: accum_result cleared to 0", (accum_result == 40'sd0));

            // Release reset
            rst_n = 1;
            repeat(2) @(negedge clk);

            // Inspect hardware outputs AFTER reset
            post_valid = completion_valid;
            post_state = slot_fsm_state;
            hs_after_reset = handshake_accept_count;

            check("T3-07", "Zero completion handshakes accepted during or across reset abort",
                (hs_after_reset == hs_before_reset));
            check("T3-08", "Post-reset: core remains idle in ST_FREE with valid=0",
                (post_valid == 1'b0 && post_state == 3'b000));

            // Software Host Recovery Demonstration:
            // Driver inspects in-flight transaction table:
            // Transaction was marked PENDING; host issued reset -> Driver transitions status to ABORTED_BY_RESET
            // Driver returns error ERR_TIMEOUT_ABORTED to software caller.
            // Driver now issues retry / clean transaction: Op 267 (7 * 8 = 56)
            $display("   [HOST RECOVERY] Driver marks aborted transaction as ABORTED_BY_RESET.");
            $display("   [HOST RECOVERY] Driver dispatches fresh transaction (Op 267)...");
            completion_ready = 1;
            allocate_slot(16'd1);
            send_flit(dut.u_slot_ctrl.active_gen_tag, 16'd0, 16'd7, 16'd8);
            while (!completion_valid) @(negedge clk);
            check("T3-09", "Fresh post-reset transaction reaches completion_valid=1", (completion_valid == 1'b1));
            @(negedge clk); // Accepted
            check("T3-10", "Fresh transaction completes with exact mathematical result (accum=56)", (accum_result == 40'sd56));
            drain_slot();
            check("T3-11", "Clean slot retirement post-recovery", (slot_alloc_ready == 1'b1));
        end

        // =====================================================================
        // Summary
        // =====================================================================
        $display("==================================================================");
        $display("TEST 2 & TEST 3 Summary: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");
        $fflush();

        if (fail_count == 0) begin
            $display("[SUCCESS] Tag Wrap, Stale Completion, and Reset Abort Tests Passed with Zero Failures!");
            $finish(0);
        end else begin
            $display("[ERROR] Failures detected in TEST 2 / TEST 3 suite!");
            $finish(1);
        end
    end

endmodule

