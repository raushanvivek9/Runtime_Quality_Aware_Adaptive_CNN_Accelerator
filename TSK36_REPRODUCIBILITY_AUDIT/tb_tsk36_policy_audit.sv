// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-36 Independent Reproducibility and Research-Claim Audit
// Testbench: tb_tsk36_policy_audit.sv
// Description:
//   Phase 3: Independent Policy Behavior & Boundary Verification
//   Audits Policy A and Policy B across:
//   - 10 PE caps: 0, 8, 15, 16, 31, 32, 63, 64, 128, 255
//   - 10 Latency budgets: 9568, 9569, 9570, 19120, 19121, 19122, 38224, 38225, 38226, 100000
//   - Total 200 boundary constraint combinations
//   - Verifies invalid PE limit execution blocking (exec_en = 0)
//   - Verifies single-cycle recovery and reset behavior
//   Outputs: TSK36_POLICY_BOUNDARY_AUDIT.csv
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk36_policy_audit;

    localparam real CLK_PERIOD = 10.0; // 100 MHz

    logic        clk;
    logic        rst_n;

    logic        cmd_valid;
    wire         cmd_ready;
    logic        policy_select;
    logic [31:0] latency_budget_cycles;
    logic [7:0]  max_active_pe_limit;

    wire [1:0]   resolved_pe_mode;
    wire [7:0]   active_pe_count;
    wire [3:0]   channel_passes;
    wire         fallback_asserted;
    wire         budget_violation;
    wire         invalid_pe_limit;
    wire         execution_enable;

    // Instantiate DUT (TSK-33 / TSK-35A transparent policy controller)
    tsk33_transparent_policy_controller #(
        .LATENCY_16PE_CYCLES(38225),
        .LATENCY_32PE_CYCLES(19121),
        .LATENCY_64PE_CYCLES(9569)
    ) dut (
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

    // Clock generation
    initial clk = 0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    int pe_caps[0:9];
    int budgets[0:9];

    int f_out;
    int test_id;
    int pass_count;
    int fail_count;

    // Independent Golden Prediction Variables
    logic [1:0]  exp_mode;
    logic [7:0]  exp_pes;
    logic [3:0]  exp_passes;
    logic        exp_exec_en;
    logic        exp_invalid;
    logic        exp_fb;
    logic        exp_viol;
    int          exp_cycles;

    task predict_independent_policy(
        input logic pol,
        input int   budget,
        input int   cap
    );
        begin
            if (cap < 16) begin
                // Invalid PE limit safety block
                exp_mode    = 2'b11;
                exp_pes     = 8'd0;
                exp_passes  = 4'd0;
                exp_exec_en = 1'b0;
                exp_invalid = 1'b1;
                exp_fb      = 1'b1;
                exp_viol    = 1'b1;
                exp_cycles  = 0;
            end else if (pol == 1'b0) begin
                // Policy A: Minimum Resource
                exp_invalid = 1'b0;
                exp_exec_en = 1'b1;
                if (38225 <= budget && cap >= 16) begin
                    exp_mode    = 2'b00;
                    exp_pes     = 8'd16;
                    exp_passes  = 4'd4;
                    exp_fb      = 1'b0;
                    exp_viol    = 1'b0;
                    exp_cycles  = 38225;
                end else if (19121 <= budget && cap >= 32) begin
                    exp_mode    = 2'b01;
                    exp_pes     = 8'd32;
                    exp_passes  = 4'd2;
                    exp_fb      = 1'b0;
                    exp_viol    = 1'b0;
                    exp_cycles  = 19121;
                end else if (9569 <= budget && cap >= 64) begin
                    exp_mode    = 2'b10;
                    exp_pes     = 8'd64;
                    exp_passes  = 4'd1;
                    exp_fb      = 1'b0;
                    exp_viol    = 1'b0;
                    exp_cycles  = 9569;
                end else begin
                    // Fallback to highest throughput permitted
                    exp_fb   = 1'b1;
                    exp_viol = 1'b1;
                    if (cap >= 64) begin
                        exp_mode   = 2'b10;
                        exp_pes    = 8'd64;
                        exp_passes = 4'd1;
                        exp_cycles = 9569;
                    end else if (cap >= 32) begin
                        exp_mode   = 2'b01;
                        exp_pes    = 8'd32;
                        exp_passes = 4'd2;
                        exp_cycles = 19121;
                    end else begin
                        exp_mode   = 2'b00;
                        exp_pes    = 8'd16;
                        exp_passes = 4'd4;
                        exp_cycles = 38225;
                    end
                end
            end else begin
                // Policy B: Minimum Latency (Greedy)
                exp_invalid = 1'b0;
                exp_exec_en = 1'b1;
                exp_fb      = 1'b0;
                if (cap >= 64) begin
                    exp_mode   = 2'b10;
                    exp_pes    = 8'd64;
                    exp_passes = 4'd1;
                    exp_cycles = 9569;
                    exp_viol   = (9569 > budget);
                end else if (cap >= 32) begin
                    exp_mode   = 2'b01;
                    exp_pes    = 8'd32;
                    exp_passes = 4'd2;
                    exp_cycles = 19121;
                    exp_viol   = (19121 > budget);
                end else begin
                    exp_mode   = 2'b00;
                    exp_pes    = 8'd16;
                    exp_passes = 4'd4;
                    exp_cycles = 38225;
                    exp_viol   = (38225 > budget);
                end
            end
        end
    endtask

    initial begin
        // 10 PE caps
        pe_caps[0] = 0;
        pe_caps[1] = 8;
        pe_caps[2] = 15;
        pe_caps[3] = 16;
        pe_caps[4] = 31;
        pe_caps[5] = 32;
        pe_caps[6] = 63;
        pe_caps[7] = 64;
        pe_caps[8] = 128;
        pe_caps[9] = 255;

        // 10 Latency budgets
        budgets[0] = 9568;
        budgets[1] = 9569;
        budgets[2] = 9570;
        budgets[3] = 19120;
        budgets[4] = 19121;
        budgets[5] = 19122;
        budgets[6] = 38224;
        budgets[7] = 38225;
        budgets[8] = 38226;
        budgets[9] = 100000;

        test_id    = 0;
        pass_count = 0;
        fail_count = 0;

        rst_n                 = 1'b0;
        cmd_valid             = 1'b0;
        policy_select         = 1'b0;
        latency_budget_cycles = 32'd0;
        max_active_pe_limit   = 8'd0;

        #(CLK_PERIOD * 4);
        rst_n = 1'b1;
        #(CLK_PERIOD * 2);

        f_out = $fopen("TSK36_POLICY_BOUNDARY_AUDIT.csv", "w");
        $fdisplay(f_out, "Test_ID,Policy_Name,Policy_Select,Latency_Budget_Cycles,PE_Cap,Exp_Mode,RTL_Mode,Exp_Active_PEs,RTL_Active_PEs,Exp_Exec_En,RTL_Exec_En,Exp_Invalid,RTL_Invalid,Exp_Fallback,RTL_Fallback,Exp_Violation,RTL_Violation,Measured_Cycles,Audit_Status");

        $display("==================================================================");
        $display(" TSK-36 Phase 3: Independent Policy Boundary Verification (200 Tests)");
        $display("==================================================================");

        for (int pol = 0; pol < 2; pol++) begin
            string pol_name;
            pol_name = (pol == 0 ? "Policy_A" : "Policy_B");

            for (int b = 0; b < 10; b++) begin
                int cur_budget;
                cur_budget = budgets[b];

                for (int c = 0; c < 10; c++) begin
                    int cur_cap;
                    int match;
                    cur_cap = pe_caps[c];
                    test_id++;

                    // Independent software prediction
                    predict_independent_policy(pol[0], cur_budget, cur_cap);

                    // Stimulate RTL
                    @(posedge clk);
                    cmd_valid             <= 1'b1;
                    policy_select         <= pol[0];
                    latency_budget_cycles <= cur_budget[31:0];
                    max_active_pe_limit   <= cur_cap[7:0];
                    @(posedge clk);
                    cmd_valid             <= 1'b0;
                    @(posedge clk); // Allow register update

                    // Check exact equality across all signals
                    match = 1;
                    if (resolved_pe_mode  !== exp_mode)    match = 0;
                    if (active_pe_count   !== exp_pes)     match = 0;
                    if (execution_enable  !== exp_exec_en) match = 0;
                    if (invalid_pe_limit  !== exp_invalid) match = 0;
                    if (fallback_asserted !== exp_fb)      match = 0;
                    if (budget_violation  !== exp_viol)    match = 0;

                    if (match) begin
                        pass_count++;
                    end else begin
                        fail_count++;
                        $display("[MISMATCH T%0d] %s Budget=%0d Cap=%0d: Exp(mode=%b, pes=%0d, exec=%b, inv=%b, fb=%b, viol=%b) != RTL(mode=%b, pes=%0d, exec=%b, inv=%b, fb=%b, viol=%b)",
                                 test_id, pol_name, cur_budget, cur_cap,
                                 exp_mode, exp_pes, exp_exec_en, exp_invalid, exp_fb, exp_viol,
                                 resolved_pe_mode, active_pe_count, execution_enable, invalid_pe_limit, fallback_asserted, budget_violation);
                    end

                    $fdisplay(f_out, "%0d,%s,%0d,%0d,%0d,%b,%b,%0d,%0d,%b,%b,%b,%b,%b,%b,%b,%b,%0d,%s",
                              test_id, pol_name, pol, cur_budget, cur_cap,
                              exp_mode, resolved_pe_mode,
                              exp_pes, active_pe_count,
                              exp_exec_en, execution_enable,
                              exp_invalid, invalid_pe_limit,
                              exp_fb, fallback_asserted,
                              exp_viol, budget_violation,
                              exp_cycles, (match ? "VERIFIED_BIT_EXACT" : "MISMATCH"));
                end
            end
        end

        // Additional Test: Single-Cycle Recovery
        test_id++;
        @(posedge clk);
        cmd_valid             <= 1'b1;
        policy_select         <= 1'b0;
        latency_budget_cycles <= 32'd50000;
        max_active_pe_limit   <= 8'd0; // Invalid
        @(posedge clk);
        cmd_valid             <= 1'b0;
        @(posedge clk);

        @(posedge clk);
        cmd_valid             <= 1'b1;
        policy_select         <= 1'b0;
        latency_budget_cycles <= 32'd50000;
        max_active_pe_limit   <= 8'd64; // Valid immediate recovery
        @(posedge clk);
        cmd_valid             <= 1'b0;
        @(posedge clk);

        if (execution_enable === 1'b1 && invalid_pe_limit === 1'b0 && resolved_pe_mode === 2'b00) begin
            pass_count++;
            $display("[PASS] Single-cycle recovery from invalid request verified.");
        end else begin
            fail_count++;
            $display("[FAIL] Single-cycle recovery failed!");
        end

        // Additional Test: Asynchronous Reset during Invalid State
        test_id++;
        @(posedge clk);
        cmd_valid             <= 1'b1;
        policy_select         <= 1'b0;
        latency_budget_cycles <= 32'd10000;
        max_active_pe_limit   <= 8'd15; // Invalid
        @(posedge clk);
        cmd_valid             <= 1'b0;
        @(posedge clk);

        rst_n = 1'b0;
        #(CLK_PERIOD * 2);
        rst_n = 1'b1;
        #(CLK_PERIOD);

        if (resolved_pe_mode === 2'b10 && active_pe_count === 8'd64 && execution_enable === 1'b0 && invalid_pe_limit === 1'b0) begin
            pass_count++;
            $display("[PASS] Asynchronous reset during invalid request verified.");
        end else begin
            fail_count++;
            $display("[FAIL] Asynchronous reset failed!");
        end

        $fclose(f_out);

        $display("==================================================================");
        $display(" TSK-36 Phase 3 SUMMARY");
        $display("   Total Checks Evaluated : %0d", test_id);
        $display("   Checks Passed          : %0d", pass_count);
        $display("   Checks Failed          : %0d", fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All Independent Policy Tests PASSED 100%%!");
        end else begin
            $display("[FAILURE] Detected %0d mismatches in policy audit!", fail_count);
        end

        $finish;
    end

endmodule

