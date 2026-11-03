// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-37 Final Research Evidence Consolidation and Paper Readiness Audit
// Testbench: tb_tsk37_policy_audit.sv
// Description:
//   Phase 6: Independent Policy Behavior & Boundary Verification
//   Audits Policy A (Min Resource) and Policy B (Max Performance) across:
//   - 10 PE caps: 0, 8, 15, 16, 31, 32, 63, 64, 128, 255
//   - 10 Latency budgets: 9568, 9569, 9570, 19120, 19121, 19122, 38224, 38225, 38226, 100000
//   - Total 200 boundary constraint combinations
//   - Verifies invalid PE limit execution blocking (exec_en = 0, invalid_pe_limit = 1)
//   - Verifies single-cycle recovery and reset behavior
//   Outputs: TSK37_ADAPTIVE_POLICY_RESULTS.csv
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk37_policy_audit;

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
                if (cap >= 16 && budget >= 38225) begin
                    exp_mode    = 2'b00;
                    exp_pes     = 8'd16;
                    exp_passes  = 4'd4;
                    exp_exec_en = 1'b1;
                    exp_invalid = 1'b0;
                    exp_fb      = 1'b0;
                    exp_viol    = 1'b0;
                    exp_cycles  = 38225;
                end else if (cap >= 32 && budget >= 19121) begin
                    exp_mode    = 2'b01;
                    exp_pes     = 8'd32;
                    exp_passes  = 4'd2;
                    exp_exec_en = 1'b1;
                    exp_invalid = 1'b0;
                    exp_fb      = 1'b0;
                    exp_viol    = 1'b0;
                    exp_cycles  = 19121;
                end else if (cap >= 64 && budget >= 9569) begin
                    exp_mode    = 2'b10;
                    exp_pes     = 8'd64;
                    exp_passes  = 4'd1;
                    exp_exec_en = 1'b1;
                    exp_invalid = 1'b0;
                    exp_fb      = 1'b0;
                    exp_viol    = 1'b0;
                    exp_cycles  = 9569;
                end else begin
                    // Fallback to highest allowed under cap
                    exp_exec_en = 1'b1;
                    exp_invalid = 1'b0;
                    exp_fb      = 1'b1;
                    exp_viol    = 1'b1;
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
                // Policy B: Maximum Performance
                if (cap >= 64 && budget >= 9569) begin
                    exp_mode    = 2'b10;
                    exp_pes     = 8'd64;
                    exp_passes  = 4'd1;
                    exp_exec_en = 1'b1;
                    exp_invalid = 1'b0;
                    exp_fb      = 1'b0;
                    exp_viol    = 1'b0;
                    exp_cycles  = 9569;
                end else if (cap >= 32 && budget >= 19121) begin
                    exp_mode    = 2'b01;
                    exp_pes     = 8'd32;
                    exp_passes  = 4'd2;
                    exp_exec_en = 1'b1;
                    exp_invalid = 1'b0;
                    exp_fb      = 1'b0;
                    exp_viol    = 1'b0;
                    exp_cycles  = 19121;
                end else if (cap >= 16 && budget >= 38225) begin
                    exp_mode    = 2'b00;
                    exp_pes     = 8'd16;
                    exp_passes  = 4'd4;
                    exp_exec_en = 1'b1;
                    exp_invalid = 1'b0;
                    exp_fb      = 1'b0;
                    exp_viol    = 1'b0;
                    exp_cycles  = 38225;
                end else begin
                    // Fallback to highest allowed under cap
                    exp_exec_en = 1'b1;
                    exp_invalid = 1'b0;
                    exp_fb      = 1'b1;
                    exp_viol    = 1'b1;
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
            end
        end
    endtask

    initial begin
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

        rst_n = 0;
        cmd_valid = 0;
        policy_select = 0;
        latency_budget_cycles = 0;
        max_active_pe_limit = 0;
        test_id = 0;
        pass_count = 0;
        fail_count = 0;

        #(CLK_PERIOD * 3);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        f_out = $fopen("TSK37_RESEARCH_READINESS/TSK37_ADAPTIVE_POLICY_RESULTS.csv", "w");
        if (!f_out) begin
            f_out = $fopen("TSK37_ADAPTIVE_POLICY_RESULTS.csv", "w");
        end
        $fwrite(f_out, "Test_ID,Policy_Type,Max_PE_Cap,Latency_Budget,RTL_PE_Mode,RTL_Active_PEs,RTL_Channel_Passes,RTL_Exec_Enable,RTL_Invalid_Limit,RTL_Fallback,RTL_Budget_Violation,Expected_PE_Mode,Expected_Active_PEs,Expected_Exec_Enable,Expected_Invalid_Limit,Match_Status,Safety_Blocked,Audit_Verdict\n");

        $display("==================================================================");
        $display(" TSK-37: Independent Adaptive Policy Boundary Audit");
        $display("==================================================================");

        // Sweep Policies (0 = Policy A, 1 = Policy B)
        for (int pol = 0; pol < 2; pol++) begin
            for (int c_idx = 0; c_idx < 10; c_idx++) begin
                for (int b_idx = 0; b_idx < 10; b_idx++) begin
                    int cap = pe_caps[c_idx];
                    int bgt = budgets[b_idx];
                    test_id++;

                    predict_independent_policy(pol[0], bgt, cap);

                    // Send command to DUT
                    @(posedge clk);
                    cmd_valid             <= 1'b1;
                    policy_select         <= pol[0];
                    latency_budget_cycles <= bgt;
                    max_active_pe_limit   <= cap[7:0];

                    @(posedge clk);
                    cmd_valid <= 1'b0;

                    // Allow combinatorial / registered resolution
                    #(CLK_PERIOD * 0.1);

                    // Check results
                    if ((resolved_pe_mode   === exp_mode) &&
                        (active_pe_count    === exp_pes) &&
                        (channel_passes     === exp_passes) &&
                        (execution_enable   === exp_exec_en) &&
                        (invalid_pe_limit   === exp_invalid) &&
                        (fallback_asserted  === exp_fb) &&
                        (budget_violation   === exp_viol)) begin
                        pass_count++;
                        $fwrite(f_out, "%0d,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,PASS,%s,VERIFIED\n",
                            test_id,
                            (pol == 0 ? "Policy_A" : "Policy_B"),
                            cap, bgt,
                            resolved_pe_mode, active_pe_count, channel_passes, execution_enable, invalid_pe_limit, fallback_asserted, budget_violation,
                            exp_mode, exp_pes, exp_exec_en, exp_invalid,
                            (exp_exec_en == 1'b0 ? "YES" : "NO")
                        );
                    end else begin
                        fail_count++;
                        $display("[FAIL] Test %0d (Pol=%0d, Cap=%0d, Bgt=%0d): Mode %0d (exp %0d), ExecEn %0d (exp %0d), Inv %0d (exp %0d)",
                            test_id, pol, cap, bgt, resolved_pe_mode, exp_mode, execution_enable, exp_exec_en, invalid_pe_limit, exp_invalid);
                        $fwrite(f_out, "%0d,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,FAIL,%s,FAILED\n",
                            test_id,
                            (pol == 0 ? "Policy_A" : "Policy_B"),
                            cap, bgt,
                            resolved_pe_mode, active_pe_count, channel_passes, execution_enable, invalid_pe_limit, fallback_asserted, budget_violation,
                            exp_mode, exp_pes, exp_exec_en, exp_invalid,
                            (exp_exec_en == 1'b0 ? "YES" : "NO")
                        );
                    end
                end
            end
        end

        // Additional Recovery Test: Send invalid request, then verify immediate recovery on valid request
        @(posedge clk);
        cmd_valid             <= 1'b1;
        policy_select         <= 1'b0;
        latency_budget_cycles <= 32'd10000;
        max_active_pe_limit   <= 8'd8; // Invalid
        @(posedge clk);
        cmd_valid <= 1'b0;
        #(CLK_PERIOD * 0.1);
        if (execution_enable !== 1'b0 || invalid_pe_limit !== 1'b1) begin
            $display("[FAIL] Safety interlock failed on invalid request!");
            fail_count++;
        end

        @(posedge clk);
        cmd_valid             <= 1'b1;
        policy_select         <= 1'b0;
        latency_budget_cycles <= 32'd50000;
        max_active_pe_limit   <= 8'd64; // Valid
        @(posedge clk);
        cmd_valid <= 1'b0;
        #(CLK_PERIOD * 0.1);
        if (execution_enable !== 1'b1 || invalid_pe_limit !== 1'b0 || resolved_pe_mode !== 2'b00) begin
            $display("[FAIL] Immediate recovery failed after invalid request!");
            fail_count++;
        end else begin
            $display("[SUCCESS] Single-cycle recovery after invalid request verified cleanly.");
            pass_count++;
        end

        $fclose(f_out);

        $display("------------------------------------------------------------------");
        $display(" TOTAL TESTS EVALUATED: %0d", test_id + 1);
        $display(" PASSED:               %0d", pass_count);
        $display(" FAILED:               %0d", fail_count);
        $display(" FINAL STATUS:         %s", (fail_count == 0 ? "ALL PASS" : "FAILURES DETECTED"));
        $display("==================================================================");

        if (fail_count > 0) $fatal(1);
        $finish;
    end

endmodule

