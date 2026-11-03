// =============================================================================
// Testbench: tb_tsk33_policy_validation
// Project: Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation
// Description:
//   Comprehensive verification testbench for the redesigned transparent policy
//   controller (tsk33_transparent_policy_controller).
//   Tests Policy A (Min-Resource) and Policy B (Min-Latency) across:
//     - Exact cycle thresholds (38225, 19121, 9569, and below 9569)
//     - PE resource limits (64, 32, 16, and invalid <16)
//     - Boundary conditions and fallback triggers
//     - Reset assertions and command handshake
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk33_policy_validation;

    logic        clk;
    logic        rst_n;
    logic        cmd_valid;
    logic        cmd_ready;
    logic        policy_select;
    logic [31:0] latency_budget_cycles;
    logic [7:0]  max_active_pe_limit;

    logic [1:0]  resolved_pe_mode;
    logic [7:0]  active_pe_count;
    logic [3:0]  channel_passes;
    logic        fallback_asserted;
    logic        budget_violation;

    int test_count = 0;
    int pass_count = 0;
    int fail_count = 0;
    int f_results;

    // Instantiate DUT
    tsk33_transparent_policy_controller dut (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .cmd_valid             (cmd_valid),
        .cmd_ready             (cmd_ready),
        .policy_select         (policy_select),
        .latency_budget_cycles (latency_budget_cycles),
        .max_active_pe_limit   (max_active_pe_limit),
        .resolved_pe_mode      (resolved_pe_mode),
        .active_pe_count       (active_pe_count),
        .channel_passes        (channel_passes),
        .fallback_asserted     (fallback_asserted),
        .budget_violation      (budget_violation)
    );

    // Clock generator: 100 MHz (10ns period)
    always #5 clk = ~clk;

    // Synchronous test task: drives inputs cleanly on negedge clk
    task run_test(
        input string      test_desc,
        input logic       pol_sel,
        input logic [31:0] budget,
        input logic [7:0]  pe_lim,
        input logic [1:0] exp_mode,
        input logic [7:0] exp_pes,
        input logic       exp_fallback,
        input logic       exp_violation
    );
        test_count++;
        @(negedge clk);
        cmd_valid             = 1'b1;
        policy_select         = pol_sel;
        latency_budget_cycles = budget;
        max_active_pe_limit   = pe_lim;

        @(posedge clk); // DUT clocks in inputs
        #1;
        cmd_valid             = 1'b0;

        @(negedge clk); // Sample outputs when stable
        if (resolved_pe_mode === exp_mode &&
            active_pe_count === exp_pes &&
            fallback_asserted === exp_fallback &&
            budget_violation === exp_violation) begin
            $display("[PASS] Test %02d: %s -> Mode=%0d-PE, Fallback=%0b, Violation=%0b",
                     test_count, test_desc, active_pe_count, fallback_asserted, budget_violation);
            pass_count++;
            $fdisplay(f_results, "%0d,%s,PASS,%0d,%0b,%0b",
                      test_count, test_desc, active_pe_count, fallback_asserted, budget_violation);
        end else begin
            $display("[FAIL] Test %02d: %s -> Expected (Mode=%0b, PEs=%0d, FB=%0b, Viol=%0b), Got (Mode=%0b, PEs=%0d, FB=%0b, Viol=%0b)",
                     test_count, test_desc, exp_mode, exp_pes, exp_fallback, exp_violation,
                     resolved_pe_mode, active_pe_count, fallback_asserted, budget_violation);
            fail_count++;
            $fdisplay(f_results, "%0d,%s,FAIL,%0d,%0b,%0b",
                      test_count, test_desc, active_pe_count, fallback_asserted, budget_violation);
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        cmd_valid = 0;
        policy_select = 0;
        latency_budget_cycles = 0;
        max_active_pe_limit = 0;

        f_results = $fopen("TSK33_RTL_TEST_RESULTS.csv", "w");
        $fdisplay(f_results, "Test_ID,Test_Description,Status,Active_PEs,Fallback_Asserted,Budget_Violation");

        $display("================================================================================");
        $display(" STARTING TSK-33 TRANSPARENT POLICY CONTROLLER VERIFICATION");
        $display("================================================================================");

        // Apply Reset
        #20 rst_n = 1;
        #10;

        // ---------------------------------------------------------------------
        // TEST GROUP 1: POLICY A (MINIMUM-RESOURCE / ENERGY PRIORITY)
        // ---------------------------------------------------------------------
        // Test 1: Relaxed budget (50,000 cyc, 64 PEs max) -> Select smallest (16-PE)
        run_test("Policy A: Relaxed budget (50k cyc, 64 PEs) -> Expect 16-PE",
                 1'b0, 50000, 8'd64, 2'b00, 8'd16, 1'b0, 1'b0);

        // Test 2: Exact 38,225 threshold (boundary case) -> Select 16-PE
        run_test("Policy A: Boundary exactly 38,225 cyc -> Expect 16-PE",
                 1'b0, 38225, 8'd64, 2'b00, 8'd16, 1'b0, 1'b0);

        // Test 3: Tightened to 38,224 (1 cycle below 16-PE) -> Select 32-PE
        run_test("Policy A: 38,224 cyc (below 16-PE) -> Expect 32-PE",
                 1'b0, 38224, 8'd64, 2'b01, 8'd32, 1'b0, 1'b0);

        // Test 4: Exact 19,121 threshold (boundary case) -> Select 32-PE
        run_test("Policy A: Boundary exactly 19,121 cyc -> Expect 32-PE",
                 1'b0, 19121, 8'd64, 2'b01, 8'd32, 1'b0, 1'b0);

        // Test 5: Tightened to 19,120 (1 cycle below 32-PE) -> Select 64-PE
        run_test("Policy A: 19,120 cyc (below 32-PE) -> Expect 64-PE",
                 1'b0, 19120, 8'd64, 2'b10, 8'd64, 1'b0, 1'b0);

        // Test 6: Exact 9,569 threshold -> Select 64-PE
        run_test("Policy A: Boundary exactly 9,569 cyc -> Expect 64-PE",
                 1'b0, 9569, 8'd64, 2'b10, 8'd64, 1'b0, 1'b0);

        // Test 7: Impossible deadline (5,000 cyc, 64 PEs) -> Fallback to fastest (64-PE) with violation
        run_test("Policy A: Impossible deadline (5k cyc) -> Fallback 64-PE with violation",
                 1'b0, 5000, 8'd64, 2'b10, 8'd64, 1'b1, 1'b1);

        // Test 8: Relaxed budget (50k cyc), but PE limit clamped to 32 -> Select 16-PE (smallest feasible)
        run_test("Policy A: 50k cyc, Max 32 PEs -> Expect 16-PE",
                 1'b0, 50000, 8'd32, 2'b00, 8'd16, 1'b0, 1'b0);

        // Test 9: Moderate budget (20k cyc), PE limit clamped to 32 -> Select 32-PE
        run_test("Policy A: 20k cyc, Max 32 PEs -> Expect 32-PE",
                 1'b0, 20000, 8'd32, 2'b01, 8'd32, 1'b0, 1'b0);

        // Test 10: Tight budget (10k cyc), but PE limit clamped to 32 -> Fallback to 32-PE with violation
        run_test("Policy A: 10k cyc, Max 32 PEs -> Fallback to 32-PE (respects PE limit)",
                 1'b0, 10000, 8'd32, 2'b01, 8'd32, 1'b1, 1'b1);

        // ---------------------------------------------------------------------
        // TEST GROUP 2: POLICY B (MINIMUM-LATENCY / PERFORMANCE PRIORITY)
        // ---------------------------------------------------------------------
        // Test 11: PE limit 64 -> Select 64-PE (fastest: 9,569 cycles)
        run_test("Policy B: Max 64 PEs -> Expect 64-PE (Lowest Latency)",
                 1'b1, 50000, 8'd64, 2'b10, 8'd64, 1'b0, 1'b0);

        // Test 12: PE limit clamped to 32 -> Select 32-PE (fastest within limit)
        run_test("Policy B: Max 32 PEs -> Expect 32-PE",
                 1'b1, 50000, 8'd32, 2'b01, 8'd32, 1'b0, 1'b0);

        // Test 13: PE limit clamped to 16 -> Select 16-PE
        run_test("Policy B: Max 16 PEs -> Expect 16-PE",
                 1'b1, 50000, 8'd16, 2'b00, 8'd16, 1'b0, 1'b0);

        // Test 14: Policy B with impossible deadline (5,000 cyc, 64 PEs) -> Select 64-PE with violation
        run_test("Policy B: 5k cyc, 64 PEs -> Select 64-PE with violation",
                 1'b1, 5000, 8'd64, 2'b10, 8'd64, 1'b0, 1'b1);

        // ---------------------------------------------------------------------
        // TEST GROUP 3: DEFENSIVE BOUNDARIES & INVALID DESCRIPTORS
        // ---------------------------------------------------------------------
        // Test 15: Invalid PE limit (<16, e.g. 8) -> Safety block with Mode=2'b11, PEs=0 (TSK-35A)
        run_test("Defensive: Invalid PE limit (8 PEs) -> Block with Mode=2'b11, PEs=0",
                 1'b0, 50000, 8'd8, 2'b11, 8'd0, 1'b1, 1'b1);

        // Test 16: Zero latency budget -> Fallback with violation
        run_test("Defensive: 0 cycle budget -> Fallback with violation",
                 1'b0, 0, 8'd64, 2'b10, 8'd64, 1'b1, 1'b1);

        // Test 17: Asynchronous reset assertion
        test_count++;
        @(negedge clk);
        rst_n = 0; #15; rst_n = 1; #10;
        @(negedge clk);
        if (resolved_pe_mode === 2'b10 && active_pe_count === 8'd64 && channel_passes === 4'd1) begin
            $display("[PASS] Test 17: Asynchronous Reset correctly returns to 64-PE quiescent state");
            pass_count++;
            $fdisplay(f_results, "17,Asynchronous Reset Verification,PASS,64,0,0");
        end else begin
            $display("[FAIL] Test 17: Reset state failed");
            fail_count++;
            $fdisplay(f_results, "17,Asynchronous Reset Verification,FAIL,%0d,0,0", active_pe_count);
        end

        $fclose(f_results);

        $display("================================================================================");
        $display(" TSK-33 POLICY CONTROLLER VERIFICATION SUMMARY");
        $display("   Total Tests Evaluated : %0d", test_count);
        $display("   Passed Assertions     : %0d", pass_count);
        $display("   Failed Assertions     : %0d", fail_count);
        $display("================================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-33 Transparent Policy Tests PASSED with Zero Defects!");
        end else begin
            $display("[ERROR] %0d Tests FAILED!", fail_count);
        end

        $finish;
    end

endmodule
