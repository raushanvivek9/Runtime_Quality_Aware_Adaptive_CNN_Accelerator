// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-05 Pipelined Layer Command Sequencer Verification
// Module: tb_layer_command_sequencer.sv
// Description: Comprehensive self-checking testbench for layer_command_sequencer.
//              Covers all 16 required verification scenarios including resets,
//              parameter validation, buffer backpressure, PE controller handshakes,
//              compute/drain synchronization, 1-cycle completion pulse timing,
//              multi-layer execution, delayed acknowledgments, error recovery,
//              and back-to-back command pipelining.
// Specification: TSK-05 Verification Specification
// =============================================================================

`timescale 1ns / 1ps

module tb_layer_command_sequencer;

    localparam time CLK_PERIOD = 10ns;
    localparam int LAYER_ID_W  = 16;
    localparam int K_WIDTH     = 16;
    localparam int DEGRADE_W   = 32;

    // Clock and Reset
    logic                      clk;
    logic                      rst_n;

    // Upstream Layer Command Interface
    logic                      cmd_valid;
    wire                       cmd_ready;
    logic [LAYER_ID_W-1:0]     cmd_layer_id;
    logic [1:0]                cmd_pe_mode;
    logic                      cmd_adaptive_en;
    logic [DEGRADE_W-1:0]      cmd_degradation_hat_16;
    logic [DEGRADE_W-1:0]      cmd_degradation_hat_32;
    logic [DEGRADE_W-1:0]      cmd_degradation_hat_64;
    logic                      cmd_use_ping_pong;
    logic                      cmd_req_buf_id;
    logic [K_WIDTH-1:0]        cmd_k_total;

    // Downstream Adaptive PE Controller Interface
    wire                       pe_start_req;
    wire [1:0]                 pe_req_mode;
    wire                       pe_adaptive_policy_en;
    wire [DEGRADE_W-1:0]       pe_degradation_hat_16;
    wire [DEGRADE_W-1:0]       pe_degradation_hat_32;
    wire [DEGRADE_W-1:0]       pe_degradation_hat_64;
    logic                      pe_controller_busy;
    logic                      pe_layer_quiescent;
    logic                      pe_configuration_changed;
    logic                      pe_invalid_configuration;
    wire                       pe_compute_done;
    wire                       pe_drain_done;
    wire                       pe_layer_barrier_req;

    // Downstream Ping-Pong Buffer Controller Interface
    logic                      buf_consumer_ready;
    logic                      buf_consumer_buf_id;
    wire                       buf_consumer_start;
    wire                       buf_consumer_done;
    logic                      buf_consumer_active;

    // Downstream Compute Datapath / Slot Tracker Interface
    wire                       compute_start;
    wire [K_WIDTH-1:0]         compute_k_total;
    logic                      compute_done;
    logic                      drain_done;
    logic                      drain_error;

    // Upstream Status & Notification Interface
    wire                       layer_done_pulse;
    wire [LAYER_ID_W-1:0]      layer_done_id;
    wire                       sequencer_busy;
    wire [3:0]                 sequencer_state;
    wire                       error_flag;
    wire [3:0]                 error_code;
    logic                      error_clear;

    // Test tracking counters
    int test_count = 0;
    int pass_count = 0;
    int fail_count = 0;

    // Multi-layer loop tracking variables (module-level for iverilog compatibility)
    int layer_idx;
    logic [1:0] loop_pe_mode;
    logic [K_WIDTH-1:0] loop_k;
    int wait_cycle;

    // Instantiate Device Under Test
    layer_command_sequencer #(
        .LAYER_ID_W(LAYER_ID_W),
        .K_WIDTH(K_WIDTH),
        .DEGRADE_W(DEGRADE_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_layer_id(cmd_layer_id),
        .cmd_pe_mode(cmd_pe_mode),
        .cmd_adaptive_en(cmd_adaptive_en),
        .cmd_degradation_hat_16(cmd_degradation_hat_16),
        .cmd_degradation_hat_32(cmd_degradation_hat_32),
        .cmd_degradation_hat_64(cmd_degradation_hat_64),
        .cmd_use_ping_pong(cmd_use_ping_pong),
        .cmd_req_buf_id(cmd_req_buf_id),
        .cmd_k_total(cmd_k_total),
        .pe_start_req(pe_start_req),
        .pe_req_mode(pe_req_mode),
        .pe_adaptive_policy_en(pe_adaptive_policy_en),
        .pe_degradation_hat_16(pe_degradation_hat_16),
        .pe_degradation_hat_32(pe_degradation_hat_32),
        .pe_degradation_hat_64(pe_degradation_hat_64),
        .pe_controller_busy(pe_controller_busy),
        .pe_layer_quiescent(pe_layer_quiescent),
        .pe_configuration_changed(pe_configuration_changed),
        .pe_invalid_configuration(pe_invalid_configuration),
        .pe_compute_done(pe_compute_done),
        .pe_drain_done(pe_drain_done),
        .pe_layer_barrier_req(pe_layer_barrier_req),
        .buf_consumer_ready(buf_consumer_ready),
        .buf_consumer_buf_id(buf_consumer_buf_id),
        .buf_consumer_start(buf_consumer_start),
        .buf_consumer_done(buf_consumer_done),
        .buf_consumer_active(buf_consumer_active),
        .compute_start(compute_start),
        .compute_k_total(compute_k_total),
        .compute_done(compute_done),
        .drain_done(drain_done),
        .drain_error(drain_error),
        .layer_done_pulse(layer_done_pulse),
        .layer_done_id(layer_done_id),
        .sequencer_busy(sequencer_busy),
        .sequencer_state(sequencer_state),
        .error_flag(error_flag),
        .error_code(error_code),
        .error_clear(error_clear)
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

    task check_val4(input string tname, input logic [3:0] actual, input logic [3:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
            $display("[PASS] %s: actual=4'd%0d, expected=4'd%0d", tname, actual, expected);
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=4'd%0d, expected=4'd%0d", tname, actual, expected);
        end
    endtask

    task check_val16(input string tname, input logic [15:0] actual, input logic [15:0] expected);
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
        cmd_valid                = 1'b0;
        cmd_layer_id             = '0;
        cmd_pe_mode              = 2'b10;
        cmd_adaptive_en          = 1'b0;
        cmd_degradation_hat_16   = '0;
        cmd_degradation_hat_32   = '0;
        cmd_degradation_hat_64   = '0;
        cmd_use_ping_pong        = 1'b0;
        cmd_req_buf_id           = 1'b0;
        cmd_k_total              = '0;

        pe_controller_busy       = 1'b0;
        pe_layer_quiescent       = 1'b1;
        pe_configuration_changed = 1'b0;
        pe_invalid_configuration = 1'b0;

        buf_consumer_ready       = 1'b0;
        buf_consumer_buf_id      = 1'b0;
        buf_consumer_active      = 1'b0;

        compute_done             = 1'b0;
        drain_done               = 1'b0;
        drain_error              = 1'b0;
        error_clear              = 1'b0;
    endtask

    task reset_system();
        rst_n = 1'b0;
        clear_all_inputs();
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
    endtask

    // Synchronous command issuer
    task issue_cmd(
        input logic [15:0] lid,
        input logic [1:0]  pmode,
        input logic        adpt_en,
        input logic        use_pp,
        input logic        req_buf,
        input logic [15:0] k_tot
    );
        @(negedge clk);
        cmd_valid          = 1'b1;
        cmd_layer_id       = lid;
        cmd_pe_mode        = pmode;
        cmd_adaptive_en    = adpt_en;
        cmd_use_ping_pong  = use_pp;
        cmd_req_buf_id     = req_buf;
        cmd_k_total        = k_tot;
        @(negedge clk);
        cmd_valid          = 1'b0;
    endtask

    // Main Test Program
    initial begin
        $display("==================================================================");
        $display("Starting TSK-05 Layer Command Sequencer Verification");
        $display("==================================================================");

        // ---------------------------------------------------------------------
        // SCENARIO 1: Reset and Initial Idle Behavior
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 1: Reset and Initial Idle Behavior ---");
        reset_system();
        check_val4("S1.1: State is ST_IDLE (0)", sequencer_state, 4'd0);
        check_bool("S1.2: cmd_ready asserted initially", cmd_ready, 1'b1);
        check_bool("S1.3: sequencer_busy is 0", sequencer_busy, 1'b0);
        check_bool("S1.4: layer_done_pulse is 0", layer_done_pulse, 1'b0);
        check_bool("S1.5: error_flag is 0", error_flag, 1'b0);
        check_val4("S1.6: error_code is ERR_NONE (0)", error_code, 4'd0);
        check_bool("S1.7: pe_start_req is 0", pe_start_req, 1'b0);
        check_bool("S1.8: compute_start is 0", compute_start, 1'b0);
        check_bool("S1.9: buf_consumer_start is 0", buf_consumer_start, 1'b0);
        check_bool("S1.10: buf_consumer_done is 0", buf_consumer_done, 1'b0);

        // ---------------------------------------------------------------------
        // SCENARIO 2: Valid Command Acceptance
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 2: Valid Command Acceptance ---");
        // Issue Layer 101: 32-PE, non-ping-pong, K=4
        issue_cmd(16'd101, 2'b01, 1'b0, 1'b0, 1'b0, 16'd4);
        check_bool("S2.1: cmd_ready dropped after command acceptance", cmd_ready, 1'b0);
        check_bool("S2.2: sequencer_busy is asserted", sequencer_busy, 1'b1);
        // After ST_VALIDATE, it advances to ST_CONFIGURE (non-ping-pong)
        @(negedge clk);
        check_bool("S2.3: pe_start_req asserted in ST_CONFIGURE", pe_start_req, 1'b1);
        check_bool("S2.4: pe_req_mode matches latched mode (32-PE)", (pe_req_mode == 2'b01), 1'b1);

        // Clean up scenario by completing Layer 101
        @(negedge clk); // ST_START_COMP
        check_bool("S2.5: compute_start asserted", compute_start, 1'b1);
        @(negedge clk); // ST_WAIT_COMP
        compute_done = 1'b1;
        @(negedge clk); // ST_DRAIN
        compute_done = 1'b0;
        drain_done   = 1'b1;
        pe_layer_quiescent = 1'b1;
        @(negedge clk); // ST_COMPLETE
        drain_done   = 1'b0;
        check_bool("S2.6: layer_done_pulse fired", layer_done_pulse, 1'b1);
        check_val16("S2.7: layer_done_id matches Layer 101", layer_done_id, 16'd101);
        @(negedge clk); // Return to ST_IDLE
        check_bool("S2.8: Returned to ST_IDLE with cmd_ready=1", cmd_ready, 1'b1);

        // ---------------------------------------------------------------------
        // SCENARIO 3: Invalid Command Rejection
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 3: Invalid Command Rejection ---");
        // 3A: Unsupported PE Mode 2'b11
        issue_cmd(16'd102, 2'b11, 1'b0, 1'b0, 1'b0, 16'd10);
        @(negedge clk); // ST_VALIDATE -> ST_ERROR
        check_val4("S3.1: Enters ST_ERROR on mode 2'b11", sequencer_state, 4'd8);
        check_bool("S3.2: error_flag is high", error_flag, 1'b1);
        check_val4("S3.3: error_code is ERR_INVALID_PE_MODE (1)", error_code, 4'd1);
        check_bool("S3.4: compute_start strictly 0 during error", compute_start, 1'b0);
        check_bool("S3.5: cmd_ready is 0 while in error", cmd_ready, 1'b0);

        // Clear error
        @(negedge clk);
        error_clear = 1'b1;
        @(negedge clk);
        error_clear = 1'b0;
        check_val4("S3.6: Returns to ST_IDLE after error_clear", sequencer_state, 4'd0);
        check_bool("S3.7: error_flag cleared", error_flag, 1'b0);

        // 3B: Zero K-Total
        issue_cmd(16'd103, 2'b10, 1'b0, 1'b0, 1'b0, 16'd0);
        @(negedge clk); // ST_VALIDATE -> ST_ERROR
        check_val4("S3.8: Enters ST_ERROR on k_total==0", sequencer_state, 4'd8);
        check_val4("S3.9: error_code is ERR_ZERO_K_TOTAL (2)", error_code, 4'd2);
        check_bool("S3.10: compute_start strictly 0", compute_start, 1'b0);

        // Clear error
        @(negedge clk);
        error_clear = 1'b1;
        @(negedge clk);
        error_clear = 1'b0;
        check_bool("S3.11: Successfully recovered to ST_IDLE", cmd_ready, 1'b1);

        // ---------------------------------------------------------------------
        // SCENARIO 4: Command-Ready Behavior While Busy (Backpressure)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 4: Command-Ready Behavior While Busy ---");
        // Issue Layer 104 with ping-pong enabled
        issue_cmd(16'd104, 2'b00, 1'b0, 1'b1, 1'b0, 16'd8);
        check_bool("S4.1: cmd_ready drops immediately when busy", cmd_ready, 1'b0);

        // Attempt rogue second command while in ST_WAIT_BUF
        @(negedge clk);
        cmd_valid = 1'b1;
        cmd_layer_id = 16'hFFFF;
        @(negedge clk);
        cmd_valid = 1'b0;
        check_bool("S4.2: cmd_ready remains 0, rogue command ignored", cmd_ready, 1'b0);
        check_val4("S4.3: Sequencer remains in ST_WAIT_BUF (2)", sequencer_state, 4'd2);

        // ---------------------------------------------------------------------
        // SCENARIO 5: Buffer-Not-Ready Waiting
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 5: Buffer-Not-Ready Waiting ---");
        // Hold buf_consumer_ready = 0 for 5 cycles
        for (wait_cycle = 0; wait_cycle < 5; wait_cycle++) begin
            @(negedge clk);
            check_val4($sformatf("S5[%0d]: Holding in ST_WAIT_BUF", wait_cycle), sequencer_state, 4'd2);
            check_bool("S5: compute_start not asserted while waiting", compute_start, 1'b0);
        end

        // Now provide ready buffer
        buf_consumer_ready  = 1'b1;
        buf_consumer_buf_id = 1'b0;
        @(negedge clk);
        check_val4("S5.6: Advances to ST_CONFIGURE once buffer ready", sequencer_state, 4'd3);

        // ---------------------------------------------------------------------
        // SCENARIO 6: PE Configuration Request and Acknowledgment
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 6: PE Configuration Request and Acknowledgment ---");
        check_bool("S6.1: pe_start_req pulses high", pe_start_req, 1'b1);
        check_bool("S6.2: pe_req_mode is 16-PE (2'b00)", (pe_req_mode == 2'b00), 1'b1);
        @(negedge clk);
        check_bool("S6.3: pe_start_req drops to 0 after 1 cycle", pe_start_req, 1'b0);

        // ---------------------------------------------------------------------
        // SCENARIO 7: Compute Start Only After Configuration and Input Readiness
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 7: Compute Start Only After Readiness ---");
        check_val4("S7.1: Reaches ST_START_COMP (4)", sequencer_state, 4'd4);
        check_bool("S7.2: compute_start asserted", compute_start, 1'b1);
        check_bool("S7.3: buf_consumer_start asserted", buf_consumer_start, 1'b1);
        check_val16("S7.4: compute_k_total matches Layer 104 (8)", compute_k_total, 16'd8);

        // ---------------------------------------------------------------------
        // SCENARIO 8: Compute Completion Handling
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 8: Compute Completion Handling ---");
        @(negedge clk);
        check_val4("S8.1: Advances to ST_WAIT_COMP (5)", sequencer_state, 4'd5);
        check_bool("S8.2: compute_start deasserted", compute_start, 1'b0);

        // Hold compute_done = 0 for 4 cycles
        repeat (4) @(negedge clk);
        check_val4("S8.3: Still in ST_WAIT_COMP while computing", sequencer_state, 4'd5);

        // Signal compute_done
        compute_done = 1'b1;
        #1;
        check_bool("S8.4: pe_compute_done pulsed", pe_compute_done, 1'b1);
        @(negedge clk);
        compute_done = 1'b0;
        check_val4("S8.5: Advances to ST_DRAIN (6)", sequencer_state, 4'd6);

        // ---------------------------------------------------------------------
        // SCENARIO 9: Drain Completion Handling
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 9: Drain Completion Handling ---");
        check_bool("S9.1: pe_layer_barrier_req asserted in ST_DRAIN", pe_layer_barrier_req, 1'b1);
        pe_layer_quiescent = 1'b0;
        drain_done = 1'b0;
        repeat (3) @(negedge clk);
        check_val4("S9.2: Holds in ST_DRAIN while drain is busy", sequencer_state, 4'd6);

        // Assert drain completion and quiescence
        drain_done = 1'b1;
        pe_layer_quiescent = 1'b1;
        #1;
        check_bool("S9.3: pe_drain_done pulsed", pe_drain_done, 1'b1);
        check_bool("S9.4: buf_consumer_done pulsed to release buffer", buf_consumer_done, 1'b1);
        @(negedge clk);
        drain_done = 1'b0;
        check_val4("S9.5: Advances to ST_COMPLETE (7)", sequencer_state, 4'd7);

        // ---------------------------------------------------------------------
        // SCENARIO 10: Correct Layer-Completion Pulse Timing
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 10: Correct Layer-Completion Pulse Timing ---");
        check_bool("S10.1: layer_done_pulse is exactly 1 in ST_COMPLETE", layer_done_pulse, 1'b1);
        check_val16("S10.2: layer_done_id matches completed Layer 104", layer_done_id, 16'd104);
        @(negedge clk);
        check_bool("S10.3: layer_done_pulse deasserts on next cycle (1-cycle pulse)", layer_done_pulse, 1'b0);
        check_val4("S10.4: FSM cleanly returns to ST_IDLE (0)", sequencer_state, 4'd0);
        check_bool("S10.5: cmd_ready restored to 1", cmd_ready, 1'b1);

        // ---------------------------------------------------------------------
        // SCENARIO 11: Reset While Idle
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 11: Reset While Idle ---");
        @(negedge clk);
        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        check_val4("S11.1: Remains in ST_IDLE after reset", sequencer_state, 4'd0);
        check_bool("S11.2: cmd_ready high post reset", cmd_ready, 1'b1);
        check_bool("S11.3: No spurious done pulse", layer_done_pulse, 1'b0);

        // ---------------------------------------------------------------------
        // SCENARIO 12: Reset During an Active Command
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 12: Reset During Active Command ---");
        issue_cmd(16'd105, 2'b10, 1'b0, 1'b0, 1'b0, 16'd16);
        repeat (2) @(negedge clk);
        check_val4("S12.1: Command in-flight (ST_START_COMP)", sequencer_state, 4'd4);

        // Asynchronous reset mid-command
        #3;
        rst_n = 1'b0;
        #1;
        check_val4("S12.2: Asynchronous reset immediately aborts to ST_IDLE", sequencer_state, 4'd0);
        check_bool("S12.3: sequencer_busy immediately cleared", sequencer_busy, 1'b0);

        @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        check_bool("S12.4: System ready for new commands post mid-flight reset", cmd_ready, 1'b1);

        // ---------------------------------------------------------------------
        // SCENARIO 13: Repeated Commands Across Multiple Layers (5 Layers)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 13: Repeated Commands Across Multiple Layers ---");
        for (layer_idx = 1; layer_idx <= 5; layer_idx++) begin
            loop_pe_mode = (layer_idx % 3 == 0) ? 2'b10 : ((layer_idx % 2 == 0) ? 2'b01 : 2'b00);
            loop_k = 16'd4 + layer_idx;

            issue_cmd(16'd200 + layer_idx, loop_pe_mode, 1'b0, 1'b0, 1'b0, loop_k);
            @(negedge clk); // ST_CONFIGURE
            @(negedge clk); // ST_START_COMP
            @(negedge clk); // ST_WAIT_COMP
            compute_done = 1'b1;
            @(negedge clk); // ST_DRAIN
            compute_done = 1'b0;
            drain_done = 1'b1;
            pe_layer_quiescent = 1'b1;
            @(negedge clk); // ST_COMPLETE
            drain_done = 1'b0;

            check_bool($sformatf("S13[%0d].1: Layer %0d done pulse fired", layer_idx, 200 + layer_idx), layer_done_pulse, 1'b1);
            check_val16($sformatf("S13[%0d].2: Layer %0d ID confirmed", layer_idx, 200 + layer_idx), layer_done_id, 16'd200 + layer_idx);
            @(negedge clk); // ST_IDLE
        end

        // ---------------------------------------------------------------------
        // SCENARIO 14: Delayed Acknowledgments & Variable Latency
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 14: Delayed Acknowledgments ---");
        issue_cmd(16'd301, 2'b01, 1'b0, 1'b1, 1'b1, 16'd20);
        // Delay 1: Buffer ready takes 6 cycles
        buf_consumer_ready = 1'b0;
        repeat (6) @(negedge clk);
        buf_consumer_ready  = 1'b1;
        buf_consumer_buf_id = 1'b1;
        @(negedge clk); // ST_CONFIGURE
        @(negedge clk); // ST_START_COMP
        @(negedge clk); // ST_WAIT_COMP

        // Delay 2: Compute takes 10 cycles
        repeat (10) @(negedge clk);
        compute_done = 1'b1;
        @(negedge clk);
        compute_done = 1'b0;

        // Delay 3: Drain takes 5 cycles
        pe_layer_quiescent = 1'b0;
        drain_done = 1'b0;
        repeat (5) @(negedge clk);
        drain_done = 1'b1;
        pe_layer_quiescent = 1'b1;
        @(negedge clk);
        drain_done = 1'b0;

        check_bool("S14.1: Successfully completed under delayed acknowledgments", layer_done_pulse, 1'b1);
        check_val16("S14.2: Layer 301 ID confirmed", layer_done_id, 16'd301);
        @(negedge clk);

        // ---------------------------------------------------------------------
        // SCENARIO 15: Error Recovery
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 15: Error Recovery ---");
        // Trigger Buffer Mismatch Error (command wants buffer 0, buffer controller offers buffer 1)
        issue_cmd(16'd401, 2'b10, 1'b0, 1'b1, 1'b0, 16'd10);
        buf_consumer_ready  = 1'b1;
        buf_consumer_buf_id = 1'b1; // Mismatch!
        @(negedge clk);
        @(negedge clk);
        check_val4("S15.1: Enters ST_ERROR on buffer mismatch", sequencer_state, 4'd8);
        check_val4("S15.2: error_code is ERR_BUFFER_MISMATCH (4)", error_code, 4'd4);

        // Assert error_clear
        @(negedge clk);
        error_clear = 1'b1;
        @(negedge clk);
        error_clear = 1'b0;
        check_val4("S15.3: Error cleared, returned to ST_IDLE", sequencer_state, 4'd0);
        check_bool("S15.4: cmd_ready restored", cmd_ready, 1'b1);

        // Issue valid recovery command
        issue_cmd(16'd402, 2'b10, 1'b0, 1'b0, 1'b0, 16'd5);
        @(negedge clk);
        @(negedge clk);
        @(negedge clk);
        compute_done = 1'b1;
        @(negedge clk);
        compute_done = 1'b0;
        drain_done = 1'b1;
        pe_layer_quiescent = 1'b1;
        @(negedge clk);
        drain_done = 1'b0;
        check_bool("S15.5: Recovery command Layer 402 completed successfully", layer_done_pulse, 1'b1);
        check_val16("S15.6: Layer 402 ID confirmed", layer_done_id, 16'd402);
        @(negedge clk);

        // ---------------------------------------------------------------------
        // SCENARIO 16: Back-to-Back Commands with No Loss or Duplication
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 16: Back-to-Back Commands ---");
        // Start Command 1 (Layer 501)
        issue_cmd(16'd501, 2'b00, 1'b0, 1'b0, 1'b0, 16'd4);
        @(negedge clk); // ST_CONFIGURE
        @(negedge clk); // ST_START_COMP
        @(negedge clk); // ST_WAIT_COMP
        compute_done = 1'b1;
        @(negedge clk); // ST_DRAIN
        compute_done = 1'b0;
        drain_done = 1'b1;
        pe_layer_quiescent = 1'b1;
        @(negedge clk); // ST_COMPLETE
        drain_done = 1'b0;
        check_bool("S16.1: Layer 501 complete pulse", layer_done_pulse, 1'b1);
        check_val16("S16.2: Layer 501 ID", layer_done_id, 16'd501);

        // Present Command 2 (Layer 502) synchronously as Layer 501 transitions to IDLE
        cmd_valid          = 1'b1;
        cmd_layer_id       = 16'd502;
        cmd_pe_mode        = 2'b01;
        cmd_adaptive_en    = 1'b0;
        cmd_use_ping_pong  = 1'b0;
        cmd_req_buf_id     = 1'b0;
        cmd_k_total        = 16'd8;
        @(negedge clk); // Transition edge: accepted without dead cycle!
        cmd_valid          = 1'b0;
        check_val4("S16.3: Layer 502 accepted immediately into ST_VALIDATE", sequencer_state, 4'd1);

        @(negedge clk); // ST_CONFIGURE
        @(negedge clk); // ST_START_COMP
        check_val16("S16.4: compute_k_total updated to Layer 502 (8)", compute_k_total, 16'd8);
        @(negedge clk); // ST_WAIT_COMP
        compute_done = 1'b1;
        @(negedge clk); // ST_DRAIN
        compute_done = 1'b0;
        drain_done = 1'b1;
        pe_layer_quiescent = 1'b1;
        @(negedge clk); // ST_COMPLETE
        drain_done = 1'b0;
        check_bool("S16.5: Layer 502 complete pulse", layer_done_pulse, 1'b1);
        check_val16("S16.6: Layer 502 ID", layer_done_id, 16'd502);
        @(negedge clk);
        check_bool("S16.7: Returned to ST_IDLE cleanly post back-to-back", cmd_ready, 1'b1);

        // ---------------------------------------------------------------------
        // SCENARIO 17: Drain Error Handling & Recovery (TSK-11 Phase 2D)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 17: Drain Error Handling & Recovery ---");
        issue_cmd(16'd601, 2'b10, 1'b0, 1'b0, 1'b0, 16'd4);
        @(negedge clk); // ST_CONFIGURE
        @(negedge clk); // ST_START_COMP
        @(negedge clk); // ST_WAIT_COMP
        compute_done = 1'b1;
        @(negedge clk); // ST_DRAIN
        compute_done = 1'b0;
        check_val4("S17.1: Sequencer in ST_DRAIN", sequencer_state, 4'd6);

        // Assert drain_error mid-drain
        drain_error = 1'b1;
        @(negedge clk);
        drain_error = 1'b0;
        check_val4("S17.2: Sequencer transitioned to ST_ERROR on drain error", sequencer_state, 4'd8);
        check_bool("S17.3: error_flag asserted", error_flag, 1'b1);
        check_val4("S17.4: error_code is ERR_OFMAP_DRAIN (5)", error_code, 4'd5);
        check_bool("S17.5: cmd_ready deasserted in ST_ERROR", cmd_ready, 1'b0);
        check_bool("S17.6: layer_done_pulse NEVER asserted on drain error", layer_done_pulse, 1'b0);

        // Clear error via error_clear
        @(negedge clk);
        error_clear = 1'b1;
        @(negedge clk);
        error_clear = 1'b0;
        check_val4("S17.7: Sequencer returned to ST_IDLE post error_clear", sequencer_state, 4'd0);
        check_bool("S17.8: error_flag cleared to 0", error_flag, 1'b0);
        check_val4("S17.9: error_code cleared to ERR_NONE (0)", error_code, 4'd0);
        check_bool("S17.10: cmd_ready reasserted", cmd_ready, 1'b1);

        // Issue subsequent valid command without hardware reset
        issue_cmd(16'd602, 2'b10, 1'b0, 1'b0, 1'b0, 16'd2);
        @(negedge clk); // ST_CONFIGURE
        @(negedge clk); // ST_START_COMP
        @(negedge clk); // ST_WAIT_COMP
        compute_done = 1'b1;
        @(negedge clk); // ST_DRAIN
        compute_done = 1'b0;
        drain_done = 1'b1;
        pe_layer_quiescent = 1'b1;
        @(negedge clk); // ST_COMPLETE
        drain_done = 1'b0;
        check_bool("S17.11: Layer 602 layer_done_pulse asserted", layer_done_pulse, 1'b1);
        check_val16("S17.12: Layer 602 layer_done_id correct", layer_done_id, 16'd602);
        @(negedge clk);
        check_bool("S17.13: Sequencer cleanly in ST_IDLE after Layer 602", cmd_ready, 1'b1);

        // ---------------------------------------------------------------------
        // Test Summary
        // ---------------------------------------------------------------------
        $display("\n==================================================================");
        $display("TSK-05 Test Summary: Total=%0d, Passed=%0d, Failed=%0d", test_count, pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-05 Layer Command Sequencer Tests Passed!");
            $finish(0);
        end else begin
            $display("[FAILURE] Some TSK-05 tests failed!");
            $finish(1);
        end
    end

endmodule
