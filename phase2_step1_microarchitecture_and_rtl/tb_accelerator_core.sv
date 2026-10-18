// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Module: tb_accelerator_core.sv
// Description: Comprehensive SystemVerilog Testbench for Accelerator Core Top
// =============================================================================

`timescale 1ns / 1ps

module tb_accelerator_core;

    localparam int CLK_PERIOD = 10; // 100 MHz clock

    logic                          clk;
    logic                          rst_n;
    
    // Slot allocation interface
    logic                          slot_alloc_req;
    logic [15:0]                   slot_k_total;
    logic                          slot_alloc_ready;
    logic [2:0]                    slot_fsm_state;
    
    // Flit interface
    logic                          flit_valid;
    logic [7:0]                    flit_tag;
    logic [15:0]                   flit_k_idx;
    logic                          flit_is_skip;
    logic signed [15:0]            flit_act_data;
    logic                          flit_act_mask;
    logic signed [15:0]            flit_weight_data;
    
    // Status outputs
    logic                          flit_accepted;
    logic                          stale_flit_rejected;
    logic                          seq_error;
    
    // Barrier interface
    logic                          layer_barrier_req;
    logic                          slot_quiescent;
    
    // Datapath outputs
    logic signed [39:0]            accum_result;
    logic                          sticky_saturation;
    logic [15:0]                   k_resolved;
    logic [15:0]                   k_executed;
    logic [15:0]                   k_skipped;
    logic                          slot_done;

    // Test statistics
    int pass_count = 0;
    int fail_count = 0;

    // Instantiate Device Under Test (DUT)
    accelerator_core_top #(
        .ACT_WIDTH(16),
        .WEIGHT_WIDTH(16),
        .ACCUM_WIDTH(40),
        .K_WIDTH(16),
        .TAG_WIDTH(8)
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
        .slot_quiescent(slot_quiescent),
        .accum_result(accum_result),
        .sticky_saturation(sticky_saturation),
        .k_resolved(k_resolved),
        .k_executed(k_executed),
        .k_skipped(k_skipped),
        .slot_done(slot_done)
    );

    // Clock generator
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Assertion verification task
    task check_condition(input string test_name, input logic cond);
        if (cond) begin
            $display("[PASS] %s", test_name);
            pass_count++;
        end else begin
            $display("[FAIL] %s", test_name);
            fail_count++;
        end
    endtask

    // Main Test Stimulus
    initial begin
        $display("==================================================================");
        $display("Starting Phase 2 Step 1 RTL Testbench: accelerator_core_top");
        $display("==================================================================");

        // 1. Reset state
        rst_n             = 0;
        slot_alloc_req    = 0;
        slot_k_total      = 0;
        flit_valid        = 0;
        flit_tag          = 0;
        flit_k_idx        = 0;
        flit_is_skip      = 0;
        flit_act_data     = 0;
        flit_act_mask     = 0;
        flit_weight_data  = 0;
        layer_barrier_req = 0;

        #(CLK_PERIOD * 3);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        check_condition("TEST 1: Reset Ready State", (slot_alloc_ready == 1'b1) && (slot_fsm_state == 3'b000));

        // 2. Allocate Slot 0 with K_total = 4
        @(posedge clk);
        slot_alloc_req = 1;
        slot_k_total   = 16'd4;
        @(posedge clk);
        slot_alloc_req = 0;
        
        // Wait 2 cycles for transition to ST_COMPUTING
        #(CLK_PERIOD * 2);
        check_condition("TEST 2: FSM Transition to Computing", (slot_fsm_state == 3'b010));

        // 3. Send Flit 0 (Compute): A = 250, W = 100, M = 1 -> Product = 25,000
        @(posedge clk);
        flit_valid        = 1;
        flit_tag          = 8'd1; // First allocation increments tag from 0 to 1
        flit_k_idx        = 16'd0;
        flit_is_skip      = 0;
        flit_act_data     = 16'd250;
        flit_act_mask     = 1'b1;
        flit_weight_data  = 16'd100;
        @(posedge clk);

        // 4. Send Flit 1 (Exact-zero skip flit): A = 0, M = 0 -> Product = 0
        flit_k_idx        = 16'd1;
        flit_is_skip      = 1'b1;
        flit_act_data     = 16'd0;
        flit_act_mask     = 1'b0;
        flit_weight_data  = 16'd50;
        @(posedge clk);

        // 5. Send Flit 2 (Compute): A = -150, W = 80, M = 1 -> Product = -12,000
        flit_is_skip      = 1'b0;
        flit_k_idx        = 16'd2;
        flit_act_data     = -16'sd150;
        flit_act_mask     = 1'b1;
        flit_weight_data  = 16'd80;
        @(posedge clk);

        // 6. Test Stale Flit Rejection: Send flit with stale tag = 8'd0
        flit_tag          = 8'd0; // Wrong tag!
        flit_k_idx        = 16'd3;
        flit_act_data     = 16'd500;
        flit_act_mask     = 1'b1;
        flit_weight_data  = 16'd10;
        #(CLK_PERIOD / 2);
        check_condition("TEST 3: Stale Flit Tag Rejection", (stale_flit_rejected == 1'b1 && flit_accepted == 1'b0));

        // 7. Resend Flit 3 with correct tag = 8'd1: A = 100, W = 20 -> Product = 2,000
        @(posedge clk);
        flit_tag          = 8'd1;
        flit_k_idx        = 16'd3;
        flit_act_data     = 16'd100;
        flit_act_mask     = 1'b1;
        flit_weight_data  = 16'd20;
        @(posedge clk);
        flit_valid        = 0;

        #(CLK_PERIOD * 2);

        // Accumulator Expected Value: 25,000 + 0 - 12,000 + 2,000 = 15,000
        check_condition("TEST 4: Accumulator Result Equivalence", (accum_result == 40'sd15000));
        check_condition("TEST 5: Resolved-K Progress (K_total=4)", (k_resolved == 16'd4 && slot_done == 1'b1));
        check_condition("TEST 6: K-Executed Count (3 executed)", (k_executed == 16'd3));
        check_condition("TEST 7: K-Skipped Count (1 skipped)", (k_skipped == 16'd1));
        check_condition("TEST 8: Sticky Saturation False on Nominal Sum", (sticky_saturation == 1'b0));

        // 8. Test Layer Drain Barrier & Quiescence
        @(posedge clk);
        layer_barrier_req = 1;
        #(CLK_PERIOD * 4);
        layer_barrier_req = 0;
        #(CLK_PERIOD * 2);
        check_condition("TEST 9: Layer Barrier Quiescent Synchronization", (slot_quiescent == 1'b1 && slot_alloc_ready == 1'b1));

        $display("==================================================================");
        $display("Test Summary: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All Phase 2 Step 1 RTL Tests Completed Successfully!");
            $finish(0);
        end else begin
            $display("[ERROR] Failures encountered in RTL simulation.");
            $finish(1);
        end
    end

endmodule

