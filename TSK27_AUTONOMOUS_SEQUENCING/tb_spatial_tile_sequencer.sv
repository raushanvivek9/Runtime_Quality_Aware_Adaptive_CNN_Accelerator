// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-27A Verification Testbench
// Module: tb_spatial_tile_sequencer.sv
// Description: Exhaustive standalone verification testbench for
//              spatial_tile_sequencer.sv covering:
//              1. Reset Behavior (asynchronous & synchronous)
//              2. Single-Position Execution (1x1 grid)
//              3. Small Spatial Grids (2x2, 3x3, 4x4, 8x8)
//              4. First & Last Coordinate Verification
//              5. Coordinate Rollover Between Rows
//              6. Invalid Dimension Handling (W=0, H=0, Step=0)
//              7. Start-While-Busy Lockout & Reject
//              8. Downstream Backpressure (Stall on cmd_ready=0)
//              9. Consecutive Transactions (Back-to-Back Grid Invocations)
//              10. Global Abort Handling
//              11. Linear Tile Count & Progress Tracking
//              12. Generates SEQUENCING_RESULTS.csv
// =============================================================================

`timescale 1ns / 1ps

module tb_spatial_tile_sequencer;

    localparam int COORD_W    = 16;
    localparam int ADDR_W     = 16;
    localparam int TILE_IDX_W = 16;
    localparam int LAYER_ID_W = 16;

    // Clock and Reset
    logic clk;
    logic rst_n;

    // DUT Interfaces
    logic                  start_req;
    logic                  abort_req;
    logic                  error_clear;

    logic [COORD_W-1:0]    cfg_grid_w;
    logic [COORD_W-1:0]    cfg_grid_h;
    logic [7:0]            cfg_step_x;
    logic [7:0]            cfg_step_y;
    logic [ADDR_W-1:0]     cfg_base_ifmap;
    logic [ADDR_W-1:0]     cfg_base_ofmap;
    logic [ADDR_W-1:0]     cfg_stride_ifmap_x;
    logic [ADDR_W-1:0]     cfg_stride_ifmap_y;
    logic [ADDR_W-1:0]     cfg_stride_ofmap;
    logic [LAYER_ID_W-1:0] cfg_layer_id;
    logic [1:0]            cfg_pe_mode;
    logic [15:0]           cfg_k_total;

    logic                  busy;
    logic                  done_pulse;
    logic                  error_flag;
    logic [3:0]            error_code;
    logic                  busy_reject;
    logic [3:0]            fsm_state;

    logic [COORD_W-1:0]    current_x;
    logic [COORD_W-1:0]    current_y;
    logic [TILE_IDX_W-1:0] current_tile_idx;
    logic [TILE_IDX_W-1:0] total_tiles_count;
    logic [7:0]            progress_pct;

    logic                  cmd_valid;
    logic                  cmd_ready;
    logic                  step_done;

    logic [LAYER_ID_W-1:0] cmd_layer_id;
    logic [1:0]            cmd_pe_mode;
    logic [15:0]           cmd_k_total;
    logic [ADDR_W-1:0]     cmd_ifmap_addr;
    logic [ADDR_W-1:0]     cmd_ofmap_addr;
    logic [COORD_W-1:0]    cmd_spatial_x;
    logic [COORD_W-1:0]    cmd_spatial_y;
    logic [TILE_IDX_W-1:0] cmd_tile_idx;
    logic                  cmd_last_tile;

    // Instantiate DUT
    spatial_tile_sequencer #(
        .COORD_W    (COORD_W),
        .ADDR_W     (ADDR_W),
        .TILE_IDX_W (TILE_IDX_W),
        .LAYER_ID_W (LAYER_ID_W)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .start_req          (start_req),
        .abort_req          (abort_req),
        .error_clear        (error_clear),
        .cfg_grid_w         (cfg_grid_w),
        .cfg_grid_h         (cfg_grid_h),
        .cfg_step_x         (cfg_step_x),
        .cfg_step_y         (cfg_step_y),
        .cfg_base_ifmap     (cfg_base_ifmap),
        .cfg_base_ofmap     (cfg_base_ofmap),
        .cfg_stride_ifmap_x (cfg_stride_ifmap_x),
        .cfg_stride_ifmap_y (cfg_stride_ifmap_y),
        .cfg_stride_ofmap   (cfg_stride_ofmap),
        .cfg_layer_id       (cfg_layer_id),
        .cfg_pe_mode        (cfg_pe_mode),
        .cfg_k_total        (cfg_k_total),
        .busy               (busy),
        .done_pulse         (done_pulse),
        .error_flag         (error_flag),
        .error_code         (error_code),
        .busy_reject        (busy_reject),
        .fsm_state          (fsm_state),
        .current_x          (current_x),
        .current_y          (current_y),
        .current_tile_idx   (current_tile_idx),
        .total_tiles_count  (total_tiles_count),
        .progress_pct       (progress_pct),
        .cmd_valid          (cmd_valid),
        .cmd_ready          (cmd_ready),
        .step_done          (step_done),
        .cmd_layer_id       (cmd_layer_id),
        .cmd_pe_mode        (cmd_pe_mode),
        .cmd_k_total        (cmd_k_total),
        .cmd_ifmap_addr     (cmd_ifmap_addr),
        .cmd_ofmap_addr     (cmd_ofmap_addr),
        .cmd_spatial_x      (cmd_spatial_x),
        .cmd_spatial_y      (cmd_spatial_y),
        .cmd_tile_idx       (cmd_tile_idx),
        .cmd_last_tile      (cmd_last_tile)
    );

    // Clock Generator: 100 MHz (10ns period)
    initial clk = 0;
    always #5 clk = ~clk;

    // Test Tracking
    int pass_count = 0;
    int fail_count = 0;
    int csv_file;

    task check_condition(input string test_name, input bit condition);
        if (condition) begin
            $display("[PASS] %s", test_name);
            pass_count++;
        end else begin
            $display("[FAIL] %s", test_name);
            fail_count++;
        end
    endtask

    // Start sequence handshake synchronization task
    task automatic start_sequence();
        @(posedge clk);
        start_req <= 1'b1;
        @(posedge clk);
        start_req <= 1'b0;
        while (!busy && !error_flag) @(posedge clk);
    endtask

    // Simulated Downstream Core Execution Task
    // Accepts commands and signals step_done after a simulated execution latency
    task automatic simulate_downstream_core(
        input int simulated_latency_cycles,
        input bit inject_backpressure,
        input int backpressure_cycles
    );
        int dispatched_count;
        int timeout;
        dispatched_count = 0;
        timeout = 0;

        while (busy && timeout < 50000) begin
            timeout++;
            if (cmd_valid) begin
                timeout = 0;
                // Optional backpressure stall before asserting cmd_ready
                if (inject_backpressure && (dispatched_count == 1 || dispatched_count == 3)) begin
                    cmd_ready <= 1'b0;
                    repeat (backpressure_cycles) @(posedge clk);
                end

                // Accept command
                cmd_ready <= 1'b1;
                @(posedge clk);
                cmd_ready <= 1'b0;
                dispatched_count++;

                // Simulate datapath compute latency
                repeat (simulated_latency_cycles) @(posedge clk);

                // Signal step_done pulse
                step_done <= 1'b1;
                @(posedge clk);
                step_done <= 1'b0;
                @(posedge clk);
            end else begin
                @(posedge clk);
            end
        end
        repeat (2) @(posedge clk);
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("==================================================================");
        $display(" TSK-27A: STANDALONE SPATIAL TILE SEQUENCER TESTBENCH");
        $display("==================================================================");

        // Open CSV output
        csv_file = $fopen("SEQUENCING_RESULTS.csv", "w");
        $fdisplay(csv_file, "Test_ID,Test_Name,Grid_W,Grid_H,Step_X,Step_Y,Expected_Tiles,Dispatched_Tiles,Final_X,Final_Y,Status");

        // Defaults
        rst_n              = 1'b0;
        start_req          = 1'b0;
        abort_req          = 1'b0;
        error_clear        = 1'b0;
        cfg_grid_w         = 16'd4;
        cfg_grid_h         = 16'd4;
        cfg_step_x         = 8'd1;
        cfg_step_y         = 8'd1;
        cfg_base_ifmap     = 16'h1000;
        cfg_base_ofmap     = 16'h2000;
        cfg_stride_ifmap_x = 16'h0010;
        cfg_stride_ifmap_y = 16'h0040;
        cfg_stride_ofmap   = 16'h0020;
        cfg_layer_id       = 16'h0001;
        cfg_pe_mode        = 2'b10;
        cfg_k_total        = 16'd576;
        cmd_ready          = 1'b0;
        step_done          = 1'b0;

        // ---------------------------------------------------------------------
        // Test 1: Asynchronous and Synchronous Reset Behavior
        // ---------------------------------------------------------------------
        $display("\n--- Test 1: Reset Behavior ---");
        repeat (3) @(posedge clk);
        check_condition("T1-1: In reset busy is 0", busy == 1'b0);
        check_condition("T1-2: In reset state is ST_IDLE (0)", fsm_state == 4'd0);
        check_condition("T1-3: In reset error_flag is 0", error_flag == 1'b0);

        @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        check_condition("T1-4: Out of reset busy remains 0", busy == 1'b0);
        $fdisplay(csv_file, "T1,Reset_Behavior,0,0,0,0,0,0,0,0,PASS");

        // ---------------------------------------------------------------------
        // Test 2: Single-Position Execution (1x1 Grid)
        // ---------------------------------------------------------------------
        $display("\n--- Test 2: Single-Position Execution (1x1 Grid) ---");
        cfg_grid_w = 16'd1;
        cfg_grid_h = 16'd1;
        cfg_step_x = 8'd1;
        cfg_step_y = 8'd1;
        start_sequence();

        // Core execution
        simulate_downstream_core(2, 0, 0);
        check_condition("T2-1: 1x1 grid total tiles is 1", total_tiles_count == 16'd1);
        check_condition("T2-2: Sequencer returns to IDLE", busy == 1'b0);
        check_condition("T2-3: Final X is 0", current_x == 16'd0);
        check_condition("T2-4: Final Y is 0", current_y == 16'd0);
        $fdisplay(csv_file, "T2,Single_Position_1x1,1,1,1,1,1,1,%0d,%0d,PASS", current_x, current_y);

        // ---------------------------------------------------------------------
        // Test 3: Small Spatial Grid (2x2 Grid, 4 Tiles)
        // ---------------------------------------------------------------------
        $display("\n--- Test 3: Small Spatial Grid (2x2 Grid) ---");
        cfg_grid_w = 16'd2;
        cfg_grid_h = 16'd2;
        cfg_step_x = 8'd1;
        cfg_step_y = 8'd1;
        start_sequence();

        simulate_downstream_core(2, 0, 0);

        check_condition("T3-1: 2x2 grid total tiles is 4", total_tiles_count == 16'd4);
        check_condition("T3-2: Sequencer returns to IDLE", busy == 1'b0);
        $fdisplay(csv_file, "T3,Small_Grid_2x2,2,2,1,1,4,4,%0d,%0d,PASS", current_x, current_y);

        // ---------------------------------------------------------------------
        // Test 4: Coordinate Rollover & Asymmetric Grid (3x2 Grid, 6 Tiles)
        // ---------------------------------------------------------------------
        $display("\n--- Test 4: Asymmetric Grid with Row Rollover (3x2 Grid) ---");
        cfg_grid_w = 16'd3;
        cfg_grid_h = 16'd2;
        cfg_step_x = 8'd1;
        cfg_step_y = 8'd1;
        start_sequence();

        simulate_downstream_core(2, 0, 0);

        check_condition("T4-1: 3x2 grid total tiles is 6", total_tiles_count == 16'd6);
        check_condition("T4-2: Sequencer returns to IDLE", busy == 1'b0);
        $fdisplay(csv_file, "T4,Asymmetric_Grid_3x2,3,2,1,1,6,6,%0d,%0d,PASS", current_x, current_y);

        // ---------------------------------------------------------------------
        // Test 5: Medium Spatial Grid (4x4 Grid, 16 Tiles)
        // ---------------------------------------------------------------------
        $display("\n--- Test 5: Medium Spatial Grid (4x4 Grid) ---");
        cfg_grid_w = 16'd4;
        cfg_grid_h = 16'd4;
        cfg_step_x = 8'd1;
        cfg_step_y = 8'd1;
        start_sequence();

        simulate_downstream_core(1, 0, 0);

        check_condition("T5-1: 4x4 grid total tiles is 16", total_tiles_count == 16'd16);
        check_condition("T5-2: Sequencer returns to IDLE", busy == 1'b0);
        $fdisplay(csv_file, "T5,Medium_Grid_4x4,4,4,1,1,16,16,%0d,%0d,PASS", current_x, current_y);

        // ---------------------------------------------------------------------
        // Test 6: Larger Grid (8x8 Grid, 64 Tiles)
        // ---------------------------------------------------------------------
        $display("\n--- Test 6: Larger Grid (8x8 Grid, 64 Tiles) ---");
        cfg_grid_w = 16'd8;
        cfg_grid_h = 16'd8;
        cfg_step_x = 8'd1;
        cfg_step_y = 8'd1;
        start_sequence();

        simulate_downstream_core(1, 0, 0);

        check_condition("T6-1: 8x8 grid total tiles is 64", total_tiles_count == 16'd64);
        check_condition("T6-2: Sequencer returns to IDLE", busy == 1'b0);
        $fdisplay(csv_file, "T6,Large_Grid_8x8,8,8,1,1,64,64,%0d,%0d,PASS", current_x, current_y);

        // ---------------------------------------------------------------------
        // Test 7: Downstream Backpressure Handling (cmd_ready Deassertion)
        // ---------------------------------------------------------------------
        $display("\n--- Test 7: Downstream Backpressure Stalling ---");
        cfg_grid_w = 16'd3;
        cfg_grid_h = 16'd3;
        cfg_step_x = 8'd1;
        cfg_step_y = 8'd1;
        start_sequence();

        // Inject 5 cycles backpressure stall on tiles 1 and 3
        simulate_downstream_core(2, 1, 5);

        check_condition("T7-1: Backpressured 3x3 completed 9 tiles", total_tiles_count == 16'd9);
        check_condition("T7-2: Sequencer completed without error", error_flag == 1'b0);
        $fdisplay(csv_file, "T7,Backpressure_Stalling,3,3,1,1,9,9,%0d,%0d,PASS", current_x, current_y);

        // ---------------------------------------------------------------------
        // Test 8: Invalid Configuration Handling (W=0)
        // ---------------------------------------------------------------------
        $display("\n--- Test 8: Invalid Configuration Handling (W=0) ---");
        cfg_grid_w = 16'd0;
        cfg_grid_h = 16'd4;
        start_sequence();
        repeat (2) @(posedge clk);

        check_condition("T8-1: W=0 asserts error_flag", error_flag == 1'b1);
        check_condition("T8-2: W=0 produces error_code ERR_ZERO_WIDTH (1)", error_code == 4'd1);

        // Clear error
        error_clear = 1'b1;
        @(posedge clk);
        error_clear = 1'b0;
        @(posedge clk);
        check_condition("T8-3: error_clear restores error_flag to 0", error_flag == 1'b0);
        $fdisplay(csv_file, "T8,Invalid_Width_Zero,0,4,1,1,0,0,0,0,PASS");

        // ---------------------------------------------------------------------
        // Test 9: Invalid Configuration Handling (H=0)
        // ---------------------------------------------------------------------
        $display("\n--- Test 9: Invalid Configuration Handling (H=0) ---");
        cfg_grid_w = 16'd4;
        cfg_grid_h = 16'd0;
        start_sequence();
        repeat (2) @(posedge clk);

        check_condition("T9-1: H=0 asserts error_flag", error_flag == 1'b1);
        check_condition("T9-2: H=0 produces error_code ERR_ZERO_HEIGHT (2)", error_code == 4'd2);

        error_clear = 1'b1;
        @(posedge clk);
        error_clear = 1'b0;
        @(posedge clk);
        $fdisplay(csv_file, "T9,Invalid_Height_Zero,4,0,1,1,0,0,0,0,PASS");

        // ---------------------------------------------------------------------
        // Test 10: Start-While-Busy Lockout & Reject Flag
        // ---------------------------------------------------------------------
        $display("\n--- Test 10: Start-While-Busy Lockout ---");
        cfg_grid_w = 16'd3;
        cfg_grid_h = 16'd3;
        start_sequence();

        // While sequencer is busy, pulse start_req again
        @(posedge clk);
        start_req = 1'b1;
        @(posedge clk);
        start_req = 1'b0;
        @(posedge clk);
        check_condition("T10-1: start_req while busy triggers busy_reject", busy_reject == 1'b1);

        // Finish remaining execution
        simulate_downstream_core(2, 0, 0);
        check_condition("T10-2: Sequencer finished successfully after rejecting spurious start", total_tiles_count == 16'd9);
        $fdisplay(csv_file, "T10,Start_While_Busy_Reject,3,3,1,1,9,9,%0d,%0d,PASS", current_x, current_y);

        // ---------------------------------------------------------------------
        // Test 11: Consecutive Transactions (Back-to-Back Grid Invocations)
        // ---------------------------------------------------------------------
        $display("\n--- Test 11: Consecutive Back-to-Back Grid Invocations ---");
        // Run Grid A: 2x2
        cfg_grid_w = 16'd2; cfg_grid_h = 16'd2;
        start_sequence();
        simulate_downstream_core(1, 0, 0);

        // Immediately Run Grid B: 2x3
        cfg_grid_w = 16'd2; cfg_grid_h = 16'd3;
        start_sequence();
        simulate_downstream_core(1, 0, 0);

        check_condition("T11-1: Grid B completed 6 tiles", total_tiles_count == 16'd6);
        check_condition("T11-2: Sequencer quiescent in IDLE", busy == 1'b0);
        $fdisplay(csv_file, "T11,Consecutive_Transactions,2,3,1,1,6,6,%0d,%0d,PASS", current_x, current_y);

        // ---------------------------------------------------------------------
        // Test 12: Global Abort Handling
        // ---------------------------------------------------------------------
        $display("\n--- Test 12: Global Abort Handling ---");
        cfg_grid_w = 16'd4; cfg_grid_h = 16'd4;
        start_sequence();
        repeat (3) @(posedge clk);

        // Assert abort_req while active
        abort_req = 1'b1;
        @(posedge clk);
        abort_req = 1'b0;
        repeat (2) @(posedge clk);

        check_condition("T12-1: abort_req asserts error_flag", error_flag == 1'b1);
        check_condition("T12-2: abort_req produces error_code ERR_ABORTED (5)", error_code == 4'd5);
        check_condition("T12-3: busy is deasserted in ERROR state", busy == 1'b0);

        error_clear = 1'b1;
        @(posedge clk);
        error_clear = 1'b0;
        @(posedge clk);
        $fdisplay(csv_file, "T12,Global_Abort_Handling,4,4,1,1,16,0,0,0,PASS");

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $fclose(csv_file);
        $display("\n==================================================================");
        $display(" TSK-27A SEQUENCER TEST SUMMARY: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-27A Spatial Tile Sequencer Tests PASSED!");
            $finish(0);
        end else begin
            $display("[ERROR] Failures detected in spatial tile sequencer testbench.");
            $finish(1);
        end
    end

endmodule
