// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Integration)
// Module: tb_drain_backpressure.sv
// Description: Focused Testbench for Stall-on-Busy Drain & Backpressure FSM
// Specification: DEC-P2-03 Option A & DRAIN_BACKPRESSURE_CONTRACT.md
// =============================================================================

`timescale 1ns / 1ps

module tb_drain_backpressure;

    localparam int CLK_PERIOD = 10;
    localparam int SLOT_ID_WIDTH = 4;
    localparam int TAG_WIDTH = 8;

    logic                 clk;
    logic                 rst_n;
    logic                 alloc_req;
    logic                 alloc_ready;
    logic                 flit_valid;
    logic [TAG_WIDTH-1:0] flit_tag;
    logic                 flit_accepted;
    logic                 stale_flit_rejected;
    logic                 slot_computation_done;
    logic                 layer_barrier_req;
    logic                 drain_fifo_empty;
    logic                 slot_quiescent;
    logic                 accum_clear;
    logic                 drain_enable;
    logic [TAG_WIDTH-1:0] active_gen_tag;
    logic [2:0]           fsm_state;
    logic                 completion_valid;
    logic                 completion_ready;

    int pass_count = 0;
    int fail_count = 0;

    slot_control_unit #(
        .SLOT_ID_WIDTH(SLOT_ID_WIDTH),
        .TAG_WIDTH(TAG_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .alloc_req(alloc_req),
        .alloc_ready(alloc_ready),
        .flit_valid(flit_valid),
        .flit_tag(flit_tag),
        .flit_accepted(flit_accepted),
        .stale_flit_rejected(stale_flit_rejected),
        .slot_computation_done(slot_computation_done),
        .layer_barrier_req(layer_barrier_req),
        .drain_fifo_empty(drain_fifo_empty),
        .slot_quiescent(slot_quiescent),
        .completion_valid(completion_valid),
        .completion_ready(completion_ready),
        .accum_clear(accum_clear),
        .drain_enable(drain_enable),
        .active_gen_tag(active_gen_tag),
        .fsm_state(fsm_state)
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
        alloc_req = 0; flit_valid = 0; flit_tag = 0;
        slot_computation_done = 0; layer_barrier_req = 0;
        drain_fifo_empty = 1; completion_ready = 1;
        rst_n = 0;
        #(CLK_PERIOD * 2);
        rst_n = 1;
        #(CLK_PERIOD);

        $display("==================================================================");
        $display("Starting Focused Verification: slot_control_unit Drain Protocol");
        $display("==================================================================");

        // 1. Initial State: ST_FREE
        check_condition("DRN-01: Powers up in ST_FREE with alloc_ready=1", (fsm_state == 3'b000 && alloc_ready == 1'b1));

        // 2. Allocate Slot -> ST_ALLOCATED -> ST_COMPUTING
        @(negedge clk);
        alloc_req = 1;
        @(negedge clk);
        alloc_req = 0;
        check_condition("DRN-02: Transitions ST_ALLOCATED asserting accum_clear", (accum_clear == 1'b1));
        @(negedge clk);
        check_condition("DRN-03: Advances to ST_COMPUTING", (fsm_state == 3'b010));

        // 3. Immediate Drain (drain_fifo_empty == 1)
        @(negedge clk);
        slot_computation_done = 1;
        drain_fifo_empty = 1;
        @(negedge clk);
        slot_computation_done = 0;
        check_condition("DRN-04: Enters ST_DRAINING with drain_enable=1", (fsm_state == 3'b011 && drain_enable == 1'b1));
        @(negedge clk); // Advances to ST_HANDSHAKE (3'b110)
        @(negedge clk); // Handshake accepted, advances to ST_QUIESCENT (3'b100)
        check_condition("DRN-05: Advances to ST_QUIESCENT when empty=1", (fsm_state == 3'b100 && slot_quiescent == 1'b1));
        @(negedge clk);
        check_condition("DRN-06: Advances through ST_RELEASE to ST_FREE", (fsm_state == 3'b101 || fsm_state == 3'b000));
        @(negedge clk);
        check_condition("DRN-07: Returns cleanly to ST_FREE (alloc_ready=1)", (fsm_state == 3'b000 && alloc_ready == 1'b1));

        // 4. Delayed Drain: 1-cycle backpressure
        @(negedge clk);
        alloc_req = 1;
        @(negedge clk);
        alloc_req = 0;
        @(negedge clk); // now in ST_COMPUTING
        @(negedge clk);
        slot_computation_done = 1;
        drain_fifo_empty = 0; // Downstream buffer NOT empty
        @(negedge clk);
        slot_computation_done = 0;
        check_condition("DRN-08: Enters ST_DRAINING under backpressure", (fsm_state == 3'b011 && drain_enable == 1'b1));
        // Hold backpressure for 1 extra cycle
        @(negedge clk);
        check_condition("DRN-09: Holds in ST_DRAINING when drain_fifo_empty=0", (fsm_state == 3'b011 && alloc_ready == 1'b0));
        // Release backpressure
        drain_fifo_empty = 1;
        @(negedge clk); // Advances to ST_HANDSHAKE
        @(negedge clk); // Advances to ST_QUIESCENT
        check_condition("DRN-10: Advances to ST_QUIESCENT once drain_fifo_empty asserts", (fsm_state == 3'b100));
        @(negedge clk);
        @(negedge clk);
        check_condition("DRN-11: Returned to ST_FREE", (fsm_state == 3'b000 && alloc_ready == 1'b1));

        // 5. Prolonged Backpressure Stall: 1,000 cycles
        @(negedge clk);
        alloc_req = 1;
        @(negedge clk);
        alloc_req = 0;
        @(negedge clk); // ST_COMPUTING
        @(negedge clk);
        slot_computation_done = 1;
        drain_fifo_empty = 0;
        @(negedge clk);
        slot_computation_done = 0;
        // Verify stall across 1000 cycles
        for (int i = 0; i < 1000; i++) begin
            @(negedge clk);
        end
        check_condition("DRN-12: Zero state progression over 1,000 stall cycles", 
            (fsm_state == 3'b011 && drain_enable == 1'b1 && alloc_ready == 1'b0));
        // Early allocation attempt during stall must be ignored
        alloc_req = 1;
        @(negedge clk);
        alloc_req = 0;
        check_condition("DRN-13: Early alloc_req during drain stall is strictly ignored", (fsm_state == 3'b011));
        // Resume drain
        drain_fifo_empty = 1;
        @(negedge clk); // Advances to ST_HANDSHAKE
        @(negedge clk); // Advances to ST_QUIESCENT
        check_condition("DRN-14: Clean resumption to ST_QUIESCENT after 1,000-cycle stall", (fsm_state == 3'b100));
        @(negedge clk);
        @(negedge clk);

        // 6. Asynchronous Reset during Active Drain
        @(negedge clk);
        alloc_req = 1;
        @(negedge clk);
        alloc_req = 0;
        @(negedge clk); // ST_COMPUTING
        slot_computation_done = 1;
        drain_fifo_empty = 0;
        @(negedge clk);
        slot_computation_done = 0; // ST_DRAINING
        // Assert rst_n
        rst_n = 0;
        #(CLK_PERIOD);
        check_condition("DRN-15: Asynchronous rst_n forces immediate reset to ST_FREE and drops drain_enable", 
            (fsm_state == 3'b000 && drain_enable == 1'b0));
        rst_n = 1;
        #(CLK_PERIOD);

        $display("==================================================================");
        $display("Drain Protocol Summary: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All Drain & Backpressure Tests Completed Successfully!");
            $finish(0);
        end else begin
            $display("[ERROR] Failures encountered in drain simulation.");
            $finish(1);
        end
    end

endmodule

