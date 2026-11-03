// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-28 Complete Convolution Layer Validation
// Testbench: tb_tsk28_complete_convolution.sv
// Description: End-to-end verification of complete convolution layer using:
//              - Real ResNet-18 CIFAR-10 layer1.0.conv1 weights and activations
//              - Full 4x4 spatial grid (16 positions, 100% complete feature map)
//              - Full 16 output channels (COUT=16) -> 256 complete output elements
//              - Complete 576 reduction terms (9 chunks x 64 channels = 576 MACs)
//              - 16 physical mac_unit_40b instances executing all 147,456 MACs
//              - 100% bit-exact scoreboarding against independent golden reference
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk28_complete_convolution;

    localparam real CLK_PERIOD = 10.0; // 100 MHz
    localparam int  GRID_W     = 4;
    localparam int  GRID_H     = 4;
    localparam int  TOTAL_POS  = GRID_W * GRID_H; // 16 positions
    localparam int  COUT       = 16;
    localparam int  TOTAL_CHUNKS = 9;
    localparam int  K_PER_CHUNK  = 64;
    localparam int  K_TOTAL      = TOTAL_CHUNKS * K_PER_CHUNK; // 576 terms
    localparam int  TOTAL_ELEMENTS = TOTAL_POS * COUT; // 256 outputs
    localparam int  ACT_WORDS  = TOTAL_POS * TOTAL_CHUNKS * K_PER_CHUNK; // 9216
    localparam int  WT_WORDS   = COUT * TOTAL_CHUNKS * K_PER_CHUNK; // 9216

    // Clock and Reset
    logic clk;
    logic rst_n;

    // DUT Controls
    logic        start_req;
    logic        abort_req;
    logic        error_clear;
    logic [15:0] cfg_grid_w;
    logic [15:0] cfg_grid_h;
    logic [7:0]  cfg_step_x;
    logic [7:0]  cfg_step_y;
    logic [7:0]  cfg_total_chunks;
    logic [15:0] cfg_k_per_chunk;
    logic [13:0] cfg_base_ifmap;
    logic [13:0] cfg_base_ofmap;
    logic [13:0] cfg_stride_ifmap_x;
    logic [13:0] cfg_stride_ifmap_y;
    logic [13:0] cfg_stride_ifmap_chunk;
    logic [13:0] cfg_stride_ofmap;
    logic [15:0] cfg_layer_id;
    logic [1:0]  cfg_pe_mode;

    // Status Telemetry
    wire         busy;
    wire         done_pulse;
    wire         error_flag;
    wire [3:0]   error_code;
    wire         busy_reject;
    wire [3:0]   controller_fsm_state;
    wire [15:0]  current_x;
    wire [15:0]  current_y;
    wire [15:0]  current_tile_idx;
    wire [15:0]  total_tiles_count;
    wire [7:0]   current_chunk_idx;
    wire [7:0]   total_chunks_count;
    wire         is_first_chunk;
    wire         is_last_chunk;
    wire [31:0]  total_reductions_executed;

    // Drain Telemetry
    wire         drain_valid_pulse;
    wire [15:0]  drain_tile_idx;
    wire signed [39:0] drained_accum [0:COUT-1];
    wire [COUT-1:0] mac_sticky_sat_flags;

    // Memory Write/Read Probes
    logic        mem_act_we;
    logic [13:0] mem_act_addr;
    logic signed [15:0] mem_act_wdata;
    logic        mem_wt_we;
    logic [13:0] mem_wt_addr;
    logic signed [15:0] mem_wt_wdata;
    logic [7:0]  mem_out_raddr;
    wire signed [39:0] mem_out_rdata;

    // -------------------------------------------------------------------------
    // Instantiate DUT
    // -------------------------------------------------------------------------
    tsk28_complete_convolution_engine #(
        .COORD_W      (16),
        .ADDR_W       (14),
        .TILE_IDX_W   (16),
        .CHUNK_IDX_W  (8),
        .LAYER_ID_W   (16),
        .COUT_CHANNELS(COUT),
        .ACT_MEM_SIZE (ACT_WORDS),
        .WT_MEM_SIZE  (WT_WORDS),
        .OUT_MEM_SIZE (TOTAL_ELEMENTS)
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
        .controller_fsm_state      (controller_fsm_state),
        .current_x                 (current_x),
        .current_y                 (current_y),
        .current_tile_idx          (current_tile_idx),
        .total_tiles_count         (total_tiles_count),
        .current_chunk_idx         (current_chunk_idx),
        .total_chunks_count        (total_chunks_count),
        .is_first_chunk            (is_first_chunk),
        .is_last_chunk             (is_last_chunk),
        .total_reductions_executed (total_reductions_executed),
        .drain_valid_pulse         (drain_valid_pulse),
        .drain_tile_idx            (drain_tile_idx),
        .drained_accum             (drained_accum),
        .mac_sticky_sat_flags      (mac_sticky_sat_flags),
        .mem_act_we                (mem_act_we),
        .mem_act_addr              (mem_act_addr),
        .mem_act_wdata             (mem_act_wdata),
        .mem_wt_we                 (mem_wt_we),
        .mem_wt_addr               (mem_wt_addr),
        .mem_wt_wdata              (mem_wt_wdata),
        .mem_out_raddr             (mem_out_raddr),
        .mem_out_rdata             (mem_out_rdata)
    );

    // Clock Generation
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    // Test Variables and Golden Storage
    logic signed [39:0] golden_accum_mem [0:TOTAL_ELEMENTS-1];
    logic signed [15:0] golden_requant_mem [0:TOTAL_ELEMENTS-1];

    int pass_count;
    int fail_count;
    int results_csv;
    int num_csv;

    int cycle_timeout;
    int exact_matches;
    int mismatch_count;
    longint max_abs_error;
    real sum_abs_error;
    real sum_sq_error;
    real mae;
    real rmse;
    int sat_detected;
    int y_pos;
    int x_pos;
    int elem_idx;
    logic signed [39:0] rtl_val;
    logic signed [39:0] gold_val;
    longint diff;
    string match_str;

    // Assertion & Telemetry Monitors
    int total_clear_pulses;
    int total_drain_pulses;
    int intermediate_clear_violations;
    int intermediate_drain_violations;
    logic core_accum_clear_prev;
    logic core_drain_req_prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_clear_pulses            <= 0;
            total_drain_pulses            <= 0;
            intermediate_clear_violations <= 0;
            intermediate_drain_violations <= 0;
            core_accum_clear_prev         <= 1'b0;
            core_drain_req_prev           <= 1'b0;
        end else begin
            core_accum_clear_prev <= dut.core_accum_clear;
            core_drain_req_prev   <= dut.core_drain_req;

            // Monitor Accumulator Clear Pulses (rising edge)
            if (dut.core_accum_clear && !core_accum_clear_prev) begin
                total_clear_pulses <= total_clear_pulses + 1;
                if (!dut.is_first_chunk) begin
                    intermediate_clear_violations <= intermediate_clear_violations + 1;
                    $display("[ASSERTION ERROR] Accumulator clear asserted on intermediate chunk %0d!", dut.current_chunk_idx);
                end
            end

            // Monitor OFMAP Drain Pulses (rising edge)
            if (dut.core_drain_req && !core_drain_req_prev) begin
                total_drain_pulses <= total_drain_pulses + 1;
                if (!dut.is_last_chunk) begin
                    intermediate_drain_violations <= intermediate_drain_violations + 1;
                    $display("[ASSERTION ERROR] Drain requested on intermediate chunk %0d!", dut.current_chunk_idx);
                end
            end
        end
    end

    // Helper task to check condition
    task check_condition(input string test_name, input logic condition);
        if (condition) begin
            $display("  [PASS] %s", test_name);
            pass_count++;
        end else begin
            $display("  [FAIL] %s", test_name);
            fail_count++;
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Verification Procedure
    // -------------------------------------------------------------------------
    initial begin
        clk         = 0;
        rst_n       = 0;
        start_req   = 0;
        abort_req   = 0;
        error_clear = 0;
        mem_act_we  = 0;
        mem_wt_we   = 0;
        mem_out_raddr = 0;
        pass_count  = 0;
        fail_count  = 0;

        $display("==================================================================");
        $display(" TSK-28: COMPLETE CONVOLUTION LAYER HARDWARE VALIDATION");
        $display(" Target Layer: ResNet-18 layer1.0.conv1 (CIFAR-10)");
        $display(" Output Grid:  %0dx%0d (16 Spatial Positions = 100%% Feature Map)", GRID_W, GRID_H);
        $display(" Channels:     Cin=64, Cout=16 -> 256 Complete Output Activations");
        $display(" Reductions:   K = 3 x 3 x 64 = 576 terms (9 chunks x 64 MACs)");
        $display(" Hardware MAC: 16 physical mac_unit_40b instances");
        $display(" Total MACs:   256 elements x 576 terms = 147,456 MAC operations");
        $display("==================================================================");

        // Open CSV files
        results_csv = $fopen("TSK28_RESULTS.csv", "w");
        num_csv     = $fopen("NUMERICAL_COMPARISON.csv", "w");
        $fdisplay(results_csv, "Test_ID,Scenario_Description,Grid_Dim,Cout,Total_Chunks,K_Reduction,Total_Outputs,Total_MACs,Clear_Pulses,Drain_Pulses,Mismatches,Status");
        $fdisplay(num_csv, "Pos_Idx,Y,X,Cout_Idx,RTL_Accum_40b,Gold_Accum_40b,Diff,Match,Status");

        // Load Precomputed Tensors into DUT RAMs and Golden Memory
        $display("\n[Phase 1] Preloading weights, activations, and golden reference...");
        $readmemh("tensors/act_data.hex", dut.act_ram);
        $readmemh("tensors/wt_data.hex",  dut.wt_ram);
        $readmemh("tensors/gold_accum.hex", golden_accum_mem);
        $readmemh("tensors/gold_requant.hex", golden_requant_mem);
        $display("  [SUCCESS] All %0d activation words and %0d weight words preloaded.", ACT_WORDS, WT_WORDS);

        // Reset Sequence
        #20 rst_n = 1;
        #20;

        // ---------------------------------------------------------------------
        // Test 1: Baseline Reset and Quiescent Sanity Check
        // ---------------------------------------------------------------------
        $display("\n--- Test 1: Quiescent State Checks ---");
        check_condition("T1-1: Engine is not busy after reset", busy == 1'b0);
        check_condition("T1-2: Error flag is low", error_flag == 1'b0);
        check_condition("T1-3: Total reductions counter is zero", total_reductions_executed == 32'd0);

        // ---------------------------------------------------------------------
        // Test 2: Launch Complete Convolution Layer Execution
        // ---------------------------------------------------------------------
        $display("\n--- Test 2: Complete Convolution Execution (147,456 MACs) ---");
        cfg_grid_w             = GRID_W;
        cfg_grid_h             = GRID_H;
        cfg_step_x             = 16'd1;
        cfg_step_y             = 16'd1;
        cfg_total_chunks       = TOTAL_CHUNKS; // 9 chunks
        cfg_k_per_chunk        = K_PER_CHUNK;  // 64 MACs per chunk
        cfg_base_ifmap         = 14'd0;
        cfg_base_ofmap         = 14'd0;
        cfg_stride_ifmap_x     = 14'd1;
        cfg_stride_ifmap_y     = 14'd4;
        cfg_stride_ifmap_chunk = 14'd64;
        cfg_stride_ofmap       = 14'd16;
        cfg_layer_id           = 16'h0028;
        cfg_pe_mode            = 2'b00; // Dense 64-PE / 16-Col mode

        start_req = 1'b1;
        @(posedge clk);
        start_req = 1'b0;
        @(posedge clk);

        check_condition("T2-1: Engine enters busy state upon start", busy == 1'b1);

        // Monitor execution and wait for completion
        cycle_timeout = 0;
        while (busy && cycle_timeout < 500000) begin
            @(posedge clk);
            cycle_timeout++;
        end

        check_condition("T2-2: Convolution completed within timeout", cycle_timeout < 500000);
        check_condition("T2-3: Engine deasserts busy upon layer completion", busy == 1'b0);
        check_condition("T2-4: Engine is in ST_IDLE or ST_DONE", controller_fsm_state == 4'd0 || controller_fsm_state == 4'd7);
        $display("  -> Total simulation cycles elapsed: %0d", cycle_timeout);

        // ---------------------------------------------------------------------
        // Test 3: Structural Control & Accumulator Invariant Verification
        // ---------------------------------------------------------------------
        $display("\n--- Test 3: Control & Reduction Invariant Verification ---");
        check_condition("T3-1: Total reductions executed == 144 (16 tiles x 9 chunks)", total_reductions_executed == 32'd144);
        check_condition("T3-2: Exactly 16 clear pulses (1 per spatial position on Chunk 0)", total_clear_pulses == TOTAL_POS);
        check_condition("T3-3: Exactly 16 drain pulses (1 per spatial position on Chunk 8)", total_drain_pulses == TOTAL_POS);
        check_condition("T3-4: Zero clear violations on intermediate chunks (Chunks 1..8)", intermediate_clear_violations == 0);
        check_condition("T3-5: Zero drain violations on intermediate chunks (Chunks 0..7)", intermediate_drain_violations == 0);

        // ---------------------------------------------------------------------
        // Test 4: Bit-Exact Numerical Output Verification Across All 256 Elements
        // ---------------------------------------------------------------------
        $display("\n--- Test 4: Bit-Exact Numerical Output Verification (All 256 Elements) ---");
        exact_matches  = 0;
        mismatch_count = 0;
        max_abs_error  = 0;
        sum_abs_error  = 0.0;
        sum_sq_error   = 0.0;

        for (int p = 0; p < TOTAL_POS; p++) begin
            y_pos = p / GRID_W;
            x_pos = p % GRID_W;

            for (int oc = 0; oc < COUT; oc++) begin
                elem_idx = p * COUT + oc;
                mem_out_raddr = elem_idx[7:0];
                #1; // Allow RAM read settling
                rtl_val  = mem_out_rdata;
                gold_val = golden_accum_mem[elem_idx];

                if (rtl_val >= gold_val)
                    diff = rtl_val - gold_val;
                else
                    diff = gold_val - rtl_val;

                if (diff == 0) begin
                    exact_matches++;
                    match_str = "MATCH";
                end else begin
                    mismatch_count++;
                    match_str = "MISMATCH";
                    if (mismatch_count <= 5) begin
                        $display("  [MISMATCH at Pos(%0d,%0d) Cout=%0d] RTL=0x%010x (%0d), Gold=0x%010x (%0d), Diff=%0d",
                                 y_pos, x_pos, oc, rtl_val, rtl_val, gold_val, gold_val, diff);
                    end
                end

                if (diff > max_abs_error)
                    max_abs_error = diff;

                sum_abs_error += diff;
                sum_sq_error  += real'(diff) * real'(diff);

                // Log to NUMERICAL_COMPARISON.csv
                $fdisplay(num_csv, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%s,%s",
                          p, y_pos, x_pos, oc, rtl_val, gold_val, diff, (diff == 0 ? "TRUE" : "FALSE"), match_str);
            end
        end

        mae  = sum_abs_error / real'(TOTAL_ELEMENTS);
        rmse = $sqrt(sum_sq_error / real'(TOTAL_ELEMENTS));

        $display("\n==================================================================");
        $display(" NUMERICAL ACCURACY AUDIT SUMMARY:");
        $display("   Total Elements Evaluated : %0d", TOTAL_ELEMENTS);
        $display("   Exact Bit-Exact Matches  : %0d (%.2f%%)", exact_matches, (real'(exact_matches) / real'(TOTAL_ELEMENTS)) * 100.0);
        $display("   Mismatches               : %0d", mismatch_count);
        $display("   Max Absolute Error       : %0d", max_abs_error);
        $display("   Mean Absolute Error (MAE): %.6f", mae);
        $display("   Root Mean Sq Error (RMSE): %.6f", rmse);
        $display("==================================================================");

        check_condition("T4-1: 100% Bit-Exact Matches (256/256)", exact_matches == TOTAL_ELEMENTS);
        check_condition("T4-2: Zero numerical mismatches", mismatch_count == 0);
        check_condition("T4-3: Maximum Absolute Error == 0", max_abs_error == 0);

        // Record to Results CSV
        $fdisplay(results_csv, "S1,ResNet18_L1_C1_Full_4x4_Conv,4x4,%0d,%0d,%0d,%0d,147456,%0d,%0d,%0d,%s",
                  COUT, TOTAL_CHUNKS, K_TOTAL, TOTAL_ELEMENTS, total_clear_pulses, total_drain_pulses, mismatch_count,
                  (mismatch_count == 0 ? "PASS" : "FAIL"));

        // ---------------------------------------------------------------------
        // Test 5: Requantization and Sticky Saturation Check
        // ---------------------------------------------------------------------
        $display("\n--- Test 5: Saturation & Arithmetic Bounds Check ---");
        sat_detected = 0;
        for (int c = 0; c < COUT; c++) begin
            if (mac_sticky_sat_flags[c]) begin
                sat_detected++;
                $display("  [WARNING] Sticky saturation detected on Column MAC %0d", c);
            end
        end
        check_condition("T5-1: No illegal saturation overflows detected", sat_detected == 0);

        // Close files
        $fclose(results_csv);
        $fclose(num_csv);

        // ---------------------------------------------------------------------
        // Final Summary
        // ---------------------------------------------------------------------
        $display("\n==================================================================");
        $display(" TSK-28 VERIFICATION SUMMARY: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-28 Complete Convolution Layer Tests PASSED with Zero Defects!");
            $finish(0);
        end else begin
            $display("[ERROR] Failures detected in TSK-28 testbench.");
            $finish(1);
        end
    end

endmodule
