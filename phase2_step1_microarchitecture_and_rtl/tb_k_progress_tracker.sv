// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Integration)
// Module: tb_k_progress_tracker.sv
// Description: Focused Testbench for Resolved-K Tracker with Sticky Error Diagnostics
// Specification: DEC-P2-05 Option B & K_PROGRESS_ERROR_CONTRACT.md
// =============================================================================

`timescale 1ns / 1ps

module tb_k_progress_tracker;

    localparam int CLK_PERIOD = 10;
    localparam int K_WIDTH = 16;

    logic               clk;
    logic               rst_n;
    logic               slot_start;
    logic [K_WIDTH-1:0] k_total;
    logic               flit_valid;
    logic [K_WIDTH-1:0] flit_k_idx;
    logic               flit_is_skip;
    
    logic [K_WIDTH-1:0] k_expected;
    logic [K_WIDTH-1:0] k_resolved;
    logic [K_WIDTH-1:0] k_executed;
    logic [K_WIDTH-1:0] k_skipped;
    logic               slot_done;
    logic               seq_error;
    logic               mac_exec_trigger;
    
    logic               seq_error_clear;
    logic               sticky_seq_error;
    logic [K_WIDTH-1:0] err_failed_k_idx;
    logic [K_WIDTH-1:0] err_expected_k_idx;

    int pass_count = 0;
    int fail_count = 0;

    k_progress_tracker #(
        .K_WIDTH(K_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .slot_start(slot_start),
        .k_total(k_total),
        .flit_valid(flit_valid),
        .flit_k_idx(flit_k_idx),
        .flit_is_skip(flit_is_skip),
        .k_expected(k_expected),
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

    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    task check_condition(input string test_name, input logic cond);
        if (cond) begin
            $display("[PASS] %s", test_name);
            pass_count++;
        end else begin
            $display("[FAIL] %s", test_name);
            fail_count++;
        end
    endtask

    initial begin
        slot_start = 0; k_total = 0;
        flit_valid = 0; flit_k_idx = 0; flit_is_skip = 0;
        seq_error_clear = 0;
        rst_n = 0;
        #(CLK_PERIOD * 2);
        rst_n = 1;
        #(CLK_PERIOD);

        $display("==================================================================");
        $display("Starting Focused Verification: k_progress_tracker (DEC-P2-05 Option B)");
        $display("==================================================================");

        // 1. Nominal sequential reduction (K=4, mixed compute and skip)
        @(negedge clk);
        slot_start = 1; k_total = 16'd4;
        @(negedge clk);
        slot_start = 0;
        check_condition("KPRG-01: Slot initialized with K_total=4", (k_resolved == 0 && sticky_seq_error == 0));

        // k=0 (compute)
        @(negedge clk);
        flit_valid = 1; flit_k_idx = 16'd0; flit_is_skip = 0;
        #1;
        check_condition("KPRG-02A: Active compute triggers mac_exec_trigger=1", (mac_exec_trigger == 1'b1));
        @(negedge clk);
        check_condition("KPRG-02B: Flit k=0 resolved: executed=1, resolved=1", (k_executed == 1 && k_resolved == 1));

        // k=1 (skip)
        flit_valid = 1; flit_k_idx = 16'd1; flit_is_skip = 1;
        #1;
        check_condition("KPRG-03A: Exact-zero skip suppresses mac_exec_trigger=0", (mac_exec_trigger == 1'b0));
        @(negedge clk);
        check_condition("KPRG-03B: Flit k=1 skipped: skipped=1, resolved=2", (k_skipped == 1 && k_resolved == 2));

        // k=2 (compute)
        flit_valid = 1; flit_k_idx = 16'd2; flit_is_skip = 0;
        @(negedge clk);

        // k=3 (compute)
        flit_valid = 1; flit_k_idx = 16'd3; flit_is_skip = 0;
        @(negedge clk);
        flit_valid = 0;
        check_condition("KPRG-04: In-order completion: resolved=4, slot_done=1, sticky_seq_error=0", 
            (k_resolved == 16'd4 && slot_done == 1'b1 && sticky_seq_error == 1'b0));

        // 2. Out-of-Sequence Flit Arrival (expecting k=0, inject k=3)
        @(negedge clk);
        slot_start = 1; k_total = 16'd10;
        @(negedge clk);
        slot_start = 0;
        // Deliver k=0
        @(negedge clk);
        flit_valid = 1; flit_k_idx = 16'd0; flit_is_skip = 0;
        @(negedge clk);
        // Deliver k=3 (skipping k=1 and k=2)
        flit_valid = 1; flit_k_idx = 16'd3; flit_is_skip = 0;
        @(negedge clk);
        check_condition("KPRG-05: Out-of-order flit asserts combinational seq_error and sticky_seq_error", 
            (seq_error == 1'b1 && sticky_seq_error == 1'b1));
        check_condition("KPRG-06: Diagnostic registers capture failed_k=3 and expected_k=1", 
            (err_failed_k_idx == 16'd3 && err_expected_k_idx == 16'd1));

        // 3. Drop flit_valid low: sticky error must persist!
        flit_valid = 0; flit_k_idx = 0;
        #(CLK_PERIOD * 3);
        check_condition("KPRG-07: Sticky error and diagnostics persist while flit_valid=0 (seq_error drops)", 
            (seq_error == 1'b0 && sticky_seq_error == 1'b1 && err_failed_k_idx == 16'd3 && err_expected_k_idx == 16'd1));

        // 4. First-Fault Capture Invariant: subsequent error does not overwrite initial diagnostic
        @(negedge clk);
        flit_valid = 1; flit_k_idx = 16'd7; flit_is_skip = 0;
        @(negedge clk);
        flit_valid = 0;
        check_condition("KPRG-08: First-fault capture preserved (failed_k still 3, not 7)", 
            (err_failed_k_idx == 16'd3 && err_expected_k_idx == 16'd1));

        // 5. Software Host Error Clear (seq_error_clear)
        @(negedge clk);
        seq_error_clear = 1;
        @(negedge clk);
        seq_error_clear = 0;
        check_condition("KPRG-09: seq_error_clear clears sticky error and diagnostic registers", 
            (sticky_seq_error == 1'b0 && err_failed_k_idx == 0 && err_expected_k_idx == 0));

        // 6. Duplicate Flit Injection (k=0 then k=0 again)
        @(negedge clk);
        slot_start = 1; k_total = 16'd8;
        @(negedge clk);
        slot_start = 0;
        // Deliver k=0
        @(negedge clk);
        flit_valid = 1; flit_k_idx = 16'd0; flit_is_skip = 0;
        @(negedge clk);
        // Deliver duplicate k=0 (now expecting k=1)
        flit_valid = 1; flit_k_idx = 16'd0; flit_is_skip = 0;
        @(negedge clk);
        flit_valid = 0;
        check_condition("KPRG-10: Duplicate flit asserts sticky_seq_error (failed_k=0, expected_k=1)", 
            (sticky_seq_error == 1'b1 && err_failed_k_idx == 16'd0 && err_expected_k_idx == 16'd1));

        // 7. Large Reduction Depth (K=64) sequential run
        @(negedge clk);
        slot_start = 1; k_total = 16'd64;
        @(negedge clk);
        slot_start = 0;
        for (int i = 0; i < 64; i++) begin
            @(negedge clk);
            flit_valid = 1; flit_k_idx = i[15:0]; flit_is_skip = (i % 4 == 0); // 25% skip
        end
        @(negedge clk);
        flit_valid = 0;
        check_condition("KPRG-11: 64-step reduction completes with zero errors (resolved=64, executed=48, skipped=16)", 
            (k_resolved == 16'd64 && k_executed == 16'd48 && k_skipped == 16'd16 && slot_done == 1'b1 && sticky_seq_error == 1'b0));

        // 8. Single-step reduction (K=1)
        @(negedge clk);
        slot_start = 1; k_total = 16'd1;
        @(negedge clk);
        slot_start = 0;
        @(negedge clk);
        flit_valid = 1; flit_k_idx = 16'd0; flit_is_skip = 0;
        @(negedge clk);
        flit_valid = 0;
        check_condition("KPRG-12: Single-element K=1 reduction completes immediately (resolved=1, slot_done=1)", 
            (k_resolved == 16'd1 && slot_done == 1'b1 && sticky_seq_error == 1'b0));

        $display("==================================================================");
        $display("K-Progress Verification Summary: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All K-Progress Tracker Tests Completed Successfully!");
            $finish(0);
        end else begin
            $display("[ERROR] Failures encountered in K-progress simulation.");
            $finish(1);
        end
    end

endmodule
