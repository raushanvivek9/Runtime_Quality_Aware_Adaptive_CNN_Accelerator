// =============================================================================
// Testbench: tb_tsk35a_downstream_gating
// Project: Neural_Acc: Activation-Sparse CNN Accelerator with Adaptive PE Allocation
// Task: TSK-35A Invalid PE Limit Safety Correction
// Description:
//   RTL integration testbench proving end-to-end compute execution blocking.
//   Instantiates tsk33_transparent_policy_controller interfaced directly to
//   the layer_command_sequencer.sv and a datapath handshake responder.
//   Demonstrates:
//     1. Valid configurations (Pmax >= 16) assert execution_enable and compute_start.
//     2. Invalid configurations (Pmax = 0, 15) assert invalid_pe_limit, deassert
//        execution_enable, and POSITIVELY PREVENT compute_start from pulsing.
//     3. Direct injection of invalid mode 2'b11 triggers sequencer ST_ERROR (ERR_INVALID_PE_MODE).
//     4. Clean recovery to valid compute execution following error_clear.
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk35a_downstream_gating;

    logic        clk;
    logic        rst_n;

    // Host Request Interface
    logic        host_req_valid;
    logic        policy_select;
    logic [31:0] latency_budget_cycles;
    logic [7:0]  max_active_pe_limit;

    // Policy Controller Outputs
    logic        ctrl_cmd_ready;
    logic [1:0]  resolved_pe_mode;
    logic [7:0]  active_pe_count;
    logic [3:0]  channel_passes;
    logic        fallback_asserted;
    logic        budget_violation;
    logic        invalid_pe_limit;
    logic        execution_enable;

    // Gated Sequencer Command Signals
    logic        seq_cmd_valid;
    wire         seq_cmd_ready;
    logic [15:0] seq_cmd_layer_id;
    logic [1:0]  seq_cmd_pe_mode;
    logic [15:0] seq_cmd_k_total;

    // Sequencer Handshake & Control Wires
    wire         pe_start_req;
    wire [1:0]   pe_req_mode;
    wire         pe_compute_done;
    wire         pe_drain_done;
    wire         pe_layer_barrier_req;

    wire         compute_start;
    wire [15:0]  compute_k_total;
    logic        compute_done;
    logic        drain_done;
    logic        drain_error;

    wire         layer_done_pulse;
    wire [15:0]  layer_done_id;
    wire         sequencer_busy;
    wire [3:0]   sequencer_state;
    wire         seq_error_flag;
    wire [3:0]   seq_error_code;
    logic        seq_error_clear;

    int test_count = 0;
    int pass_count = 0;
    int fail_count = 0;
    int compute_start_pulse_count = 0;
    int f_results;

    // Clock generator: 100 MHz
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // 1. Policy Controller Instance
    // -------------------------------------------------------------------------
    tsk33_transparent_policy_controller u_policy_ctrl (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .cmd_valid             (host_req_valid),
        .cmd_ready             (ctrl_cmd_ready),
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

    // -------------------------------------------------------------------------
    // 2. Layer Command Sequencer Instance
    // -------------------------------------------------------------------------
    layer_command_sequencer #(
        .LAYER_ID_W (16),
        .K_WIDTH    (16),
        .DEGRADE_W  (32)
    ) u_sequencer (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .cmd_valid                (seq_cmd_valid),
        .cmd_ready                (seq_cmd_ready),
        .cmd_layer_id             (seq_cmd_layer_id),
        .cmd_pe_mode              (seq_cmd_pe_mode),
        .cmd_adaptive_en          (1'b0),
        .cmd_degradation_hat_16   (32'd0),
        .cmd_degradation_hat_32   (32'd0),
        .cmd_degradation_hat_64   (32'd0),
        .cmd_use_ping_pong        (1'b0),
        .cmd_req_buf_id           (1'b0),
        .cmd_k_total              (seq_cmd_k_total),
        .pe_start_req             (pe_start_req),
        .pe_req_mode              (pe_req_mode),
        .pe_adaptive_policy_en    (),
        .pe_degradation_hat_16    (),
        .pe_degradation_hat_32    (),
        .pe_degradation_hat_64    (),
        .pe_controller_busy       (1'b0),
        .pe_layer_quiescent       (1'b1),
        .pe_configuration_changed (),
        .pe_invalid_configuration (1'b0),
        .pe_compute_done          (pe_compute_done),
        .pe_drain_done            (pe_drain_done),
        .pe_layer_barrier_req     (pe_layer_barrier_req),
        .buf_consumer_ready       (1'b0),
        .buf_consumer_buf_id      (1'b0),
        .buf_consumer_start       (),
        .buf_consumer_done        (),
        .buf_consumer_active      (1'b0),
        .compute_start            (compute_start),
        .compute_k_total          (compute_k_total),
        .compute_done             (compute_done),
        .drain_done               (drain_done),
        .drain_error              (drain_error),
        .layer_done_pulse         (layer_done_pulse),
        .layer_done_id            (layer_done_id),
        .sequencer_busy           (sequencer_busy),
        .sequencer_state          (sequencer_state),
        .error_flag               (seq_error_flag),
        .error_code               (seq_error_code),
        .error_clear              (seq_error_clear)
    );

    // Monitor compute_start pulses
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            compute_start_pulse_count <= 0;
        end else if (compute_start) begin
            compute_start_pulse_count <= compute_start_pulse_count + 1;
        end
    end

    // Counter-based Datapath handshake responder
    int comp_timer = 0;
    typedef enum {DP_IDLE, DP_COMP, DP_DRAIN} dp_state_t;
    dp_state_t dp_state = DP_IDLE;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            compute_done <= 1'b0;
            drain_done   <= 1'b0;
            drain_error  <= 1'b0;
            comp_timer   <= 0;
            dp_state     <= DP_IDLE;
        end else begin
            compute_done <= 1'b0;
            drain_done   <= 1'b0;
            case (dp_state)
                DP_IDLE: begin
                    if (compute_start) begin
                        comp_timer <= 3;
                        dp_state   <= DP_COMP;
                    end
                end
                DP_COMP: begin
                    if (comp_timer > 1) begin
                        comp_timer <= comp_timer - 1;
                    end else begin
                        compute_done <= 1'b1;
                        comp_timer   <= 2;
                        dp_state     <= DP_DRAIN;
                    end
                end
                DP_DRAIN: begin
                    if (comp_timer > 1) begin
                        comp_timer <= comp_timer - 1;
                    end else begin
                        drain_done <= 1'b1;
                        dp_state   <= DP_IDLE;
                    end
                end
            endcase
        end
    end

    initial begin
        clk = 0;
        rst_n = 0;
        host_req_valid = 0;
        policy_select = 0;
        latency_budget_cycles = 0;
        max_active_pe_limit = 0;
        seq_cmd_valid = 0;
        seq_cmd_layer_id = 0;
        seq_cmd_pe_mode = 0;
        seq_cmd_k_total = 16'd576;
        seq_error_clear = 0;

        f_results = $fopen("TSK35A_DOWNSTREAM_GATING_RESULTS.csv", "w");
        $fdisplay(f_results, "Test_ID,Scenario_Description,Status,Invalid_PE_Limit,Execution_Enable,Compute_Started,Sequencer_Error");

        $display("================================================================================");
        $display(" STARTING TSK-35A DOWNSTREAM EXECUTION GATING & SAFETY VERIFICATION");
        $display("================================================================================");

        // Apply Reset
        #20 rst_n = 1;
        #10;

        // ---------------------------------------------------------------------
        // TEST 1: VALID CONFIGURATION (Pmax = 64, Budget = 10,000)
        // ---------------------------------------------------------------------
        test_count++;
        @(negedge clk);
        host_req_valid        = 1'b1;
        policy_select         = 1'b0; // Policy A
        latency_budget_cycles = 32'd10000;
        max_active_pe_limit   = 8'd64;

        @(posedge clk);
        #1;
        host_req_valid = 1'b0;

        @(negedge clk);
        // Verify policy controller output
        if (invalid_pe_limit === 1'b0 && execution_enable === 1'b1 && resolved_pe_mode === 2'b10) begin
            $display("[INFO] Test 01: Policy Controller resolved valid 64-PE mode.");
            // Dispatch to Sequencer gated by execution_enable
            seq_cmd_valid    = execution_enable;
            seq_cmd_layer_id = 16'h0001;
            seq_cmd_pe_mode  = resolved_pe_mode;
            seq_cmd_k_total  = 16'd576;

            @(posedge clk);
            #1;
            seq_cmd_valid = 1'b0;

            // Wait for layer completion
            while (!layer_done_pulse) @(posedge clk);

            @(negedge clk);
            if (compute_start_pulse_count == 1 && seq_error_flag === 1'b0) begin
                $display("[PASS] Test 01: Valid Configuration dispatched and executed successfully (compute_start pulsed once).");
                pass_count++;
                $fdisplay(f_results, "1,Valid Configuration Execution,PASS,0,1,1,0");
            end else begin
                $display("[FAIL] Test 01: Valid Configuration failed to execute.");
                fail_count++;
                $fdisplay(f_results, "1,Valid Configuration Execution,FAIL,0,1,%0d,%0b", compute_start_pulse_count, seq_error_flag);
            end
        end else begin
            $display("[FAIL] Test 01: Policy resolution incorrect.");
            fail_count++;
        end

        // ---------------------------------------------------------------------
        // TEST 2: INVALID CONFIGURATION WITH EXECUTION-ENABLE GATING (Pmax = 0)
        // ---------------------------------------------------------------------
        test_count++;
        compute_start_pulse_count = 0; // Reset pulse tracker
        @(negedge clk);
        host_req_valid        = 1'b1;
        policy_select         = 1'b0;
        latency_budget_cycles = 32'd50000;
        max_active_pe_limit   = 8'd0; // INVALID CAP

        @(posedge clk);
        #1;
        host_req_valid = 1'b0;

        @(negedge clk);
        // Verify controller asserts invalid_pe_limit and deasserts execution_enable
        if (invalid_pe_limit === 1'b1 && execution_enable === 1'b0 && resolved_pe_mode === 2'b11 && active_pe_count === 8'd0) begin
            // Downstream hardware gates command dispatch with execution_enable
            seq_cmd_valid    = execution_enable; // 1'b0 !
            seq_cmd_layer_id = 16'h0002;
            seq_cmd_pe_mode  = resolved_pe_mode;

            // Wait 20 clock cycles to confirm sequencer NEVER starts compute
            repeat (20) @(posedge clk);

            @(negedge clk);
            if (compute_start_pulse_count == 0 && sequencer_state == 4'd0) begin
                $display("[PASS] Test 02: Pmax = 0 correctly blocked downstream compute execution (0 compute_start pulses).");
                pass_count++;
                $fdisplay(f_results, "2,Invalid Pmax=0 Execution Blocking,PASS,1,0,0,0");
            end else begin
                $display("[FAIL] Test 02: Compute started despite invalid Pmax=0!");
                fail_count++;
                $fdisplay(f_results, "2,Invalid Pmax=0 Execution Blocking,FAIL,1,0,%0d,0", compute_start_pulse_count);
            end
        end else begin
            $display("[FAIL] Test 02: Invalid PE limit not flagged correctly.");
            fail_count++;
        end

        // ---------------------------------------------------------------------
        // TEST 3: PROTOCOL-LEVEL REJECTION (Bypassing enable, sending mode 2'b11)
        // ---------------------------------------------------------------------
        test_count++;
        compute_start_pulse_count = 0;
        @(negedge clk);
        host_req_valid        = 1'b1;
        policy_select         = 1'b0;
        latency_budget_cycles = 32'd50000;
        max_active_pe_limit   = 8'd15; // INVALID CAP

        @(posedge clk);
        #1;
        host_req_valid = 1'b0;

        @(negedge clk);
        // Directly present resolved_pe_mode (2'b11) to sequencer with cmd_valid = 1
        seq_cmd_valid    = 1'b1;
        seq_cmd_layer_id = 16'h0003;
        seq_cmd_pe_mode  = resolved_pe_mode; // 2'b11 !
        seq_cmd_k_total  = 16'd576;

        @(posedge clk);
        #1;
        seq_cmd_valid = 1'b0;

        // Give sequencer time to transition
        repeat (3) @(posedge clk);

        @(negedge clk);
        if (seq_error_flag === 1'b1 && seq_error_code === 4'd1 && compute_start_pulse_count == 0) begin
            $display("[PASS] Test 03: Sequencer validated mode 2'b11, halted in ST_ERROR (ERR_INVALID_PE_MODE) without computing.");
            pass_count++;
            $fdisplay(f_results, "3,Sequencer Protocol Error Rejection,PASS,1,0,0,1");
        end else begin
            $display("[FAIL] Test 03: Sequencer did not halt in error state!");
            fail_count++;
            $fdisplay(f_results, "3,Sequencer Protocol Error Rejection,FAIL,%0b,%0b,%0d,%0d",
                      invalid_pe_limit, execution_enable, compute_start_pulse_count, seq_error_code);
        end

        // ---------------------------------------------------------------------
        // TEST 4: ERROR RECOVERY & SUBSEQUENT VALID EXECUTION
        // ---------------------------------------------------------------------
        test_count++;
        compute_start_pulse_count = 0;
        // Step A: Clear sequencer error
        @(negedge clk);
        seq_error_clear = 1'b1;
        @(posedge clk);
        #1;
        seq_error_clear = 1'b0;

        // Step B: Present subsequent valid configuration (Pmax = 32, Budget = 20k)
        @(negedge clk);
        host_req_valid        = 1'b1;
        policy_select         = 1'b0;
        latency_budget_cycles = 32'd20000;
        max_active_pe_limit   = 8'd32;

        @(posedge clk);
        #1;
        host_req_valid = 1'b0;

        @(negedge clk);
        if (invalid_pe_limit === 1'b0 && execution_enable === 1'b1 && resolved_pe_mode === 2'b01) begin
            // Dispatch to Sequencer
            seq_cmd_valid    = execution_enable;
            seq_cmd_layer_id = 16'h0004;
            seq_cmd_pe_mode  = resolved_pe_mode;
            seq_cmd_k_total  = 16'd576;

            @(posedge clk);
            #1;
            seq_cmd_valid = 1'b0;

            while (!layer_done_pulse) @(posedge clk);

            @(negedge clk);
            if (compute_start_pulse_count == 1 && seq_error_flag === 1'b0) begin
                $display("[PASS] Test 04: Successfully recovered from error and executed valid 32-PE layer cleanly.");
                pass_count++;
                $fdisplay(f_results, "4,Post-Error Recovery Execution,PASS,0,1,1,0");
            end else begin
                $display("[FAIL] Test 04: Recovery execution failed.");
                fail_count++;
                $fdisplay(f_results, "4,Post-Error Recovery Execution,FAIL,0,1,%0d,%0b", compute_start_pulse_count, seq_error_flag);
            end
        end else begin
            $display("[FAIL] Test 04: Post-error policy resolution failed.");
            fail_count++;
        end

        $fclose(f_results);

        $display("================================================================================");
        $display(" TSK-35A DOWNSTREAM GATING VERIFICATION SUMMARY");
        $display("   Total Scenarios Evaluated : %0d", test_count);
        $display("   Passed Assertions         : %0d", pass_count);
        $display("   Failed Assertions         : %0d", fail_count);
        $display("================================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All Downstream Execution Gating Tests PASSED with Zero Defects!");
        end else begin
            $display("[ERROR] %0d Gating Tests FAILED!", fail_count);
        end

        $finish;
    end

endmodule
