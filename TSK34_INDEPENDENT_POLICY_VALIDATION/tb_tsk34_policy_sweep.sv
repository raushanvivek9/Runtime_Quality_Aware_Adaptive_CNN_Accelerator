// =============================================================================
// Testbench: tb_tsk34_policy_sweep
// Project: Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation
// Description:
//   Comprehensive 192-point constraint sweep testbench for TSK-34.
//   Exhaustively evaluates tsk33_transparent_policy_controller across:
//     - 2 Policies: Policy A (0) and Policy B (1)
//     - 8 PE Limits: 0, 15, 16, 31, 32, 63, 64, 128
//     - 12 Latency Budgets: 0, 5000, 9568, 9569, 9570, 19120, 19121, 19122, 38224, 38225, 38226, 100000
//   Outputs full results to TSK34_RTL_SWEEP_OUTPUT.csv for automated comparison
//   against the independent software reference model.
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk34_policy_sweep;

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

    int test_id;
    int f_out;

    // Instantiate DUT (referencing TSK-33 controller)
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

    // 100 MHz Clock (10ns period)
    always #5 clk = ~clk;

    // Test parameter storage
    int pe_limits[0:7];
    int latency_budgets[0:11];

    initial begin
        clk = 0;
        rst_n = 0;
        cmd_valid = 0;
        policy_select = 0;
        latency_budget_cycles = 0;
        max_active_pe_limit = 0;
        test_id = 0;

        // Initialize PE limits
        pe_limits[0] = 0;
        pe_limits[1] = 15;
        pe_limits[2] = 16;
        pe_limits[3] = 31;
        pe_limits[4] = 32;
        pe_limits[5] = 63;
        pe_limits[6] = 64;
        pe_limits[7] = 128;

        // Initialize latency budgets
        latency_budgets[0]  = 0;
        latency_budgets[1]  = 5000;
        latency_budgets[2]  = 9568;
        latency_budgets[3]  = 9569;
        latency_budgets[4]  = 9570;
        latency_budgets[5]  = 19120;
        latency_budgets[6]  = 19121;
        latency_budgets[7]  = 19122;
        latency_budgets[8]  = 38224;
        latency_budgets[9]  = 38225;
        latency_budgets[10] = 38226;
        latency_budgets[11] = 100000;

        f_out = $fopen("TSK34_RTL_SWEEP_OUTPUT.csv", "w");
        $fdisplay(f_out, "Test_ID,Policy,Latency_Budget,PE_Limit,RTL_Mode,RTL_Active_PEs,RTL_Passes,RTL_Fallback,RTL_Violation");

        $display("================================================================================");
        $display(" STARTING TSK-34 192-POINT CONSTRAINT SWEEP VERIFICATION");
        $display("================================================================================");

        // Apply Reset
        #20 rst_n = 1;
        #10;

        // Iterate through Policies: 0 = Policy A, 1 = Policy B
        for (int p_idx = 0; p_idx < 2; p_idx++) begin
            for (int l_idx = 0; l_idx < 8; l_idx++) begin
                for (int b_idx = 0; b_idx < 12; b_idx++) begin
                    test_id++;

                    // Drive synchronously on negedge clk
                    @(negedge clk);
                    cmd_valid             = 1'b1;
                    policy_select         = (p_idx == 1);
                    max_active_pe_limit   = pe_limits[l_idx][7:0];
                    latency_budget_cycles = latency_budgets[b_idx];

                    // Clock rising edge: DUT registers
                    @(posedge clk);
                    #1;
                    cmd_valid             = 1'b0;

                    // Clock falling edge: sample stable outputs
                    @(negedge clk);
                    $fdisplay(f_out, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                              test_id, p_idx, latency_budgets[b_idx], pe_limits[l_idx],
                              resolved_pe_mode, active_pe_count, channel_passes,
                              fallback_asserted, budget_violation);

                    if (test_id % 24 == 0) begin
                        $display("[PROGRESS] Completed %0d / 192 test points...", test_id);
                    end
                end
            end
        end

        $fclose(f_out);
        $display("================================================================================");
        $display(" TSK-34 SWEEP FINISHED: 192 Points Recorded to TSK34_RTL_SWEEP_OUTPUT.csv");
        $display("================================================================================");
        $finish;
    end

endmodule
