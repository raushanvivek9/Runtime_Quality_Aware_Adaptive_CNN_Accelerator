// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Verification)
// Module: tb_adaptive_pe_controller.sv
// Description: Comprehensive Self-Checking Testbench for Adaptive PE Controller
// Tests:
//   1. Reset and initial safe state
//   2. Request for 16-PE mode (Mode 0)
//   3. Request for 32-PE mode (Mode 1)
//   4. Request for 64-PE mode (Mode 2)
//   5. Invalid mode (2'b11) handling & safe error recovery
//   6. Configuration change attempt during active compute (lockout & rejection)
//   7. Safe transition at layer boundary (Drain -> Quiescent -> New Layer)
//   8. Accumulator-clear pulse duration & non-overlap with compute enable
//   9. Start request rejection while busy (Clear, Compute, Drain)
//  10. Asynchronous reset during active transition
//  11. Controller and array configuration consistency (integrated with pe_array_40b)
//  12. Glitch prevention: no spurious enable in non-compute states
//  13. Stage 8A Adaptive degradation policy evaluation
// =============================================================================

`timescale 1ns / 1ps

module tb_adaptive_pe_controller;

    localparam int CLK_PERIOD = 10;
    localparam int ROWS       = 4;
    localparam int COLS       = 16;
    localparam int ACT_W      = 16;
    localparam int WEIGHT_W   = 16;
    localparam int ACCUM_W    = 40;

    // Testbench signals
    logic clk;
    logic rst_n;

    // Controller Command & Workload inputs
    logic        start_req;
    logic [1:0]  req_mode;
    logic        adaptive_policy_en;
    logic [31:0] degradation_hat_16;
    logic [31:0] degradation_hat_32;
    logic [31:0] degradation_hat_64;

    // Execution flow inputs
    logic        compute_enable_in;
    logic        compute_done;
    logic        layer_barrier_req;
    logic        drain_done;
    logic [15:0] col_mask_in;

    // Controller outputs
    wire  [1:0]  cfg_mode;
    wire         enable;
    wire         accum_clear;
    wire         sat_clear;
    wire  [15:0] col_enable;

    wire         controller_busy;
    wire         layer_quiescent;
    wire         configuration_changed;
    wire         fallback_to_64;
    wire         invalid_configuration;
    wire         busy_reject;
    wire  [2:0]  controller_state;

    // PE Array dummy datapath signals for integration verification (Test 11)
    logic signed [ACT_W-1:0]    dummy_act_row [0:ROWS-1];
    logic                       dummy_act_mask_row [0:ROWS-1];
    logic signed [ACT_W-1:0]    dummy_act [0:ROWS-1][0:COLS-1];
    logic                       dummy_act_mask [0:ROWS-1][0:COLS-1];
    logic signed [WEIGHT_W-1:0] dummy_weight [0:ROWS-1][0:COLS-1];

    wire  signed [ACCUM_W-1:0]  array_accum_out [0:ROWS-1][0:COLS-1];
    wire                        array_sticky_sat [0:ROWS-1][0:COLS-1];
    wire                        array_cycle_skipped [0:ROWS-1][0:COLS-1];
    wire  [COLS-1:0]            array_col_active;
    wire  [6:0]                 array_active_pe_count;
    wire                        array_cfg_invalid;
    wire  [COLS-1:0]            array_col_sat;
    wire  [COLS-1:0]            array_col_skipped;
    wire                        array_global_sat;

    // Test bookkeeping
    int pass_count;
    int fail_count;

    // Instantiate Controller Under Test
    adaptive_pe_controller #(
        .COLS(COLS),
        .D_MAX_Q16(16'd3277),
        .USE_FIXED64(1'b0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_req(start_req),
        .req_mode(req_mode),
        .adaptive_policy_en(adaptive_policy_en),
        .degradation_hat_16(degradation_hat_16),
        .degradation_hat_32(degradation_hat_32),
        .degradation_hat_64(degradation_hat_64),
        .compute_enable_in(compute_enable_in),
        .compute_done(compute_done),
        .layer_barrier_req(layer_barrier_req),
        .drain_done(drain_done),
        .col_mask_in(col_mask_in),
        .cfg_mode(cfg_mode),
        .enable(enable),
        .accum_clear(accum_clear),
        .sat_clear(sat_clear),
        .col_enable(col_enable),
        .controller_busy(controller_busy),
        .layer_quiescent(layer_quiescent),
        .configuration_changed(configuration_changed),
        .fallback_to_64(fallback_to_64),
        .invalid_configuration(invalid_configuration),
        .busy_reject(busy_reject),
        .controller_state(controller_state)
    );

    // Instantiate Verified 64-PE Array (TSK-01) driven directly by Controller outputs
    pe_array_40b #(
        .ROWS(ROWS),
        .COLS(COLS),
        .ACT_WIDTH(ACT_W),
        .WEIGHT_WIDTH(WEIGHT_W),
        .ACCUM_WIDTH(ACCUM_W)
    ) u_pe_array (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_mode(cfg_mode),
        .cfg_invalid(array_cfg_invalid),
        .active_pe_count(array_active_pe_count),
        .col_active(array_col_active),
        .enable(enable),
        .col_enable(col_enable),
        .accum_clear(accum_clear),
        .sat_clear(sat_clear),
        .broadcast_act(1'b0),
        .act_data_row(dummy_act_row),
        .act_mask_row(dummy_act_mask_row),
        .act_data(dummy_act),
        .act_mask(dummy_act_mask),
        .weight_data(dummy_weight),
        .accum_out(array_accum_out),
        .sticky_saturation(array_sticky_sat),
        .cycle_skipped(array_cycle_skipped),
        .col_sticky_saturation(array_col_sat),
        .col_cycle_skipped(array_col_skipped),
        .array_sticky_saturation(array_global_sat)
    );

    // Clock generator (100 MHz)
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // Verification check task
    task check(input string test_id, input string test_desc, input logic cond);
        if (cond) begin
            $display("[PASS] %s: %s", test_id, test_desc);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] %s: %s", test_id, test_desc);
            fail_count = fail_count + 1;
        end
    endtask

    // Clear input stimuli
    task clear_inputs();
        start_req          = 0;
        req_mode           = 2'b10;
        adaptive_policy_en = 0;
        degradation_hat_16 = 32'd0;
        degradation_hat_32 = 32'd0;
        degradation_hat_64 = 32'd0;
        compute_enable_in  = 0;
        compute_done       = 0;
        layer_barrier_req  = 0;
        drain_done         = 0;
        col_mask_in        = '1;

        for (int r = 0; r < ROWS; r = r + 1) begin
            dummy_act_row[r]      = '0;
            dummy_act_mask_row[r] = '0;
            for (int c = 0; c < COLS; c = c + 1) begin
                dummy_act[r][c]      = '0;
                dummy_act_mask[r][c] = '0;
                dummy_weight[r][c]   = '0;
            end
        end
    endtask

    // Helper task to cleanly complete compute and drain back to IDLE
    task finish_compute_and_drain();
        start_req = 0;
        // Wait until in ST_COMPUTE
        while (controller_state != 3'b010) @(posedge clk);
        @(negedge clk);
        compute_done = 1;
        @(posedge clk);
        #1; // now in ST_DRAIN
        @(negedge clk);
        compute_done = 0;
        drain_done   = 1;
        @(posedge clk);
        #1; // now in ST_QUIESCENT
        @(negedge clk);
        drain_done   = 0;
        @(posedge clk);
        #1; // now in ST_IDLE
    endtask

    // Main Test Sequence
    initial begin
        pass_count = 0;
        fail_count = 0;

        $display("==================================================================");
        $display("Starting TSK-02 Adaptive PE Controller Verification (tb_adaptive_pe_controller)");
        $display("==================================================================");

        clear_inputs();
        rst_n = 0;
        #(CLK_PERIOD * 2);
        rst_n = 1;
        #(CLK_PERIOD);

        // ---------------------------------------------------------------------
        // TEST 1: Reset and Initial Safe State
        // ---------------------------------------------------------------------
        check("TEST-01A", "Reset initializes FSM to ST_IDLE (3'b000)", (controller_state == 3'b000));
        check("TEST-01B", "Reset defaults cfg_mode to safe 64-PE mode (2'b10)", (cfg_mode == 2'b10));
        check("TEST-01C", "Reset deasserts controller_busy and asserts layer_quiescent", 
              (!controller_busy && layer_quiescent));
        check("TEST-01D", "Reset holds enable and accum_clear low", (!enable && !accum_clear));
        check("TEST-01E", "Reset initializes error and reject flags to zero", 
              (!invalid_configuration && !busy_reject));

        // ---------------------------------------------------------------------
        // TEST 2: Request for 16-PE Mode (Mode 0)
        // ---------------------------------------------------------------------
        @(negedge clk);
        req_mode  = 2'b00; // 16 PE
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-02A", "Start req pulses into ST_CLEAR with accum_clear=1 and sat_clear=1", 
              (controller_state == 3'b001 && accum_clear == 1'b1 && sat_clear == 1'b1 && enable == 1'b0));
        check("TEST-02B", "Configuration changed flag asserted on mode switch", (configuration_changed == 1'b1));
        check("TEST-02C", "cfg_mode updated to 2'b00 in CLEAR state", (cfg_mode == 2'b00));

        @(negedge clk);
        start_req = 0;
        @(posedge clk);
        #1;
        check("TEST-02D", "Advances to ST_COMPUTE: accum_clear deasserted, busy asserted",
              (controller_state == 3'b010 && accum_clear == 1'b0 && controller_busy == 1'b1));
        
        // Check enable gating in compute state
        compute_enable_in = 1;
        #1;
        check("TEST-02E", "Enable tracks compute_enable_in when in ST_COMPUTE", (enable == 1'b1));
        compute_enable_in = 0;
        #1;
        check("TEST-02F", "Enable drops when compute_enable_in is 0 in ST_COMPUTE", (enable == 1'b0));

        // Finish compute
        @(negedge clk);
        compute_done = 1;
        @(posedge clk);
        #1;
        check("TEST-02G", "Compute done advances FSM to ST_DRAIN with enable gated", 
              (controller_state == 3'b011 && enable == 1'b0));

        @(negedge clk);
        compute_done = 0;
        drain_done   = 1;
        @(posedge clk);
        #1;
        check("TEST-02H", "Drain done advances FSM to ST_QUIESCENT", (controller_state == 3'b100));

        @(negedge clk);
        drain_done = 0;
        @(posedge clk);
        #1;
        check("TEST-02I", "Quiescent advances to ST_IDLE when no pending request", (controller_state == 3'b000));

        // ---------------------------------------------------------------------
        // TEST 3: Request for 32-PE Mode (Mode 1)
        // ---------------------------------------------------------------------
        @(negedge clk);
        req_mode  = 2'b01; // 32 PE
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-03A", "Start req (Mode 1) enters ST_CLEAR with cfg_mode=2'b01", 
              (controller_state == 3'b001 && cfg_mode == 2'b01 && accum_clear == 1'b1));
        check("TEST-03B", "configuration_changed asserted for 16PE -> 32PE switch", (configuration_changed == 1'b1));

        finish_compute_and_drain();
        check("TEST-03C", "Mode 1 session completes back to ST_IDLE with cfg_mode preserved", 
              (controller_state == 3'b000 && cfg_mode == 2'b01));

        // ---------------------------------------------------------------------
        // TEST 4: Request for 64-PE Mode (Mode 2)
        // ---------------------------------------------------------------------
        @(negedge clk);
        req_mode  = 2'b10; // 64 PE
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-04A", "Start req (Mode 2) enters ST_CLEAR with cfg_mode=2'b10", 
              (controller_state == 3'b001 && cfg_mode == 2'b10 && accum_clear == 1'b1));

        @(negedge clk);
        start_req = 0;
        @(posedge clk);
        #1;
        check("TEST-04B", "Mode 2 active in ST_COMPUTE", (controller_state == 3'b010 && cfg_mode == 2'b10));

        finish_compute_and_drain();

        // ---------------------------------------------------------------------
        // TEST 5: Invalid Mode (2'b11) Handling & Recovery
        // ---------------------------------------------------------------------
        @(negedge clk);
        req_mode  = 2'b11; // Invalid mode
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-05A", "Requesting invalid mode 2'b11 enters ST_ERROR", (controller_state == 3'b101));
        check("TEST-05B", "invalid_configuration flag asserted on 2'b11", (invalid_configuration == 1'b1));
        check("TEST-05C", "cfg_mode set to 2'b11 during ST_ERROR", (cfg_mode == 2'b11));

        compute_enable_in = 1;
        #1;
        check("TEST-05D", "Enable is strictly 0 in ST_ERROR even with compute_enable_in high", (enable == 1'b0));
        compute_enable_in = 0;

        // Safe recovery with valid request
        @(negedge clk);
        req_mode  = 2'b00; // Recover with Mode 0
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-05E", "Valid request safely recovers from ST_ERROR to ST_CLEAR", 
              (controller_state == 3'b001 && cfg_mode == 2'b00 && invalid_configuration == 1'b0));
        
        finish_compute_and_drain();

        // ---------------------------------------------------------------------
        // TEST 6: Mid-Compute Configuration Change Lockout & Rejection
        // ---------------------------------------------------------------------
        @(negedge clk);
        req_mode  = 2'b00; // Mode 0
        start_req = 1;
        @(posedge clk);
        @(negedge clk);
        start_req = 0;
        @(posedge clk);
        #1;
        // Currently in ST_COMPUTE with Mode 0
        check("TEST-06A", "Established in ST_COMPUTE in Mode 0", (controller_state == 3'b010 && cfg_mode == 2'b00));

        // Attempt rogue configuration change while compute is active
        @(negedge clk);
        req_mode  = 2'b10; // Try switching to 64 PE mid-flight
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-06B", "Rogue start_req mid-compute triggers busy_reject pulse", (busy_reject == 1'b1));
        check("TEST-06C", "cfg_mode locked to 2'b00; rogue 2'b10 strictly rejected", (cfg_mode == 2'b00));
        check("TEST-06D", "FSM remains stably in ST_COMPUTE without interruption", (controller_state == 3'b010));

        finish_compute_and_drain();

        // ---------------------------------------------------------------------
        // TEST 7: Safe Transition at Layer Boundary
        // ---------------------------------------------------------------------
        @(negedge clk);
        req_mode  = 2'b00; // Layer 1 in Mode 0
        start_req = 1;
        @(posedge clk);
        @(negedge clk);
        start_req = 0;
        @(posedge clk);
        // In compute; assert layer barrier request
        @(negedge clk);
        layer_barrier_req = 1;
        @(posedge clk);
        #1;
        check("TEST-07A", "layer_barrier_req triggers transition from COMPUTE to DRAIN", 
              (controller_state == 3'b011));

        @(negedge clk);
        layer_barrier_req = 0;
        drain_done = 1;
        @(posedge clk);
        #1;
        check("TEST-07B", "drain_done advances to ST_QUIESCENT", (controller_state == 3'b100 && layer_quiescent == 1'b1));

        // Start Layer 2 in Mode 1 directly from QUIESCENT state
        @(negedge clk);
        drain_done = 0;
        req_mode  = 2'b01;
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-07C", "New layer start from QUIESCENT seamlessly enters ST_CLEAR with new cfg_mode=2'b01", 
              (controller_state == 3'b001 && cfg_mode == 2'b01 && accum_clear == 1'b1));

        finish_compute_and_drain();

        // ---------------------------------------------------------------------
        // TEST 8: Accumulator-Clear Timing Verification
        // ---------------------------------------------------------------------
        @(negedge clk);
        req_mode  = 2'b10;
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-08A", "accum_clear is exactly 1 during ST_CLEAR", (accum_clear == 1'b1));
        check("TEST-08B", "accum_clear and enable are mutually exclusive (enable==0 when accum_clear==1)", 
              (enable == 1'b0));

        @(negedge clk);
        start_req = 0;
        compute_enable_in = 1;
        @(posedge clk);
        #1;
        check("TEST-08C", "In ST_COMPUTE: accum_clear is 0 while enable is 1", 
              (accum_clear == 1'b0 && enable == 1'b1));

        compute_enable_in = 0;
        finish_compute_and_drain();

        // ---------------------------------------------------------------------
        // TEST 9: Start Request Rejection During CLEAR and DRAIN
        // ---------------------------------------------------------------------
        @(negedge clk);
        req_mode  = 2'b00;
        start_req = 1;
        @(posedge clk);
        // Now in ST_CLEAR
        @(negedge clk);
        start_req = 1; // Pulse redundant start_req during CLEAR
        @(posedge clk);
        #1;
        check("TEST-09A", "start_req during ST_CLEAR triggers busy_reject", (busy_reject == 1'b1));

        // Let it enter COMPUTE, then trigger DRAIN
        @(negedge clk);
        start_req = 0;
        compute_done = 1;
        @(posedge clk);
        #1; // now in ST_DRAIN

        @(negedge clk);
        compute_done = 0;
        start_req = 1; // Pulse redundant start_req during DRAIN
        @(posedge clk);
        #1;
        check("TEST-09B", "start_req during ST_DRAIN triggers busy_reject", (busy_reject == 1'b1));

        @(negedge clk);
        start_req = 0;
        drain_done = 1;
        @(posedge clk);
        @(negedge clk);
        drain_done = 0;
        @(posedge clk);
        #1;

        // ---------------------------------------------------------------------
        // TEST 10: Asynchronous Reset During Active Transition
        // ---------------------------------------------------------------------
        @(negedge clk);
        req_mode  = 2'b00;
        start_req = 1;
        @(posedge clk);
        // Currently in ST_CLEAR
        #2;
        rst_n = 0; // Asynchronous reset assertion
        #1;
        check("TEST-10A", "Asynchronous rst_n immediately resets FSM to ST_IDLE", (controller_state == 3'b000));
        check("TEST-10B", "Asynchronous rst_n immediately drops accum_clear to 0", (accum_clear == 1'b0));
        check("TEST-10C", "Asynchronous rst_n resets cfg_mode to safe default 2'b10", (cfg_mode == 2'b10));

        #(CLK_PERIOD * 2);
        rst_n = 1;
        start_req = 0;
        #(CLK_PERIOD);

        // ---------------------------------------------------------------------
        // TEST 11: Controller and PE Array Consistency (Integrated with pe_array_40b)
        // ---------------------------------------------------------------------
        // Check Mode 0 (16 PE) propagation to array
        @(negedge clk);
        req_mode  = 2'b00;
        start_req = 1;
        @(posedge clk);
        @(negedge clk);
        start_req = 0;
        @(posedge clk);
        #1;
        check("TEST-11A", "Controller Mode 0 -> Array reports active_pe_count == 16", 
              (array_active_pe_count == 7'd16));
        check("TEST-11B", "Controller Mode 0 -> Array reports col_active == 16'h000F", 
              (array_col_active == 16'h000F));

        finish_compute_and_drain();

        // Check Mode 1 (32 PE) propagation to array
        @(negedge clk);
        req_mode = 2'b01;
        start_req = 1;
        @(posedge clk);
        @(negedge clk);
        start_req = 0;
        @(posedge clk);
        #1;
        check("TEST-11C", "Controller Mode 1 -> Array reports active_pe_count == 32", 
              (array_active_pe_count == 7'd32));
        check("TEST-11D", "Controller Mode 1 -> Array reports col_active == 16'h00FF", 
              (array_col_active == 16'h00FF));

        finish_compute_and_drain();

        // Check Mode 2 (64 PE) propagation to array
        @(negedge clk);
        req_mode = 2'b10;
        start_req = 1;
        @(posedge clk);
        @(negedge clk);
        start_req = 0;
        @(posedge clk);
        #1;
        check("TEST-11E", "Controller Mode 2 -> Array reports active_pe_count == 64", 
              (array_active_pe_count == 7'd64));
        check("TEST-11F", "Controller Mode 2 -> Array reports col_active == 16'hFFFF", 
              (array_col_active == 16'hFFFF));

        // Verify MAC accumulation through array driven by controller enable
        @(negedge clk);
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                dummy_act[r][c]      = 16'sd10;
                dummy_act_mask[r][c] = 1'b1;
                dummy_weight[r][c]   = 16'sd25; // 250 per PE
            end
        end
        compute_enable_in = 1;
        @(posedge clk);
        #1;
        check("TEST-11G", "Active PEs compute partial sum driven by controller enable (250)", 
              (array_accum_out[0][0] == 40'sd250 && array_accum_out[3][15] == 40'sd250));

        compute_enable_in = 0;
        finish_compute_and_drain();

        // ---------------------------------------------------------------------
        // TEST 12: Glitch Prevention in Non-Compute States
        // ---------------------------------------------------------------------
        // In ST_IDLE: toggle compute_enable_in high
        compute_enable_in = 1;
        #1;
        check("TEST-12A", "Enable stays strictly 0 in ST_IDLE despite compute_enable_in=1", (enable == 1'b0));

        // Request compute, check ST_CLEAR
        @(negedge clk);
        req_mode  = 2'b00;
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-12B", "Enable stays strictly 0 in ST_CLEAR despite compute_enable_in=1", (enable == 1'b0));

        // Advance to ST_DRAIN
        @(negedge clk);
        start_req = 0;
        @(posedge clk); // to ST_COMPUTE
        @(negedge clk);
        compute_done = 1;
        @(posedge clk);
        #1; // to ST_DRAIN
        check("TEST-12C", "Enable stays strictly 0 in ST_DRAIN despite compute_enable_in=1", (enable == 1'b0));

        @(negedge clk);
        compute_done = 0;
        drain_done = 1;
        @(posedge clk);
        #1; // to ST_QUIESCENT
        check("TEST-12D", "Enable stays strictly 0 in ST_QUIESCENT despite compute_enable_in=1", (enable == 1'b0));

        @(negedge clk);
        drain_done = 0;
        compute_enable_in = 0;
        @(posedge clk);
        #1;

        // ---------------------------------------------------------------------
        // TEST 13: Stage 8A Adaptive Degradation Policy Evaluation
        // ---------------------------------------------------------------------
        // Case A: Low degradation (D16 <= D_MAX) -> Chooses Mode 0 (16 PE)
        @(negedge clk);
        adaptive_policy_en = 1;
        degradation_hat_16 = 32'd2000; // <= 3277
        degradation_hat_32 = 32'd1000;
        degradation_hat_64 = 32'd500;
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-13A", "Adaptive Policy: D16 <= D_MAX selects 16-PE Mode (2'b00)", 
              (cfg_mode == 2'b00 && fallback_to_64 == 1'b0));

        finish_compute_and_drain();

        // Case B: Medium degradation (D16 > D_MAX, D32 <= D_MAX) -> Chooses Mode 1 (32 PE)
        @(negedge clk);
        adaptive_policy_en = 1;
        degradation_hat_16 = 32'd5000; // > 3277
        degradation_hat_32 = 32'd2500; // <= 3277
        degradation_hat_64 = 32'd500;
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-13B", "Adaptive Policy: D16 > D_MAX, D32 <= D_MAX selects 32-PE Mode (2'b01)", 
              (cfg_mode == 2'b01 && fallback_to_64 == 1'b0));

        finish_compute_and_drain();

        // Case C: High degradation (D16 > D_MAX, D32 > D_MAX) -> Fallback to 64 PE (Mode 2)
        @(negedge clk);
        adaptive_policy_en = 1;
        degradation_hat_16 = 32'd8000; // > 3277
        degradation_hat_32 = 32'd6000; // > 3277
        degradation_hat_64 = 32'd500;
        start_req = 1;
        @(posedge clk);
        #1;
        check("TEST-13C", "Adaptive Policy: D32 > D_MAX triggers fallback to 64-PE Mode (2'b10)", 
              (cfg_mode == 2'b10 && fallback_to_64 == 1'b1));

        finish_compute_and_drain();

        // ---------------------------------------------------------------------
        // Final Summary
        // ---------------------------------------------------------------------
        #(CLK_PERIOD * 2);
        $display("==================================================================");
        $display("TSK-02 Test Summary: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");
        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-02 Adaptive PE Controller RTL Tests Passed!");
        end else begin
            $display("[FAILURE] %0d Tests Failed in TSK-02 Adaptive PE Controller RTL!", fail_count);
        end
        $finish;
    end

endmodule
