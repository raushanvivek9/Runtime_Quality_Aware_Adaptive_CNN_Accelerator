// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-04 Ping-Pong Buffer Controller Verification
// Module: tb_ping_pong_buffer_controller.sv
// Description: Comprehensive self-checking testbench for ping_pong_buffer_controller.
//              Verifies all 15 required scenarios including ownership tracking,
//              role transitions, backpressure, concurrent transactions, resets,
//              illegal start handling, and 50-iteration pipelined execution.
// Specification: TSK-04 Verification Specification
// =============================================================================

`timescale 1ns / 1ps

module tb_ping_pong_buffer_controller;

    localparam time CLK_PERIOD = 10ns;

    // Clock and Reset
    logic clk;
    logic rst_n;

    // Producer Interface
    wire        producer_ready;
    logic       producer_start;
    logic       producer_done;
    wire        producer_buf_id;
    wire        producer_active;
    wire        producer_stall;
    wire        producer_err_start;

    // Consumer Interface
    wire        consumer_ready;
    logic       consumer_start;
    logic       consumer_done;
    wire        consumer_buf_id;
    wire        consumer_active;
    wire        consumer_stall;
    wire        consumer_err_start;

    // Diagnostics & Status
    wire [1:0]  buf_state_a;
    wire [1:0]  buf_state_b;
    wire        buf_a_empty;
    wire        buf_a_producing;
    wire        buf_a_ready;
    wire        buf_a_consuming;
    wire        buf_b_empty;
    wire        buf_b_producing;
    wire        buf_b_ready;
    wire        buf_b_consuming;
    wire        switch_event_pulse;
    wire        invariant_violation;
    wire [31:0] total_produced_count;
    wire [31:0] total_consumed_count;

    // Test tracking counters
    int test_count = 0;
    int pass_count = 0;
    int fail_count = 0;

    // Pipeline test variables
    int target_iterations;
    int produced_cnt;
    int consumed_cnt;
    int p_delay;
    int c_delay;
    logic [31:0] init_produced;
    logic [31:0] init_consumed;
    int cycle_idx;

    // Instantiate Device Under Test
    ping_pong_buffer_controller #(
        .RESET_DEFAULT_PROD_BUF(1'b0),
        .RESET_DEFAULT_CONS_BUF(1'b0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .producer_ready(producer_ready),
        .producer_start(producer_start),
        .producer_done(producer_done),
        .producer_buf_id(producer_buf_id),
        .producer_active(producer_active),
        .producer_stall(producer_stall),
        .producer_err_start(producer_err_start),
        .consumer_ready(consumer_ready),
        .consumer_start(consumer_start),
        .consumer_done(consumer_done),
        .consumer_buf_id(consumer_buf_id),
        .consumer_active(consumer_active),
        .consumer_stall(consumer_stall),
        .consumer_err_start(consumer_err_start),
        .buf_state_a(buf_state_a),
        .buf_state_b(buf_state_b),
        .buf_a_empty(buf_a_empty),
        .buf_a_producing(buf_a_producing),
        .buf_a_ready(buf_a_ready),
        .buf_a_consuming(buf_a_consuming),
        .buf_b_empty(buf_b_empty),
        .buf_b_producing(buf_b_producing),
        .buf_b_ready(buf_b_ready),
        .buf_b_consuming(buf_b_consuming),
        .switch_event_pulse(switch_event_pulse),
        .invariant_violation(invariant_violation),
        .total_produced_count(total_produced_count),
        .total_consumed_count(total_consumed_count)
    );

    // 100MHz clock generator
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Helper check tasks
    task check_bool(input string tname, input logic actual, input logic expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
            $display("[PASS] %s: actual=%0b, expected=%0b", tname, actual, expected);
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%0b, expected=%0b", tname, actual, expected);
        end
    endtask

    task check_val2(input string tname, input logic [1:0] actual, input logic [1:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
            $display("[PASS] %s: actual=2'b%02b, expected=2'b%02b", tname, actual, expected);
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=2'b%02b, expected=2'b%02b", tname, actual, expected);
        end
    endtask

    task check_val32(input string tname, input logic [31:0] actual, input logic [31:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
            $display("[PASS] %s: actual=%0d, expected=%0d", tname, actual, expected);
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%0d, expected=%0d", tname, actual, expected);
        end
    endtask

    task clear_all_inputs();
        producer_start = 1'b0;
        producer_done  = 1'b0;
        consumer_start = 1'b0;
        consumer_done  = 1'b0;
    endtask

    task reset_system();
        rst_n = 1'b0;
        clear_all_inputs();
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
    endtask

    // Synchronous Handshake Stimulus Tasks
    task drive_prod_start();
        @(negedge clk);
        producer_start = 1'b1;
        @(negedge clk);
        producer_start = 1'b0;
    endtask

    task drive_prod_done();
        @(negedge clk);
        producer_done = 1'b1;
        @(negedge clk);
        producer_done = 1'b0;
    endtask

    task drive_cons_start();
        @(negedge clk);
        consumer_start = 1'b1;
        @(negedge clk);
        consumer_start = 1'b0;
    endtask

    task drive_cons_done();
        @(negedge clk);
        consumer_done = 1'b1;
        @(negedge clk);
        consumer_done = 1'b0;
    endtask

    // Global invariant monitor: invariant_violation must NEVER be 1 when rst_n is 1
    always @(posedge clk) begin
        if (rst_n && invariant_violation) begin
            $display("[FATAL INVARIANT VIOLATION] at time %0t: invariant_violation asserted!", $time);
            fail_count++;
        end
    end

    // Test program
    initial begin
        $display("==================================================================");
        $display("Starting TSK-04 Ping-Pong Buffer Controller Verification");
        $display("==================================================================");

        // ---------------------------------------------------------------------
        // SCENARIO 1: Reset and Initial Ownership
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 1: Reset and Initial Ownership ---");
        reset_system();
        check_val2("S1.1: Buffer A starts EMPTY", buf_state_a, 2'b00);
        check_val2("S1.2: Buffer B starts EMPTY", buf_state_b, 2'b00);
        check_bool("S1.3: Producer ready initially", producer_ready, 1'b1);
        check_bool("S1.4: Consumer not ready initially", consumer_ready, 1'b0);
        check_bool("S1.5: Producer targets Buffer A (0)", producer_buf_id, 1'b0);
        check_bool("S1.6: Consumer targets Buffer A (0)", consumer_buf_id, 1'b0);
        check_bool("S1.7: Producer inactive", producer_active, 1'b0);
        check_bool("S1.8: Consumer inactive", consumer_active, 1'b0);
        check_bool("S1.9: No invariant violation", invariant_violation, 1'b0);
        check_val32("S1.10: Total produced = 0", total_produced_count, 32'd0);
        check_val32("S1.11: Total consumed = 0", total_consumed_count, 32'd0);

        // ---------------------------------------------------------------------
        // SCENARIO 2: Produce into Buffer A
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 2: Produce into Buffer A ---");
        drive_prod_start();

        check_val2("S2.1: Buffer A enters PRODUCING", buf_state_a, 2'b01);
        check_bool("S2.2: Producer active is high", producer_active, 1'b1);
        check_bool("S2.3: Producer buf id locked to Buffer A", producer_buf_id, 1'b0);
        check_bool("S2.4: Producer ready drops while producing", producer_ready, 1'b0);
        check_bool("S2.5: Consumer still not ready", consumer_ready, 1'b0);

        // Simulate multi-cycle production
        repeat (4) @(posedge clk);

        // Complete production of Buffer A
        drive_prod_done();

        check_val2("S2.6: Buffer A transitions to READY", buf_state_a, 2'b10);
        check_bool("S2.7: Producer active drops", producer_active, 1'b0);
        check_bool("S2.8: Next producer target toggles to Buffer B (1)", producer_buf_id, 1'b1);
        check_bool("S2.9: Producer ready for next buffer (Buffer B is empty)", producer_ready, 1'b1);
        check_bool("S2.10: Consumer ready for Buffer A", consumer_ready, 1'b1);
        check_bool("S2.11: Consumer target is Buffer A (0)", consumer_buf_id, 1'b0);
        check_val32("S2.12: total_produced_count incremented to 1", total_produced_count, 32'd1);

        // ---------------------------------------------------------------------
        // SCENARIO 3: Consumer Starts Reading Buffer A
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 3: Consumer Starts Reading Buffer A ---");
        drive_cons_start();

        check_val2("S3.1: Buffer A transitions to CONSUMING", buf_state_a, 2'b11);
        check_bool("S3.2: Consumer active is high", consumer_active, 1'b1);
        check_bool("S3.3: Consumer buf id locked to Buffer A (0)", consumer_buf_id, 1'b0);
        check_bool("S3.4: Consumer ready drops while consuming", consumer_ready, 1'b0);

        // ---------------------------------------------------------------------
        // SCENARIO 4: Parallel Overlap (Producer Writes B while Consumer Reads A)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 4: Parallel Overlap (Producer Writes B while Consumer Reads A) ---");
        check_bool("S4.1: Producer ready for Buffer B", producer_ready, 1'b1);
        check_bool("S4.2: Producer target is Buffer B (1)", producer_buf_id, 1'b1);

        drive_prod_start();

        check_val2("S4.3: Buffer A remains CONSUMING", buf_state_a, 2'b11);
        check_val2("S4.4: Buffer B enters PRODUCING", buf_state_b, 2'b01);
        check_bool("S4.5: Both producer and consumer active simultaneously", (producer_active && consumer_active), 1'b1);
        check_bool("S4.6: Invariant holds during concurrent access", invariant_violation, 1'b0);

        // Simulate concurrent execution for 5 cycles
        repeat (5) @(posedge clk);

        // ---------------------------------------------------------------------
        // SCENARIO 5: Consumer Completes Buffer A
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 5: Consumer Completes Buffer A ---");
        drive_cons_done();

        check_val2("S5.1: Buffer A transitions to EMPTY", buf_state_a, 2'b00);
        check_bool("S5.2: Consumer active drops to 0", consumer_active, 1'b0);
        check_bool("S5.3: Consumer target pointer toggles to Buffer B (1)", consumer_buf_id, 1'b1);
        check_val32("S5.4: total_consumed_count incremented to 1", total_consumed_count, 32'd1);
        check_val2("S5.5: Buffer B still PRODUCING without disturbance", buf_state_b, 2'b01);

        // ---------------------------------------------------------------------
        // SCENARIO 6: Safe Transition to Buffer B
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 6: Safe Transition to Buffer B ---");
        drive_prod_done();

        check_val2("S6.1: Buffer B transitions to READY", buf_state_b, 2'b10);
        check_bool("S6.2: Producer target pointer toggles to Buffer A (0)", producer_buf_id, 1'b0);
        check_bool("S6.3: Consumer ready asserts for Buffer B", consumer_ready, 1'b1);
        check_bool("S6.4: Consumer target is Buffer B (1)", consumer_buf_id, 1'b1);

        drive_cons_start();

        check_val2("S6.5: Buffer B transitions to CONSUMING", buf_state_b, 2'b11);
        check_bool("S6.6: Consumer active locked on Buffer B", consumer_active, 1'b1);

        // ---------------------------------------------------------------------
        // SCENARIO 7: Buffer A Reusability After Consumption Completes
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 7: Buffer A Reusability After Consumption Completes ---");
        check_bool("S7.1: Producer ready for Buffer A (now empty)", producer_ready, 1'b1);
        check_bool("S7.2: Producer target is Buffer A (0)", producer_buf_id, 1'b0);

        drive_prod_start();

        check_val2("S7.3: Buffer A successfully reused (PRODUCING)", buf_state_a, 2'b01);
        check_val2("S7.4: Buffer B continues CONSUMING in parallel", buf_state_b, 2'b11);

        // Retire both to reach clean benchmark point
        @(negedge clk);
        producer_done = 1'b1;
        consumer_done = 1'b1;
        @(negedge clk);
        clear_all_inputs();

        check_val2("S7.5: Buffer A is now READY", buf_state_a, 2'b10);
        check_val2("S7.6: Buffer B is now EMPTY", buf_state_b, 2'b00);

        // ---------------------------------------------------------------------
        // SCENARIO 8: Producer Backpressure When No Buffer Is Writable
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 8: Producer Backpressure (Full Buffers) ---");
        // Buffer A is already READY. Now produce Buffer B so BOTH are full/ready!
        drive_prod_start();
        drive_prod_done();

        check_val2("S8.1: Buffer A is READY", buf_state_a, 2'b10);
        check_val2("S8.2: Buffer B is READY", buf_state_b, 2'b10);
        check_bool("S8.3: Next producer target is Buffer A (0)", producer_buf_id, 1'b0);
        check_bool("S8.4: Producer NOT ready (both buffers full)", producer_ready, 1'b0);

        // Producer attempts to start: must be stalled and rejected
        @(negedge clk);
        producer_start = 1'b1;
        #1;
        check_bool("S8.5: Producer stall asserted on un-ready buffer", producer_stall, 1'b1);
        @(posedge clk);
        #1;
        check_bool("S8.6: Producer error start pulsed", producer_err_start, 1'b1);
        check_val2("S8.7: Buffer A protected against overwrite (remains READY)", buf_state_a, 2'b10);
        @(negedge clk);
        producer_start = 1'b0;

        // ---------------------------------------------------------------------
        // SCENARIO 9: Consumer Start Blocked When No Completed Buffer Available
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 9: Consumer Start Blocked (Empty Buffers) ---");
        // Drain Buffer A
        drive_cons_start();
        drive_cons_done();

        // Drain Buffer B
        drive_cons_start();
        drive_cons_done();

        // Now both buffers are EMPTY
        check_val2("S9.1: Buffer A is EMPTY", buf_state_a, 2'b00);
        check_val2("S9.2: Buffer B is EMPTY", buf_state_b, 2'b00);
        check_bool("S9.3: Consumer ready is 0", consumer_ready, 1'b0);

        // Consumer attempts start on empty buffer: must be stalled and rejected
        @(negedge clk);
        consumer_start = 1'b1;
        #1;
        check_bool("S9.4: Consumer stall asserted on un-ready buffer", consumer_stall, 1'b1);
        @(posedge clk);
        #1;
        check_bool("S9.5: Consumer error start pulsed", consumer_err_start, 1'b1);
        check_bool("S9.6: Consumer active remains 0", consumer_active, 1'b0);
        @(negedge clk);
        consumer_start = 1'b0;

        // ---------------------------------------------------------------------
        // SCENARIO 10: Simultaneous Producer and Consumer Completion Events
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 10: Simultaneous Producer & Consumer Completion ---");
        // Put Buffer A in CONSUMING and Buffer B in PRODUCING
        drive_prod_start();
        drive_prod_done();

        // Start consuming A and producing B simultaneously
        @(negedge clk);
        consumer_start = 1'b1;
        producer_start = 1'b1;
        @(negedge clk);
        clear_all_inputs();

        check_val2("S10.1: Buffer A is CONSUMING", buf_state_a, 2'b11);
        check_val2("S10.2: Buffer B is PRODUCING", buf_state_b, 2'b01);

        // Assert producer_done and consumer_done on the EXACT same cycle!
        @(negedge clk);
        producer_done = 1'b1;
        consumer_done = 1'b1;
        @(negedge clk);
        clear_all_inputs();

        check_val2("S10.3: Buffer A cleanly transitions to EMPTY", buf_state_a, 2'b00);
        check_val2("S10.4: Buffer B cleanly transitions to READY", buf_state_b, 2'b10);
        check_bool("S10.5: Producer active drops cleanly", producer_active, 1'b0);
        check_bool("S10.6: Consumer active drops cleanly", consumer_active, 1'b0);
        check_bool("S10.7: No invariant violation during simultaneous completion", invariant_violation, 1'b0);

        // ---------------------------------------------------------------------
        // SCENARIO 11: Reset During Idle
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 11: Reset During Idle ---");
        @(negedge clk);
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        check_val2("S11.1: Post-reset Buffer A is EMPTY", buf_state_a, 2'b00);
        check_val2("S11.2: Post-reset Buffer B is EMPTY", buf_state_b, 2'b00);
        check_bool("S11.3: Post-reset producer ready", producer_ready, 1'b1);
        check_bool("S11.4: Post-reset consumer not ready", consumer_ready, 1'b0);

        // ---------------------------------------------------------------------
        // SCENARIO 12: Asynchronous Reset During Active Transactions
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 12: Asynchronous Reset During Active Transactions ---");
        drive_prod_start();
        check_val2("S12.1: Buffer A PRODUCING", buf_state_a, 2'b01);

        // Assert asynchronous reset mid-cycle
        #3;
        rst_n = 1'b0;
        #1;
        check_val2("S12.2: Asynchronous reset immediately forces Buffer A to EMPTY", buf_state_a, 2'b00);
        check_bool("S12.3: Asynchronous reset immediately drops producer active", producer_active, 1'b0);

        @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        check_bool("S12.4: System ready post mid-flight reset", producer_ready, 1'b1);

        // ---------------------------------------------------------------------
        // SCENARIO 13: Illegal or Repeated Start Requests
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 13: Illegal or Repeated Start Requests ---");
        drive_prod_start();
        check_bool("S13.1: Producer active is high", producer_active, 1'b1);

        // Producer is active; attempt repeated start
        @(negedge clk);
        producer_start = 1'b1;
        @(posedge clk);
        #1;
        check_bool("S13.2: Repeated producer start triggers error pulse", producer_err_start, 1'b1);
        check_val2("S13.3: Buffer A state remains PRODUCING without corruption", buf_state_a, 2'b01);
        @(negedge clk);
        producer_start = 1'b0;

        drive_prod_done();

        // Consumer starts Buffer A
        drive_cons_start();
        check_bool("S13.4: Consumer active is high", consumer_active, 1'b1);

        // Attempt repeated consumer start
        @(negedge clk);
        consumer_start = 1'b1;
        @(posedge clk);
        #1;
        check_bool("S13.5: Repeated consumer start triggers error pulse", consumer_err_start, 1'b1);
        check_val2("S13.6: Buffer A remains CONSUMING without corruption", buf_state_a, 2'b11);
        @(negedge clk);
        consumer_start = 1'b0;

        drive_cons_done();

        // ---------------------------------------------------------------------
        // SCENARIO 14: Buffer Ownership Invariants Across Multiple Alternations
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 14: Alternating Buffer Invariants (10 Full Cycles) ---");
        reset_system();
        for (cycle_idx = 0; cycle_idx < 10; cycle_idx++) begin
            logic exp_prod_buf, exp_cons_buf;
            exp_prod_buf = cycle_idx[0];
            exp_cons_buf = cycle_idx[0];

            // 1. Producer fills buffer
            check_bool($sformatf("S14[%0d].1: Producer targets expected buffer", cycle_idx), producer_buf_id, exp_prod_buf);
            drive_prod_start();
            repeat (2) @(posedge clk);
            drive_prod_done();

            // 2. Consumer drains buffer
            check_bool($sformatf("S14[%0d].2: Consumer targets expected buffer", cycle_idx), consumer_buf_id, exp_cons_buf);
            drive_cons_start();
            repeat (2) @(posedge clk);
            drive_cons_done();

            check_bool($sformatf("S14[%0d].3: Invariant holds after cycle", cycle_idx), invariant_violation, 1'b0);
        end

        // ---------------------------------------------------------------------
        // SCENARIO 15: Extended Pipelined Alternating Sequence (50 Continuous Transfers)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 15: Extended Pipelined Alternation (50 Iterations) ---");
        begin
            target_iterations = 50;
            produced_cnt = 0;
            consumed_cnt = 0;
            p_delay = 0;
            c_delay = 0;
            init_produced = total_produced_count;
            init_consumed = total_consumed_count;

            while (consumed_cnt < target_iterations) begin
                @(negedge clk);

                // Producer logic
                if (!producer_active && producer_ready && (produced_cnt < target_iterations)) begin
                    producer_start = 1'b1;
                    producer_done  = 1'b0;
                    p_delay = 1 + (produced_cnt % 3); // Variable production delay 1..3 cycles
                end else if (producer_active) begin
                    producer_start = 1'b0;
                    if (p_delay > 0) begin
                        p_delay--;
                        producer_done = 1'b0;
                    end else begin
                        producer_done = 1'b1;
                        produced_cnt++;
                    end
                end else begin
                    producer_start = 1'b0;
                    producer_done  = 1'b0;
                end

                // Consumer logic
                if (!consumer_active && consumer_ready && (consumed_cnt < target_iterations)) begin
                    consumer_start = 1'b1;
                    consumer_done  = 1'b0;
                    c_delay = 1 + (consumed_cnt % 4); // Variable consumption delay 1..4 cycles
                end else if (consumer_active) begin
                    consumer_start = 1'b0;
                    if (c_delay > 0) begin
                        c_delay--;
                        consumer_done = 1'b0;
                    end else begin
                        consumer_done = 1'b1;
                        consumed_cnt++;
                    end
                end else begin
                    consumer_start = 1'b0;
                    consumer_done  = 1'b0;
                end
            end

            @(negedge clk);
            clear_all_inputs();
            @(negedge clk);

            check_val32("S15.1: Exactly 50 transfers produced in pipeline", total_produced_count, init_produced + 32'd50);
            check_val32("S15.2: Exactly 50 transfers consumed in pipeline", total_consumed_count, init_consumed + 32'd50);
            check_bool("S15.3: Invariant holds at end of extended pipeline", invariant_violation, 1'b0);
        end

        // ---------------------------------------------------------------------
        // Test Summary
        // ---------------------------------------------------------------------
        $display("\n==================================================================");
        $display("TSK-04 Test Summary: Total=%0d, Passed=%0d, Failed=%0d", test_count, pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-04 Ping-Pong Buffer Controller Tests Passed!");
            $finish(0);
        end else begin
            $display("[FAILURE] Some TSK-04 tests failed!");
            $finish(1);
        end
    end

endmodule
