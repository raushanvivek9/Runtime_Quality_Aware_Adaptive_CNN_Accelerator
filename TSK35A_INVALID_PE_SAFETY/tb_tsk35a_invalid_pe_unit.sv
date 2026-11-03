// =============================================================================
// Testbench: tb_tsk35a_invalid_pe_unit
// Project: Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation
// Task: TSK-35A Invalid PE Limit Safety Correction
// Description:
//   Directed unit verification testbench for the enhanced transparent policy
//   controller (tsk33_transparent_policy_controller.sv).
//   Verifies:
//     - Explicit assertion of invalid_pe_limit and deassertion of execution_enable
//       when max_active_pe_limit < 16 (Pmax = 0, 15).
//     - Valid recognition of Pmax = 16, 31, 32, 63, 64, 128, 255.
//     - Immediate single-cycle recovery from invalid to valid requests.
//     - Clean reset recovery while in invalid state.
//     - Latency boundary transitions at 38225, 19121, 9569 cycles (+/- 1 cycle).
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk35a_invalid_pe_unit;

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
    logic        invalid_pe_limit;
    logic        execution_enable;

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
        .budget_violation      (budget_violation),
        .invalid_pe_limit      (invalid_pe_limit),
        .execution_enable      (execution_enable)
    );

    // 100 MHz Clock (10ns period)
    always #5 clk = ~clk;

    // Race-free synchronous test task
    task run_check(
        input string      test_desc,
        input logic       pol_sel,
        input logic [31:0] budget,
        input logic [7:0]  pe_lim,
        input logic [1:0] exp_mode,
        input logic [7:0] exp_pes,
        input logic [3:0] exp_passes,
        input logic       exp_fallback,
        input logic       exp_violation,
        input logic       exp_invalid,
        input logic       exp_exec_en
    );
        test_count++;
        @(negedge clk);
        cmd_valid             = 1'b1;
        policy_select         = pol_sel;
        latency_budget_cycles = budget;
        max_active_pe_limit   = pe_lim;

        @(posedge clk); // DUT registers inputs
        #1;
        cmd_valid             = 1'b0;

        @(negedge clk); // Sample stable registered outputs
        if (resolved_pe_mode  === exp_mode &&
            active_pe_count   === exp_pes &&
            channel_passes    === exp_passes &&
            fallback_asserted === exp_fallback &&
            budget_violation  === exp_violation &&
            invalid_pe_limit  === exp_invalid &&
            execution_enable  === exp_exec_en) begin
            $display("[PASS] Test %02d: %s -> Mode=%0b, PEs=%0d, Passes=%0d, FB=%0b, Viol=%0b, Invalid=%0b, ExecEn=%0b",
                     test_count, test_desc, resolved_pe_mode, active_pe_count, channel_passes,
                     fallback_asserted, budget_violation, invalid_pe_limit, execution_enable);
            pass_count++;
            $fdisplay(f_results, "%0d,%s,PASS,%0b,%0d,%0d,%0b,%0b,%0b,%0b",
                      test_count, test_desc, resolved_pe_mode, active_pe_count, channel_passes,
                      fallback_asserted, budget_violation, invalid_pe_limit, execution_enable);
        end else begin
            $display("[FAIL] Test %02d: %s", test_count, test_desc);
            $display("       Expected: Mode=%0b, PEs=%0d, Passes=%0d, FB=%0b, Viol=%0b, Invalid=%0b, ExecEn=%0b",
                     exp_mode, exp_pes, exp_passes, exp_fallback, exp_violation, exp_invalid, exp_exec_en);
            $display("       Got:      Mode=%0b, PEs=%0d, Passes=%0d, FB=%0b, Viol=%0b, Invalid=%0b, ExecEn=%0b",
                     resolved_pe_mode, active_pe_count, channel_passes, fallback_asserted, budget_violation, invalid_pe_limit, execution_enable);
            fail_count++;
            $fdisplay(f_results, "%0d,%s,FAIL,%0b,%0d,%0d,%0b,%0b,%0b,%0b",
                      test_count, test_desc, resolved_pe_mode, active_pe_count, channel_passes,
                      fallback_asserted, budget_violation, invalid_pe_limit, execution_enable);
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        cmd_valid = 0;
        policy_select = 0;
        latency_budget_cycles = 0;
        max_active_pe_limit = 0;

        f_results = $fopen("TSK35A_UNIT_RESULTS.csv", "w");
        $fdisplay(f_results, "Test_ID,Description,Status,Mode,PEs,Passes,Fallback,Violation,Invalid_PE_Limit,Execution_Enable");

        $display("================================================================================");
        $display(" STARTING TSK-35A DIRECTED INVALID-PE LIMIT & SAFETY VERIFICATION");
        $display("================================================================================");

        // Apply Reset
        #20 rst_n = 1;
        #10;

        // ---------------------------------------------------------------------
        // GROUP 1: POLICY A INVALID & VALID PE LIMIT CHECKS
        // ---------------------------------------------------------------------
        // Test 01: Pmax = 0 -> Invalid, blocked
        run_check("Policy A: Pmax = 0 (Invalid) -> Block compute",
                  1'b0, 50000, 8'd0, 2'b11, 8'd0, 4'd0, 1'b1, 1'b1, 1'b1, 1'b0);

        // Test 02: Pmax = 15 -> Invalid, blocked
        run_check("Policy A: Pmax = 15 (Invalid) -> Block compute",
                  1'b0, 50000, 8'd15, 2'b11, 8'd0, 4'd0, 1'b1, 1'b1, 1'b1, 1'b0);

        // Test 03: Pmax = 16 -> Valid, selects 16-PE
        run_check("Policy A: Pmax = 16 (Valid Boundary) -> Select 16-PE",
                  1'b0, 50000, 8'd16, 2'b00, 8'd16, 4'd4, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 04: Pmax = 31 -> Valid cap, allows 16-PE only
        run_check("Policy A: Pmax = 31 (Valid Intermediate Cap) -> Select 16-PE",
                  1'b0, 50000, 8'd31, 2'b00, 8'd16, 4'd4, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 05: Pmax = 32 -> Valid cap, budget 20k -> Select 32-PE
        run_check("Policy A: Pmax = 32, Budget 20k -> Select 32-PE",
                  1'b0, 20000, 8'd32, 2'b01, 8'd32, 4'd2, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 06: Pmax = 63 -> Valid cap, budget 20k -> Select 32-PE
        run_check("Policy A: Pmax = 63, Budget 20k -> Select 32-PE",
                  1'b0, 20000, 8'd63, 2'b01, 8'd32, 4'd2, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 07: Pmax = 64 -> Valid cap, budget 10k -> Select 64-PE
        run_check("Policy A: Pmax = 64, Budget 10k -> Select 64-PE",
                  1'b0, 10000, 8'd64, 2'b10, 8'd64, 4'd1, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 08: Pmax = 128 -> Valid cap (>64 allows 64 PEs), budget 10k -> Select 64-PE
        run_check("Policy A: Pmax = 128 (Above 64 Cap), Budget 10k -> Select 64-PE",
                  1'b0, 10000, 8'd128, 2'b10, 8'd64, 4'd1, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 09: Pmax = 255 -> Valid cap (>64 allows 64 PEs), budget 50k -> Select 16-PE (Min Resource)
        run_check("Policy A: Pmax = 255 (Max Byte Cap), Budget 50k -> Select 16-PE",
                  1'b0, 50000, 8'd255, 2'b00, 8'd16, 4'd4, 1'b0, 1'b0, 1'b0, 1'b1);

        // ---------------------------------------------------------------------
        // GROUP 2: POLICY B INVALID & VALID PE LIMIT CHECKS
        // ---------------------------------------------------------------------
        // Test 10: Policy B: Pmax = 0 -> Invalid, blocked
        run_check("Policy B: Pmax = 0 (Invalid) -> Block compute",
                  1'b1, 50000, 8'd0, 2'b11, 8'd0, 4'd0, 1'b1, 1'b1, 1'b1, 1'b0);

        // Test 11: Policy B: Pmax = 15 -> Invalid, blocked
        run_check("Policy B: Pmax = 15 (Invalid) -> Block compute",
                  1'b1, 50000, 8'd15, 2'b11, 8'd0, 4'd0, 1'b1, 1'b1, 1'b1, 1'b0);

        // Test 12: Policy B: Pmax = 16 -> Valid, selects 16-PE
        run_check("Policy B: Pmax = 16 -> Select 16-PE",
                  1'b1, 50000, 8'd16, 2'b00, 8'd16, 4'd4, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 13: Policy B: Pmax = 31 -> Valid cap, selects 16-PE
        run_check("Policy B: Pmax = 31 -> Select 16-PE",
                  1'b1, 50000, 8'd31, 2'b00, 8'd16, 4'd4, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 14: Policy B: Pmax = 32 -> Valid cap, selects 32-PE
        run_check("Policy B: Pmax = 32 -> Select 32-PE",
                  1'b1, 50000, 8'd32, 2'b01, 8'd32, 4'd2, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 15: Policy B: Pmax = 63 -> Valid cap, selects 32-PE
        run_check("Policy B: Pmax = 63 -> Select 32-PE",
                  1'b1, 50000, 8'd63, 2'b01, 8'd32, 4'd2, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 16: Policy B: Pmax = 64 -> Valid cap, selects 64-PE
        run_check("Policy B: Pmax = 64 -> Select 64-PE",
                  1'b1, 50000, 8'd64, 2'b10, 8'd64, 4'd1, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 17: Policy B: Pmax = 128 -> Valid cap, selects 64-PE
        run_check("Policy B: Pmax = 128 -> Select 64-PE",
                  1'b1, 50000, 8'd128, 2'b10, 8'd64, 4'd1, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 18: Policy B: Pmax = 255 -> Valid cap, selects 64-PE
        run_check("Policy B: Pmax = 255 -> Select 64-PE",
                  1'b1, 50000, 8'd255, 2'b10, 8'd64, 4'd1, 1'b0, 1'b0, 1'b0, 1'b1);

        // ---------------------------------------------------------------------
        // GROUP 3: LATENCY BOUNDARY SWEEP (+/- 1 CYCLE) FOR POLICY A
        // ---------------------------------------------------------------------
        // Test 19: 38,224 cyc (below 16-PE) -> Select 32-PE
        run_check("Boundary: 38,224 cyc (1 below 16-PE) -> Expect 32-PE",
                  1'b0, 38224, 8'd64, 2'b01, 8'd32, 4'd2, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 20: 38,225 cyc (exact 16-PE) -> Select 16-PE
        run_check("Boundary: 38,225 cyc (exact 16-PE) -> Expect 16-PE",
                  1'b0, 38225, 8'd64, 2'b00, 8'd16, 4'd4, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 21: 38,226 cyc (1 above 16-PE) -> Select 16-PE
        run_check("Boundary: 38,226 cyc (1 above 16-PE) -> Expect 16-PE",
                  1'b0, 38226, 8'd64, 2'b00, 8'd16, 4'd4, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 22: 19,120 cyc (1 below 32-PE) -> Select 64-PE
        run_check("Boundary: 19,120 cyc (1 below 32-PE) -> Expect 64-PE",
                  1'b0, 19120, 8'd64, 2'b10, 8'd64, 4'd1, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 23: 19,121 cyc (exact 32-PE) -> Select 32-PE
        run_check("Boundary: 19,121 cyc (exact 32-PE) -> Expect 32-PE",
                  1'b0, 19121, 8'd64, 2'b01, 8'd32, 4'd2, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 24: 19,122 cyc (1 above 32-PE) -> Select 32-PE
        run_check("Boundary: 19,122 cyc (1 above 32-PE) -> Expect 32-PE",
                  1'b0, 19122, 8'd64, 2'b01, 8'd32, 4'd2, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 25: 9,568 cyc (1 below 64-PE) -> Fallback 64-PE with violation
        run_check("Boundary: 9,568 cyc (1 below 64-PE) -> Fallback 64-PE",
                  1'b0, 9568, 8'd64, 2'b10, 8'd64, 4'd1, 1'b1, 1'b1, 1'b0, 1'b1);

        // Test 26: 9,569 cyc (exact 64-PE) -> Select 64-PE
        run_check("Boundary: 9,569 cyc (exact 64-PE) -> Expect 64-PE",
                  1'b0, 9569, 8'd64, 2'b10, 8'd64, 4'd1, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 27: 9,570 cyc (1 above 64-PE) -> Select 64-PE
        run_check("Boundary: 9,570 cyc (1 above 64-PE) -> Expect 64-PE",
                  1'b0, 9570, 8'd64, 2'b10, 8'd64, 4'd1, 1'b0, 1'b0, 1'b0, 1'b1);

        // ---------------------------------------------------------------------
        // GROUP 4: RECOVERY & RESET TESTS
        // ---------------------------------------------------------------------
        // Test 28: Invalid Request Followed by Immediate Valid Request
        run_check("Sequence: Apply Invalid Pmax = 0",
                  1'b0, 50000, 8'd0, 2'b11, 8'd0, 4'd0, 1'b1, 1'b1, 1'b1, 1'b0);
        run_check("Sequence: Immediate Valid Pmax = 64 (Verify Clean Single-Cycle Recovery)",
                  1'b0, 50000, 8'd64, 2'b00, 8'd16, 4'd4, 1'b0, 1'b0, 1'b0, 1'b1);

        // Test 29: Reset While in Invalid State
        run_check("Reset Test: Force Invalid Pmax = 15",
                  1'b1, 50000, 8'd15, 2'b11, 8'd0, 4'd0, 1'b1, 1'b1, 1'b1, 1'b0);

        test_count++;
        @(negedge clk);
        rst_n = 0; #15; rst_n = 1; #10;
        @(negedge clk);
        if (resolved_pe_mode === 2'b10 && active_pe_count === 8'd64 && channel_passes === 4'd1 &&
            invalid_pe_limit === 1'b0 && execution_enable === 1'b0) begin
            $display("[PASS] Test %02d: Reset while invalid returned cleanly to default quiescent state", test_count);
            pass_count++;
            $fdisplay(f_results, "%0d,Reset while invalid recovery,PASS,2'b10,64,1,0,0,0,0", test_count);
        end else begin
            $display("[FAIL] Test %02d: Reset recovery failed", test_count);
            fail_count++;
            $fdisplay(f_results, "%0d,Reset while invalid recovery,FAIL,%0b,%0d,%0d,%0b,%0b,%0b,%0b",
                      test_count, resolved_pe_mode, active_pe_count, channel_passes,
                      fallback_asserted, budget_violation, invalid_pe_limit, execution_enable);
        end

        $fclose(f_results);

        $display("================================================================================");
        $display(" TSK-35A DIRECTED UNIT VERIFICATION SUMMARY");
        $display("   Total Assertions Evaluated : %0d", test_count);
        $display("   Passed Assertions          : %0d", pass_count);
        $display("   Failed Assertions          : %0d", fail_count);
        $display("================================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-35A Directed Unit Tests PASSED with Zero Defects!");
        end else begin
            $display("[ERROR] %0d Tests FAILED!", fail_count);
        end

        $finish;
    end

endmodule

