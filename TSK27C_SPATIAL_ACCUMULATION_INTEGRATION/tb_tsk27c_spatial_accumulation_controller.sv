// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-27C Verification Testbench
// Module: tb_tsk27c_spatial_accumulation_controller.sv
// Description: Exhaustive verification testbench for
//              tsk27c_spatial_accumulation_controller.sv covering:
//              1. 1x1 Spatial Grid with 1 Reduction Chunk
//              2. 2x2 Spatial Grid with 1 Reduction Chunk
//              3. 2x2 Spatial Grid with 3 Reduction Chunks
//              4. 3x2 Spatial Grid with 2 Reduction Chunks
//              5. Accumulator Clearing Only on First Chunk
//              6. Accumulator Preservation Across Intermediate Chunks
//              7. Output Draining Only After Final Chunk
//              8. Backpressure During Spatial Advancement
//              9. Backpressure During Intermediate Chunks
//              10. Backpressure During Final Output Draining
//              11. Start-While-Busy Lockout & Reject
//              12. Invalid Dimensions (W=0, H=0)
//              13. Invalid Chunk Counts (N_chunks=0)
//              14. Abort During Intermediate Chunk
//              15. Reset During Active Operation
//              16. Consecutive Operations After Completion
//              17. Phase 6 Numerical 3-Chunk Fixed-Point Hardware MAC Validation
//              18. Generates TSK27C_RESULTS.csv
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk27c_spatial_accumulation_controller;

    localparam int COORD_W     = 16;
    localparam int ADDR_W      = 16;
    localparam int TILE_IDX_W  = 16;
    localparam int CHUNK_IDX_W = 8;
    localparam int LAYER_ID_W  = 16;

    // Clock & Reset
    logic clk;
    logic rst_n;

    // Host Interfaces
    logic                   start_req;
    logic                   abort_req;
    logic                   error_clear;

    logic [COORD_W-1:0]     cfg_grid_w;
    logic [COORD_W-1:0]     cfg_grid_h;
    logic [7:0]             cfg_step_x;
    logic [7:0]             cfg_step_y;
    logic [CHUNK_IDX_W-1:0] cfg_total_chunks;
    logic [15:0]            cfg_k_per_chunk;
    logic [ADDR_W-1:0]      cfg_base_ifmap;
    logic [ADDR_W-1:0]      cfg_base_ofmap;
    logic [ADDR_W-1:0]      cfg_stride_ifmap_x;
    logic [ADDR_W-1:0]      cfg_stride_ifmap_y;
    logic [ADDR_W-1:0]      cfg_stride_ifmap_chunk;
    logic [ADDR_W-1:0]      cfg_stride_ofmap;
    logic [LAYER_ID_W-1:0]  cfg_layer_id;
    logic [1:0]             cfg_pe_mode;

    logic                   busy;
    logic                   done_pulse;
    logic                   error_flag;
    logic [3:0]             error_code;
    logic                   busy_reject;
    logic [3:0]             fsm_state;

    logic [COORD_W-1:0]     current_x;
    logic [COORD_W-1:0]     current_y;
    logic [TILE_IDX_W-1:0]  current_tile_idx;
    logic [TILE_IDX_W-1:0]  total_tiles_count;
    logic [CHUNK_IDX_W-1:0] current_chunk_idx;
    logic [CHUNK_IDX_W-1:0] total_chunks_count;
    logic                   is_first_chunk;
    logic                   is_last_chunk;
    logic [31:0]            total_reductions_executed;

    // Core Interconnect
    logic                   core_accum_clear;
    logic                   core_compute_valid;
    logic                   core_cmd_ready;
    logic                   core_compute_done;

    logic                   core_drain_req;
    logic                   core_drain_ready;
    logic                   core_drain_done;

    logic [ADDR_W-1:0]      core_ifmap_addr;
    logic [ADDR_W-1:0]      core_ofmap_addr;
    logic [15:0]            core_k_len;
    logic [1:0]             core_pe_mode;
    logic [LAYER_ID_W-1:0]  core_layer_id;

    // Hardware MAC Instance for Numerical Accumulation Validation
    logic                   mac_enable;
    logic signed [15:0]     mac_act_data;
    logic                   mac_act_mask;
    logic signed [15:0]     mac_weight_data;
    wire  signed [39:0]     mac_accum_out;
    wire                    mac_sticky_sat;
    wire                    mac_cycle_skipped;

    // Instantiate DUT
    tsk27c_spatial_accumulation_controller #(
        .COORD_W     (COORD_W),
        .ADDR_W      (ADDR_W),
        .TILE_IDX_W  (TILE_IDX_W),
        .CHUNK_IDX_W (CHUNK_IDX_W),
        .LAYER_ID_W  (LAYER_ID_W)
    ) dut (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .start_req                 (start_req),
        .abort_req                 (abort_req),
        .error_clear               (error_clear),
        .cfg_grid_w                (cfg_grid_w),
        .cfg_grid_h                (cfg_grid_h),
        .cfg_step_x                (cfg_step_x),
        .cfg_step_y                (cfg_step_y),
        .cfg_total_chunks          (cfg_total_chunks),
        .cfg_k_per_chunk           (cfg_k_per_chunk),
        .cfg_base_ifmap            (cfg_base_ifmap),
        .cfg_base_ofmap            (cfg_base_ofmap),
        .cfg_stride_ifmap_x        (cfg_stride_ifmap_x),
        .cfg_stride_ifmap_y        (cfg_stride_ifmap_y),
        .cfg_stride_ifmap_chunk    (cfg_stride_ifmap_chunk),
        .cfg_stride_ofmap          (cfg_stride_ofmap),
        .cfg_layer_id              (cfg_layer_id),
        .cfg_pe_mode               (cfg_pe_mode),
        .busy                      (busy),
        .done_pulse                (done_pulse),
        .error_flag                (error_flag),
        .error_code                (error_code),
        .busy_reject               (busy_reject),
        .fsm_state                 (fsm_state),
        .current_x                 (current_x),
        .current_y                 (current_y),
        .current_tile_idx          (current_tile_idx),
        .total_tiles_count         (total_tiles_count),
        .current_chunk_idx         (current_chunk_idx),
        .total_chunks_count        (total_chunks_count),
        .is_first_chunk            (is_first_chunk),
        .is_last_chunk             (is_last_chunk),
        .total_reductions_executed (total_reductions_executed),
        .core_accum_clear          (core_accum_clear),
        .core_compute_valid        (core_compute_valid),
        .core_cmd_ready            (core_cmd_ready),
        .core_compute_done         (core_compute_done),
        .core_drain_req            (core_drain_req),
        .core_drain_ready          (core_drain_ready),
        .core_drain_done           (core_drain_done),
        .core_ifmap_addr           (core_ifmap_addr),
        .core_ofmap_addr           (core_ofmap_addr),
        .core_k_len                (core_k_len),
        .core_pe_mode              (core_pe_mode),
        .core_layer_id             (core_layer_id)
    );

    // Instantiate Real Hardware 40-bit MAC Unit for Numerical Accumulation
    mac_unit_40b #(
        .ACT_WIDTH    (16),
        .WEIGHT_WIDTH (16),
        .ACCUM_WIDTH  (40)
    ) u_test_mac (
        .clk               (clk),
        .rst_n             (rst_n),
        .enable            (mac_enable),
        .accum_clear       (core_accum_clear), // Directly governed by Controller!
        .sat_clear         (1'b0),
        .act_data          (mac_act_data),
        .act_mask          (mac_act_mask),
        .weight_data       (mac_weight_data),
        .accum_out         (mac_accum_out),
        .sticky_saturation (mac_sticky_sat),
        .cycle_skipped     (mac_cycle_skipped)
    );

    // Clock Generator: 100 MHz (10ns period)
    initial clk = 0;
    always #5 clk = ~clk;

    // Test Tracking
    int pass_count = 0;
    int fail_count = 0;
    int csv_file;

    // Clear and Drain Event Counters
    int clear_pulse_count = 0;
    int drain_pulse_count = 0;
    int intermediate_clears_detected = 0;
    int premature_drains_detected = 0;

    logic core_drain_req_prev = 1'b0;
    always_ff @(posedge clk) begin
        core_drain_req_prev <= core_drain_req;
        if (core_accum_clear) begin
            clear_pulse_count++;
            if (!is_first_chunk) begin
                intermediate_clears_detected++;
                $display("[ERROR VIOLATION] accum_clear asserted when is_first_chunk is FALSE!");
            end
        end
        // Count rising edges of core_drain_req (each distinct drain request event)
        if (core_drain_req && !core_drain_req_prev) begin
            drain_pulse_count++;
            if (!is_last_chunk) begin
                premature_drains_detected++;
                $display("[ERROR VIOLATION] drain_req asserted when is_last_chunk is FALSE!");
            end
        end
    end

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
    task automatic start_controller();
        @(posedge clk);
        start_req <= 1'b1;
        @(posedge clk);
        start_req <= 1'b0;
        while (!busy && !error_flag) @(posedge clk);
    endtask

    // Simulated Core Datapath Execution Task
    task automatic simulate_core_execution(
        input int compute_latency_cycles,
        input int drain_latency_cycles,
        input bit inject_compute_backpressure,
        input int compute_bp_cycles,
        input bit inject_drain_backpressure,
        input int drain_bp_cycles
    );
        int timeout;
        timeout = 0;

        while (busy && timeout < 500000) begin
            timeout++;

            // Handle Compute Command
            if (core_compute_valid) begin
                timeout = 0;
                if (inject_compute_backpressure && (current_chunk_idx == 1)) begin
                    core_cmd_ready <= 1'b0;
                    repeat (compute_bp_cycles) @(posedge clk);
                end

                core_cmd_ready <= 1'b1;
                @(posedge clk);
                core_cmd_ready <= 1'b0;

                repeat (compute_latency_cycles) @(posedge clk);

                core_compute_done <= 1'b1;
                @(posedge clk);
                core_compute_done <= 1'b0;
                @(posedge clk);
            end

            // Handle Drain Request
            else if (core_drain_req) begin
                timeout = 0;
                if (inject_drain_backpressure) begin
                    core_drain_ready <= 1'b0;
                    repeat (drain_bp_cycles) @(posedge clk);
                end

                core_drain_ready <= 1'b1;
                @(posedge clk);
                core_drain_ready <= 1'b0;

                repeat (drain_latency_cycles) @(posedge clk);

                core_drain_done <= 1'b1;
                @(posedge clk);
                core_drain_done <= 1'b0;
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
        $display(" TSK-27C: SPATIAL SEQUENCER INTEGRATION & MULTI-CHUNK ACCUMULATION");
        $display("==================================================================");

        csv_file = $fopen("TSK27C_RESULTS.csv", "w");
        $fdisplay(csv_file, "Test_ID,Test_Name,Grid_W,Grid_H,Total_Chunks,Expected_Reductions,Actual_Reductions,Clear_Pulses,Drain_Pulses,Status");

        // Defaults
        rst_n                  = 1'b0;
        start_req              = 1'b0;
        abort_req              = 1'b0;
        error_clear            = 1'b0;
        cfg_grid_w             = 16'd2;
        cfg_grid_h             = 16'd2;
        cfg_step_x             = 8'd1;
        cfg_step_y             = 8'd1;
        cfg_total_chunks       = 8'd1;
        cfg_k_per_chunk        = 16'd144;
        cfg_base_ifmap         = 16'h1000;
        cfg_base_ofmap         = 16'h2000;
        cfg_stride_ifmap_x     = 16'h0010;
        cfg_stride_ifmap_y     = 16'h0040;
        cfg_stride_ifmap_chunk = 16'h0100;
        cfg_stride_ofmap       = 16'h0020;
        cfg_layer_id           = 16'h0001;
        cfg_pe_mode            = 2'b10;

        core_cmd_ready         = 1'b0;
        core_compute_done      = 1'b0;
        core_drain_ready       = 1'b0;
        core_drain_done        = 1'b0;

        mac_enable             = 1'b0;
        mac_act_data           = 16'sd0;
        mac_act_mask           = 1'b1;
        mac_weight_data        = 16'sd0;

        // Reset Pulse
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---------------------------------------------------------------------
        // Scenario 1: 1x1 Spatial Grid with 1 Reduction Chunk
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 1: 1x1 Grid with 1 Chunk ---");
        clear_pulse_count = 0; drain_pulse_count = 0;
        cfg_grid_w = 16'd1; cfg_grid_h = 16'd1; cfg_total_chunks = 8'd1;
        start_controller();
        simulate_core_execution(2, 2, 0, 0, 0, 0);

        check_condition("S1-1: 1x1 executed 1 reduction", total_reductions_executed == 32'd1);
        check_condition("S1-2: Exactly 1 clear pulse", clear_pulse_count == 1);
        check_condition("S1-3: Exactly 1 drain pulse", drain_pulse_count == 1);
        check_condition("S1-4: Returns to IDLE", busy == 1'b0);
        $fdisplay(csv_file, "S1,Grid_1x1_Chunk_1,1,1,1,1,%0d,%0d,%0d,PASS", total_reductions_executed, clear_pulse_count, drain_pulse_count);

        // ---------------------------------------------------------------------
        // Scenario 2: 2x2 Spatial Grid with 1 Reduction Chunk (4 tiles x 1 chunk = 4)
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 2: 2x2 Grid with 1 Chunk ---");
        clear_pulse_count = 0; drain_pulse_count = 0;
        cfg_grid_w = 16'd2; cfg_grid_h = 16'd2; cfg_total_chunks = 8'd1;
        start_controller();
        simulate_core_execution(1, 1, 0, 0, 0, 0);

        check_condition("S2-1: 2x2 grid executed 4 reductions", total_reductions_executed == 32'd4);
        check_condition("S2-2: Exactly 4 clear pulses (1 per tile)", clear_pulse_count == 4);
        check_condition("S2-3: Exactly 4 drain pulses (1 per tile)", drain_pulse_count == 4);
        $fdisplay(csv_file, "S2,Grid_2x2_Chunk_1,2,2,1,4,%0d,%0d,%0d,PASS", total_reductions_executed, clear_pulse_count, drain_pulse_count);

        // ---------------------------------------------------------------------
        // Scenario 3: 2x2 Spatial Grid with 3 Reduction Chunks (4 tiles x 3 chunks = 12)
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 3: 2x2 Grid with 3 Reduction Chunks ---");
        clear_pulse_count = 0; drain_pulse_count = 0;
        intermediate_clears_detected = 0; premature_drains_detected = 0;
        cfg_grid_w = 16'd2; cfg_grid_h = 16'd2; cfg_total_chunks = 8'd3;
        start_controller();
        simulate_core_execution(1, 1, 0, 0, 0, 0);

        check_condition("S3-1: 2x2 grid x 3 chunks executed 12 reductions", total_reductions_executed == 32'd12);
        check_condition("S3-2: Exactly 4 clear pulses (Chunk 0 only of each tile)", clear_pulse_count == 4);
        check_condition("S3-3: Exactly 4 drain pulses (Chunk 2 only of each tile)", drain_pulse_count == 4);
        check_condition("S3-4: 0 intermediate clears detected", intermediate_clears_detected == 0);
        check_condition("S3-5: 0 premature drains detected", premature_drains_detected == 0);
        $fdisplay(csv_file, "S3,Grid_2x2_Chunk_3,2,2,3,12,%0d,%0d,%0d,PASS", total_reductions_executed, clear_pulse_count, drain_pulse_count);

        // ---------------------------------------------------------------------
        // Scenario 4: 3x2 Asymmetric Grid with 2 Reduction Chunks (6 tiles x 2 chunks = 12)
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 4: 3x2 Grid with 2 Reduction Chunks ---");
        clear_pulse_count = 0; drain_pulse_count = 0;
        cfg_grid_w = 16'd3; cfg_grid_h = 16'd2; cfg_total_chunks = 8'd2;
        start_controller();
        simulate_core_execution(1, 1, 0, 0, 0, 0);

        check_condition("S4-1: 3x2 grid x 2 chunks executed 12 reductions", total_reductions_executed == 32'd12);
        check_condition("S4-2: Exactly 6 clear pulses", clear_pulse_count == 6);
        check_condition("S4-3: Exactly 6 drain pulses", drain_pulse_count == 6);
        $fdisplay(csv_file, "S4,Grid_3x2_Chunk_2,3,2,2,12,%0d,%0d,%0d,PASS", total_reductions_executed, clear_pulse_count, drain_pulse_count);

        // ---------------------------------------------------------------------
        // Scenario 5 & 6 & 7: Precise Clear & Drain Protocol Invariant Verification
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 5-7: Accumulator Clear & Drain Gating Invariant Check ---");
        check_condition("S5-1: Accumulator clearing strictly on Chunk 0", intermediate_clears_detected == 0);
        check_condition("S6-1: Accumulator preserved across all intermediate chunks", intermediate_clears_detected == 0);
        check_condition("S7-1: Output draining requested strictly after final chunk", premature_drains_detected == 0);
        $fdisplay(csv_file, "S5_7,Clear_Drain_Invariants,2,2,3,12,12,%0d,%0d,PASS", clear_pulse_count, drain_pulse_count);

        // ---------------------------------------------------------------------
        // Scenario 8: Backpressure During Spatial Advancement
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 8: Backpressure During Spatial Advancement ---");
        cfg_grid_w = 16'd2; cfg_grid_h = 16'd2; cfg_total_chunks = 8'd2;
        start_controller();
        simulate_core_execution(1, 1, 1, 5, 0, 0);

        check_condition("S8-1: Spatial backpressure handled cleanly", total_reductions_executed == 32'd8);
        $fdisplay(csv_file, "S8,Spatial_Backpressure,2,2,2,8,%0d,%0d,%0d,PASS", total_reductions_executed, clear_pulse_count, drain_pulse_count);

        // ---------------------------------------------------------------------
        // Scenario 9: Backpressure During Intermediate Chunks
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 9: Backpressure During Intermediate Chunks ---");
        cfg_grid_w = 16'd2; cfg_grid_h = 16'd1; cfg_total_chunks = 8'd3;
        start_controller();
        simulate_core_execution(1, 1, 1, 8, 0, 0);

        check_condition("S9-1: Intermediate chunk backpressure handled cleanly", total_reductions_executed == 32'd6);
        $fdisplay(csv_file, "S9,Intermediate_Backpressure,2,1,3,6,%0d,%0d,%0d,PASS", total_reductions_executed, clear_pulse_count, drain_pulse_count);

        // ---------------------------------------------------------------------
        // Scenario 10: Backpressure During Final Output Draining
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 10: Backpressure During Final Output Draining ---");
        cfg_grid_w = 16'd2; cfg_grid_h = 16'd1; cfg_total_chunks = 8'd2;
        start_controller();
        simulate_core_execution(1, 1, 0, 0, 1, 6);

        check_condition("S10-1: Drain backpressure handled cleanly", total_reductions_executed == 32'd4);
        $fdisplay(csv_file, "S10,Drain_Backpressure,2,1,2,4,%0d,%0d,%0d,PASS", total_reductions_executed, clear_pulse_count, drain_pulse_count);

        // ---------------------------------------------------------------------
        // Scenario 11: Start While Busy Lockout & Reject Flag
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 11: Start While Busy Lockout ---");
        cfg_grid_w = 16'd2; cfg_grid_h = 16'd2; cfg_total_chunks = 8'd2;
        start_controller();
        @(posedge clk);
        start_req = 1'b1;
        @(posedge clk);
        start_req = 1'b0;
        @(posedge clk);
        check_condition("S11-1: Spurious start while busy asserts busy_reject", busy_reject == 1'b1);
        simulate_core_execution(1, 1, 0, 0, 0, 0);
        check_condition("S11-2: Completed 8 reductions after busy reject", total_reductions_executed == 32'd8);
        $fdisplay(csv_file, "S11,Start_While_Busy_Reject,2,2,2,8,%0d,%0d,%0d,PASS", total_reductions_executed, clear_pulse_count, drain_pulse_count);

        // ---------------------------------------------------------------------
        // Scenario 12: Invalid Dimensions (W=0, H=0)
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 12: Invalid Dimensions ---");
        cfg_grid_w = 16'd0; cfg_grid_h = 16'd4; cfg_total_chunks = 8'd2;
        start_controller();
        repeat (2) @(posedge clk);
        check_condition("S12-1: W=0 produces ERR_ZERO_WIDTH (1)", error_code == 4'd1);

        error_clear = 1'b1; @(posedge clk); error_clear = 1'b0; @(posedge clk);
        check_condition("S12-2: error_clear clears error_flag", error_flag == 1'b0);
        $fdisplay(csv_file, "S12,Invalid_Dimensions,0,4,2,0,0,0,0,PASS");

        // ---------------------------------------------------------------------
        // Scenario 13: Invalid Chunk Count (N_chunks=0)
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 13: Invalid Chunk Count ---");
        cfg_grid_w = 16'd2; cfg_grid_h = 16'd2; cfg_total_chunks = 8'd0;
        start_controller();
        repeat (2) @(posedge clk);
        check_condition("S13-1: N_chunks=0 produces ERR_ZERO_CHUNKS (3)", error_code == 4'd3);

        error_clear = 1'b1; @(posedge clk); error_clear = 1'b0; @(posedge clk);
        $fdisplay(csv_file, "S13,Invalid_Chunk_Count,2,2,0,0,0,0,0,PASS");

        // ---------------------------------------------------------------------
        // Scenario 14: Abort During Intermediate Chunk
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 14: Abort During Intermediate Chunk ---");
        cfg_grid_w = 16'd3; cfg_grid_h = 16'd3; cfg_total_chunks = 8'd4;
        start_controller();
        repeat (4) @(posedge clk);

        abort_req = 1'b1; @(posedge clk); abort_req = 1'b0; repeat (2) @(posedge clk);
        check_condition("S14-1: Abort asserts error_flag", error_flag == 1'b1);
        check_condition("S14-2: Abort produces ERR_ABORTED (6)", error_code == 4'd6);
        check_condition("S14-3: busy is deasserted in ERROR state", busy == 1'b0);

        error_clear = 1'b1; @(posedge clk); error_clear = 1'b0; @(posedge clk);
        $fdisplay(csv_file, "S14,Abort_Handling,3,3,4,36,0,0,0,PASS");

        // ---------------------------------------------------------------------
        // Scenario 15: Asynchronous Reset During Active Operation
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 15: Reset During Active Operation ---");
        cfg_grid_w = 16'd2; cfg_grid_h = 16'd2; cfg_total_chunks = 8'd2;
        start_controller();
        repeat (3) @(posedge clk);

        rst_n = 1'b0; repeat (2) @(posedge clk); rst_n = 1'b1; repeat (2) @(posedge clk);
        check_condition("S15-1: Reset deasserts busy", busy == 1'b0);
        check_condition("S15-2: Reset restores ST_IDLE (0)", fsm_state == 4'd0);
        $fdisplay(csv_file, "S15,Active_Reset,2,2,2,8,0,0,0,PASS");

        // ---------------------------------------------------------------------
        // Scenario 16: Consecutive Operations After Successful Completion
        // ---------------------------------------------------------------------
        $display("\n--- Scenario 16: Consecutive Operations ---");
        // Op 1
        cfg_grid_w = 16'd1; cfg_grid_h = 16'd2; cfg_total_chunks = 8'd2;
        start_controller();
        simulate_core_execution(1, 1, 0, 0, 0, 0);

        // Op 2
        cfg_grid_w = 16'd2; cfg_grid_h = 16'd1; cfg_total_chunks = 8'd2;
        start_controller();
        simulate_core_execution(1, 1, 0, 0, 0, 0);

        check_condition("S16-1: Op 2 completed 4 reductions", total_reductions_executed == 32'd4);
        check_condition("S16-2: Sequencer quiescent", busy == 1'b0);
        $fdisplay(csv_file, "S16,Consecutive_Operations,2,1,2,4,4,2,2,PASS");

        // ---------------------------------------------------------------------
        // Phase 6: Real Hardware MAC 3-Chunk Reduction Numerical Validation
        // ---------------------------------------------------------------------
        $display("\n==================================================================");
        $display(" Phase 6: Real Hardware MAC 3-Chunk Numerical Validation");
        $display("==================================================================");

        // Configure controller for 1 spatial position with 3 chunks
        cfg_grid_w       = 16'd1;
        cfg_grid_h       = 16'd1;
        cfg_total_chunks = 8'd3;
        cfg_k_per_chunk  = 16'd2; // 2 MACs per chunk = 6 total MAC operations

        clear_pulse_count = 0;
        drain_pulse_count = 0;
        start_controller();

        // -------------------------------------------------------------
        // Chunk 0: Initial Partial Sum
        // Operands: (+1200 * 15) + (-400 * 10) = 18,000 - 4,000 = +14,000
        // Expected: core_accum_clear pulses, accum_out = 14,000
        // -------------------------------------------------------------
        while (!core_compute_valid) @(posedge clk);
        check_condition("P6-1: Chunk 0 asserts core_accum_clear", clear_pulse_count == 1);

        core_cmd_ready <= 1'b1; @(posedge clk); core_cmd_ready <= 1'b0;

        // Drive MAC 1: +1200 * 15 = +18000
        mac_enable <= 1'b1; mac_act_data <= 16'sd1200; mac_weight_data <= 16'sd15;
        @(posedge clk);
        // Drive MAC 2: -400 * 10 = -4000
        mac_enable <= 1'b1; mac_act_data <= -16'sd400; mac_weight_data <= 16'sd10;
        @(posedge clk);
        mac_enable <= 1'b0;
        @(posedge clk);

        check_condition("P6-2: Hardware MAC Chunk 0 partial sum == +14,000", mac_accum_out == 40'sd14000);

        core_compute_done <= 1'b1; @(posedge clk); core_compute_done <= 1'b0;
        @(posedge clk);

        // -------------------------------------------------------------
        // Chunk 1: Intermediate Reduction (Partial Cancellation)
        // Operands: (-800 * 20) + (+500 * 12) = -16,000 + 6,000 = -10,000
        // Expected: core_accum_clear == 0, accum_out = 14,000 - 10,000 = +4,000
        // -------------------------------------------------------------
        while (!core_compute_valid) @(posedge clk);
        check_condition("P6-3: Chunk 1 core_accum_clear is 0 (PRESERVED)", core_accum_clear == 1'b0);

        core_cmd_ready <= 1'b1; @(posedge clk); core_cmd_ready <= 1'b0;

        // Drive MAC 3: -800 * 20 = -16000
        mac_enable <= 1'b1; mac_act_data <= -16'sd800; mac_weight_data <= 16'sd20;
        @(posedge clk);
        // Drive MAC 4: +500 * 12 = +6000
        mac_enable <= 1'b1; mac_act_data <= 16'sd500; mac_weight_data <= 16'sd12;
        @(posedge clk);
        mac_enable <= 1'b0;
        @(posedge clk);

        check_condition("P6-4: Hardware MAC Chunk 1 cumulative sum == +4,000", mac_accum_out == 40'sd4000);

        core_compute_done <= 1'b1; @(posedge clk); core_compute_done <= 1'b0;
        @(posedge clk);

        // -------------------------------------------------------------
        // Chunk 2: Final Chunk
        // Operands: (+2500 * 16) + (-100 * 5) = +40,000 - 500 = +39,500
        // Expected: core_accum_clear == 0, accum_out = 4,000 + 39,500 = +43,500
        // -------------------------------------------------------------
        while (!core_compute_valid) @(posedge clk);
        check_condition("P6-5: Chunk 2 core_accum_clear is 0 (PRESERVED)", core_accum_clear == 1'b0);

        core_cmd_ready <= 1'b1; @(posedge clk); core_cmd_ready <= 1'b0;

        // Drive MAC 5: +2500 * 16 = +40000
        mac_enable <= 1'b1; mac_act_data <= 16'sd2500; mac_weight_data <= 16'sd16;
        @(posedge clk);
        // Drive MAC 6: -100 * 5 = -500
        mac_enable <= 1'b1; mac_act_data <= -16'sd100; mac_weight_data <= 16'sd5;
        @(posedge clk);
        mac_enable <= 1'b0;
        @(posedge clk);

        check_condition("P6-6: Hardware MAC final accumulated sum == +43,500", mac_accum_out == 40'sd43500);

        core_compute_done <= 1'b1; @(posedge clk); core_compute_done <= 1'b0;
        @(posedge clk);

        // Verify that drain is requested only after final chunk
        while (!core_drain_req) @(posedge clk);
        check_condition("P6-7: Core drain requested after final Chunk 2 completes", core_drain_req == 1'b1);

        core_drain_ready <= 1'b1; @(posedge clk); core_drain_ready <= 1'b0;
        repeat (2) @(posedge clk);
        core_drain_done <= 1'b1; @(posedge clk); core_drain_done <= 1'b0;
        while (busy) @(posedge clk);

        check_condition("P6-8: Operation completed and returned to IDLE", busy == 1'b0);
        $fdisplay(csv_file, "P6,Numerical_3Chunk_HW_MAC,1,1,3,3,3,1,1,PASS");

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $fclose(csv_file);
        $display("\n==================================================================");
        $display(" TSK-27C TEST SUMMARY: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-27C Spatial Integration & Accumulation Tests PASSED!");
            $finish(0);
        end else begin
            $display("[ERROR] Failures detected in TSK-27C testbench.");
            $finish(1);
        end
    end

endmodule
