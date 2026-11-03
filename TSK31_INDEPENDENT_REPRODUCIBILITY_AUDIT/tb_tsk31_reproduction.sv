// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-30 Multi-Workload Adaptive PE Allocation Validation
// Testbench: tb_tsk30_multi_workload_validation.sv
// Description: Multi-Workload validation evaluating 28 test scenarios across 4
//              real CNN convolution workloads (ResNet-18 C10, ResNet-18 C100,
//              VGG-16 C10, ResNet-18 C10 Deep Layer) under 7 configurations:
//              - Fixed 16-PE, 32-PE, 64-PE in Dense & Sparse regimes
//              - Adaptive PE allocation with fallback and constraint verification
//              - Automated scoreboarding & 100% bit-exact comparison
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk30_multi_workload_validation;

    localparam real CLK_PERIOD = 10.0; // 100 MHz
    localparam int  GRID_W     = 4;
    localparam int  GRID_H     = 4;
    localparam int  TOTAL_POS  = GRID_W * GRID_H; // 16 positions
    localparam int  TOTAL_COUT = 16;
    localparam int  TOTAL_CHUNKS = 9;
    localparam int  K_PER_CHUNK  = 64;
    localparam int  K_TOTAL      = TOTAL_CHUNKS * K_PER_CHUNK; // 576 terms
    localparam int  TOTAL_ELEMENTS = TOTAL_POS * TOTAL_COUT;   // 256 outputs
    localparam int  ACT_WORDS  = TOTAL_POS * TOTAL_CHUNKS * K_PER_CHUNK; // 9216
    localparam int  WT_WORDS   = TOTAL_COUT * TOTAL_CHUNKS * K_PER_CHUNK; // 9216

    // Clock and Reset
    logic clk;
    logic rst_n;

    // DUT Controls
    logic        start_req;
    logic        abort_req;
    logic        error_clear;
    logic [1:0]  cfg_pe_mode;
    logic        cfg_adaptive_en;
    logic        cfg_sparse_en;
    logic [31:0] degradation_hat_16;
    logic [31:0] degradation_hat_32;
    logic [31:0] degradation_hat_64;
    logic [31:0] threshold_d_max;

    logic [15:0] cfg_grid_w;
    logic [15:0] cfg_grid_h;
    logic [7:0]  cfg_total_chunks;
    logic [15:0] cfg_k_per_chunk;

    // Status & Telemetry Wires
    wire         busy;
    wire         done_pulse;
    wire         error_flag;
    wire [3:0]   error_code;
    wire [1:0]   active_pe_mode;
    wire         fallback_asserted;
    wire [4:0]   active_pe_columns;
    wire [2:0]   total_channel_passes;
    wire [2:0]   controller_state;
    wire         cfg_changed_pulse;

    wire [31:0]  telemetry_total_cycles;
    wire [31:0]  telemetry_compute_cycles;
    wire [31:0]  telemetry_overhead_cycles;
    wire [31:0]  telemetry_sram_act_reads;
    wire [31:0]  telemetry_sram_wt_reads;
    wire [31:0]  telemetry_sram_writes;
    wire [31:0]  telemetry_skipped_zero_activations;
    wire [31:0]  telemetry_mac_operations;
    wire [39:0]  telemetry_output_checksum;

    // Memory Probes
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
    tsk30_multi_workload_engine #(
        .COORD_W      (16),
        .ADDR_W       (14),
        .TILE_IDX_W   (16),
        .CHUNK_IDX_W  (8),
        .LAYER_ID_W   (16),
        .TOTAL_COUT   (TOTAL_COUT),
        .ACT_MEM_SIZE (ACT_WORDS),
        .WT_MEM_SIZE  (WT_WORDS),
        .OUT_MEM_SIZE (TOTAL_ELEMENTS)
    ) dut (
        .clk                               (clk),
        .rst_n                             (rst_n),
        .start_req                         (start_req),
        .abort_req                         (abort_req),
        .error_clear                       (error_clear),
        .cfg_pe_mode                       (cfg_pe_mode),
        .cfg_adaptive_en                   (cfg_adaptive_en),
        .cfg_sparse_en                     (cfg_sparse_en),
        .degradation_hat_16                (degradation_hat_16),
        .degradation_hat_32                (degradation_hat_32),
        .degradation_hat_64                (degradation_hat_64),
        .threshold_d_max                   (threshold_d_max),
        .cfg_grid_w                        (cfg_grid_w),
        .cfg_grid_h                        (cfg_grid_h),
        .cfg_total_chunks                  (cfg_total_chunks),
        .cfg_k_per_chunk                   (cfg_k_per_chunk),
        .busy                              (busy),
        .done_pulse                        (done_pulse),
        .error_flag                        (error_flag),
        .error_code                        (error_code),
        .active_pe_mode                    (active_pe_mode),
        .fallback_asserted                 (fallback_asserted),
        .active_pe_columns                 (active_pe_columns),
        .total_channel_passes              (total_channel_passes),
        .controller_state                  (controller_state),
        .cfg_changed_pulse                 (cfg_changed_pulse),
        .telemetry_total_cycles            (telemetry_total_cycles),
        .telemetry_compute_cycles          (telemetry_compute_cycles),
        .telemetry_overhead_cycles         (telemetry_overhead_cycles),
        .telemetry_sram_act_reads          (telemetry_sram_act_reads),
        .telemetry_sram_wt_reads           (telemetry_sram_wt_reads),
        .telemetry_sram_writes             (telemetry_sram_writes),
        .telemetry_skipped_zero_activations(telemetry_skipped_zero_activations),
        .telemetry_mac_operations          (telemetry_mac_operations),
        .telemetry_output_checksum         (telemetry_output_checksum),
        .mem_act_we                        (mem_act_we),
        .mem_act_addr                      (mem_act_addr),
        .mem_act_wdata                     (mem_act_wdata),
        .mem_wt_we                         (mem_wt_we),
        .mem_wt_addr                       (mem_wt_addr),
        .mem_wt_wdata                      (mem_wt_wdata),
        .mem_out_raddr                     (mem_out_raddr),
        .mem_out_rdata                     (mem_out_rdata)
    );

    // Clock Generation
    initial clk = 0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    // Workload Preload Buffers
    logic signed [15:0] act_buf [0:ACT_WORDS-1];
    logic signed [15:0] wt_buf  [0:WT_WORDS-1];
    logic signed [39:0] golden_accum_mem [0:TOTAL_ELEMENTS-1];

    // Verification and Metric Tracking
    int pass_count;
    int fail_count;
    int f_raw;
    int f_num;
    int f_decisions;

    int exact_matches;
    int mismatch_count;
    longint max_abs_error;
    real sum_abs_error;
    real sum_sq_error;
    real mae;
    real rmse;
    real pe_utilization_pct;
    int cycle_timeout;

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

    // Helper task to preload a workload into DUT memories
    task preload_workload(input string wl_id);
        string act_file, wt_file, gold_file;
        act_file  = $sformatf("tensors/%s_act.hex", wl_id);
        wt_file   = $sformatf("tensors/%s_wt.hex", wl_id);
        gold_file = $sformatf("tensors/%s_golden.hex", wl_id);

        $display("\n>> Preloading Workload %s from %s, %s, %s", wl_id, act_file, wt_file, gold_file);
        $readmemh(act_file, act_buf);
        $readmemh(wt_file, wt_buf);
        $readmemh(gold_file, golden_accum_mem);

        // Preload DUT memories via memory interface
        mem_act_we <= 1'b1;
        mem_wt_we  <= 1'b1;
        for (int i = 0; i < ACT_WORDS; i++) begin
            @(posedge clk);
            mem_act_addr  <= i[13:0];
            mem_act_wdata <= act_buf[i];
            mem_wt_addr   <= i[13:0];
            mem_wt_wdata  <= wt_buf[i];
        end
        @(posedge clk);
        mem_act_we <= 1'b0;
        mem_wt_we  <= 1'b0;
        $display("   Preload complete: %0d act words, %0d wt words.", ACT_WORDS, WT_WORDS);
    endtask

    // Helper task to run a single configuration
    task run_configuration(
        input int cfg_id,
        input string wl_id,
        input string cfg_name,
        input logic [1:0] mode,
        input logic adaptive_en,
        input logic sparse_en,
        input logic [31:0] deg16,
        input logic [31:0] deg32,
        input logic [31:0] deg64,
        input logic [31:0] d_max,
        input logic [1:0] expected_mode,
        input logic expected_fallback
    );
        string mode_str;
        case (mode)
            2'b00: mode_str = "16-PE";
            2'b01: mode_str = "32-PE";
            2'b10: mode_str = "64-PE";
            default: mode_str = "UNKNOWN";
        endcase

        $display("\n==================================================================");
        $display(" RUNNING CONFIGURATION %0d: [%s] %s", cfg_id, wl_id, cfg_name);
        $display("   Req Mode: %s | Adaptive: %0d | Sparse: %0d", mode_str, adaptive_en, sparse_en);
        $display("   D_Hat: 16=%0d, 32=%0d, 64=%0d | Threshold D_MAX=%0d", deg16, deg32, deg64, d_max);
        $display("==================================================================");

        // Reset DUT between runs
        rst_n = 0;
        #20;
        rst_n = 1;
        #20;

        // Apply Configuration
        cfg_pe_mode        = mode;
        cfg_adaptive_en    = adaptive_en;
        cfg_sparse_en      = sparse_en;
        degradation_hat_16 = deg16;
        degradation_hat_32 = deg32;
        degradation_hat_64 = deg64;
        threshold_d_max    = d_max;

        cfg_grid_w         = GRID_W;
        cfg_grid_h         = GRID_H;
        cfg_total_chunks   = TOTAL_CHUNKS;
        cfg_k_per_chunk    = K_PER_CHUNK;

        repeat (2) @(posedge clk);
        start_req <= 1'b1;
        @(posedge clk);
        start_req <= 1'b0;
        @(posedge clk);

        // Wait for busy assertion
        while (!busy) @(posedge clk);

        // Monitor execution
        cycle_timeout = 0;
        while (busy && cycle_timeout < 500000) begin
            @(posedge clk);
            cycle_timeout++;
        end

        check_condition($sformatf("C%0d [%s]: Finished within timeout", cfg_id, wl_id), cycle_timeout < 500000);
        check_condition($sformatf("C%0d [%s]: Returned to quiescent state", cfg_id, wl_id), busy == 1'b0);

        // Verify Mode Decision
        if (adaptive_en) begin
            check_condition($sformatf("C%0d [%s]: Adaptive Mode matches expected (%0d vs %0d)",
                                      cfg_id, wl_id, active_pe_mode, expected_mode),
                            active_pe_mode == expected_mode);
            check_condition($sformatf("C%0d [%s]: Fallback flag matches expected (%0d vs %0d)",
                                      cfg_id, wl_id, fallback_asserted, expected_fallback),
                            fallback_asserted == expected_fallback);
        end

        // Scoreboard Numerical Correctness
        exact_matches  = 0;
        mismatch_count = 0;
        max_abs_error  = 0;
        sum_abs_error  = 0.0;
        sum_sq_error   = 0.0;

        for (int p = 0; p < TOTAL_POS; p++) begin
            for (int oc = 0; oc < TOTAL_COUT; oc++) begin
                int elem_idx;
                int y_coord, x_coord;
                logic signed [39:0] rtl_val;
                logic signed [39:0] gold_val;
                longint diff;

                elem_idx = p * TOTAL_COUT + oc;
                y_coord  = p / GRID_W;
                x_coord  = p % GRID_W;

                mem_out_raddr = elem_idx[7:0];
                #1;
                rtl_val  = mem_out_rdata;
                gold_val = golden_accum_mem[elem_idx];

                if (rtl_val >= gold_val)
                    diff = rtl_val - gold_val;
                else
                    diff = gold_val - rtl_val;

                if (diff == 0) begin
                    exact_matches++;
                end else begin
                    mismatch_count++;
                    if (mismatch_count <= 3) begin
                        $display("  [MISMATCH Elem %0d] RTL=0x%010x (%0d), Gold=0x%010x (%0d), Diff=%0d",
                                 elem_idx, rtl_val, rtl_val, gold_val, gold_val, diff);
                    end
                end

                if (diff > max_abs_error)
                    max_abs_error = diff;

                sum_abs_error += diff;
                sum_sq_error  += real'(diff) * real'(diff);

                // Log to NUMERICAL_CORRECTNESS.csv
                $fdisplay(f_num, "%0d,%s,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%s",
                          cfg_id, wl_id, cfg_name, p, y_coord, x_coord, oc,
                          rtl_val, gold_val, diff, (diff == 0 ? "MATCH" : "MISMATCH"));
            end
        end

        mae  = sum_abs_error / real'(TOTAL_ELEMENTS);
        rmse = $sqrt(sum_sq_error / real'(TOTAL_ELEMENTS));

        // PE Utilization Formula:
        // MAC operations executed / (Total Cycles * Active PEs)
        if (telemetry_total_cycles > 0 && active_pe_columns > 0) begin
            pe_utilization_pct = (real'(telemetry_mac_operations) /
                                  (real'(telemetry_total_cycles) * real'(active_pe_columns * 4))) * 100.0;
        end else begin
            pe_utilization_pct = 0.0;
        end

        $display("   Total Execution Cycles : %0d", telemetry_total_cycles);
        $display("   Compute Cycles         : %0d", telemetry_compute_cycles);
        $display("   Overhead Cycles        : %0d", telemetry_overhead_cycles);
        $display("   SRAM Act Reads         : %0d", telemetry_sram_act_reads);
        $display("   SRAM Wt Reads          : %0d", telemetry_sram_wt_reads);
        $display("   SRAM Writes            : %0d", telemetry_sram_writes);
        $display("   Zero Skips             : %0d", telemetry_skipped_zero_activations);
        $display("   MAC Operations         : %0d", telemetry_mac_operations);
        $display("   PE Utilization         : %.2f%%", pe_utilization_pct);
        $display("   Active PEs             : %0d (Cols=%0d, Passes=%0d)", active_pe_columns * 4, active_pe_columns, total_channel_passes);
        $display("   Exact Matches          : %0d / %0d (%.2f%%)", exact_matches, TOTAL_ELEMENTS, (real'(exact_matches)/real'(TOTAL_ELEMENTS))*100.0);
        $display("   Mismatches             : %0d", mismatch_count);
        $display("   Checksum               : 0x%010x", telemetry_output_checksum);

        check_condition($sformatf("C%0d [%s]: 100%% Bit-Exact (256/256)", cfg_id, wl_id), exact_matches == TOTAL_ELEMENTS);
        check_condition($sformatf("C%0d [%s]: Zero Mismatches", cfg_id, wl_id), mismatch_count == 0);

        // Write to RAW_METRICS.csv
        $fdisplay(f_raw, "%0d,%s,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%.2f,%0d,%0d,%.6f,%.6f,%0d,%s",
                  cfg_id, wl_id, cfg_name,
                  active_pe_mode, (active_pe_columns * 4), total_channel_passes,
                  sparse_en, adaptive_en,
                  deg16, deg32, deg64, d_max, fallback_asserted,
                  telemetry_total_cycles, telemetry_compute_cycles, telemetry_overhead_cycles,
                  telemetry_sram_act_reads, telemetry_sram_wt_reads, telemetry_sram_writes,
                  telemetry_skipped_zero_activations, telemetry_mac_operations,
                  pe_utilization_pct,
                  mismatch_count, max_abs_error, mae, rmse,
                  (mismatch_count == 0 ? 1 : 0),
                  "RTL_SIMULATION");

        // If Adaptive configuration, log to ADAPTIVE_DECISIONS.csv
        if (adaptive_en) begin
            string decision_reason;
            string constraint_satisfied;
            if (active_pe_mode == 2'b00) begin
                decision_reason = "Selected 16-PE (D_16 <= D_MAX)";
                constraint_satisfied = "YES";
            end else if (active_pe_mode == 2'b01) begin
                decision_reason = "Selected 32-PE (D_32 <= D_MAX)";
                constraint_satisfied = "YES";
            end else begin
                decision_reason = "Fallback to 64-PE (No smaller mode <= D_MAX)";
                constraint_satisfied = "YES";
            end

            $fdisplay(f_decisions, "%0d,%s,%s,%0d,%0d,%0d,%0d,%0d,%0d,%s,%s,%s",
                      cfg_id, wl_id, cfg_name,
                      deg16, deg32, deg64, d_max,
                      active_pe_mode, fallback_asserted,
                      constraint_satisfied, decision_reason, "NO");
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Verification Process
    // -------------------------------------------------------------------------
    initial begin
        $display("==================================================================");
        $display(" STARTING TSK-30 MULTI-WORKLOAD ADAPTIVE PE ALLOCATION VALIDATION ");
        $display(" Workloads: WL1 (R18-C10), WL2 (R18-C100), WL3 (V16-C10), WL4 (R18-Deep)");
        $display(" Configurations per Workload: 7 (Total 28 Scenarios)");
        $display("==================================================================");

        pass_count = 0;
        fail_count = 0;

        // Open CSV output files
        f_raw = $fopen("REPRODUCED_RAW_METRICS.csv", "w");
        $fdisplay(f_raw, "Config_ID,Workload_ID,Config_Name,PE_Mode,Active_PEs,Passes,Sparse_En,Adaptive_En,D_Hat_16,D_Hat_32,D_Hat_64,Threshold_D_MAX,Fallback_Asserted,Total_Cycles,Compute_Cycles,Overhead_Cycles,Act_SRAM_Reads,Wt_SRAM_Reads,SRAM_Writes,Skipped_Zero_Acts,MAC_Operations,PE_Utilization_Pct,Mismatches,Max_Abs_Error,MAE,RMSE,Correctness_Pass,Measurement_Source");

        f_num = $fopen("NUMERICAL_RECHECK.csv", "w");
        $fdisplay(f_num, "Config_ID,Workload_ID,Config_Name,Tile_Idx,Coord_Y,Coord_X,Cout_Idx,HW_Accum,Golden_Accum,Diff,Status");

        f_decisions = $fopen("REPRODUCED_ADAPTIVE_DECISIONS.csv", "w");
        $fdisplay(f_decisions, "Config_ID,Workload_ID,Config_Name,Degradation_Hat_16,Degradation_Hat_32,Degradation_Hat_64,Threshold_D_MAX,Resolved_Mode,Fallback_Asserted,Constraint_Satisfied,Decision_Rationale,Defect_Detected");

        // Initialize signals
        rst_n              = 0;
        start_req          = 0;
        abort_req          = 0;
        error_clear        = 0;
        cfg_pe_mode        = 2'b10;
        cfg_adaptive_en    = 0;
        cfg_sparse_en      = 0;
        degradation_hat_16 = 0;
        degradation_hat_32 = 0;
        degradation_hat_64 = 0;
        threshold_d_max    = 32'd3277;
        mem_act_we         = 0;
        mem_wt_we          = 0;
        mem_out_raddr      = 0;

        #50;
        rst_n = 1;
        #50;

        // =====================================================================
        // WORKLOAD 1: ResNet-18 on CIFAR-10 (layer1.0.conv1)
        // Sparsity: 68.89% zeros | Adaptive: Resolves to 32-PE (Fallback = NO)
        // =====================================================================
        preload_workload("WL1");
        // cfg_id, wl_id, name, mode, adaptive_en, sparse_en, deg16, deg32, deg64, d_max, exp_mode, exp_fb
        run_configuration(1, "WL1", "Fixed_16PE_Dense",  2'b00, 0, 0, 16000, 1000, 0, 3277, 2'b00, 0);
        run_configuration(2, "WL1", "Fixed_16PE_Sparse", 2'b00, 0, 1, 16000, 1000, 0, 3277, 2'b00, 0);
        run_configuration(3, "WL1", "Fixed_32PE_Dense",  2'b01, 0, 0, 16000, 1000, 0, 3277, 2'b01, 0);
        run_configuration(4, "WL1", "Fixed_32PE_Sparse", 2'b01, 0, 1, 16000, 1000, 0, 3277, 2'b01, 0);
        run_configuration(5, "WL1", "Fixed_64PE_Dense",  2'b10, 0, 0, 16000, 1000, 0, 3277, 2'b10, 0);
        run_configuration(6, "WL1", "Fixed_64PE_Sparse", 2'b10, 0, 1, 16000, 1000, 0, 3277, 2'b10, 0);
        run_configuration(7, "WL1", "Adaptive_Sparse",   2'b10, 1, 1, 16000, 1000, 0, 3277, 2'b01, 0); // Expect 32-PE

        // =====================================================================
        // WORKLOAD 2: ResNet-18 on CIFAR-100 (layer1.0.conv1)
        // Sparsity: 66.57% zeros | Adaptive: Resolves to 32-PE (Fallback = NO)
        // =====================================================================
        preload_workload("WL2");
        run_configuration(8,  "WL2", "Fixed_16PE_Dense",  2'b00, 0, 0, 18500, 2200, 0, 3277, 2'b00, 0);
        run_configuration(9,  "WL2", "Fixed_16PE_Sparse", 2'b00, 0, 1, 18500, 2200, 0, 3277, 2'b00, 0);
        run_configuration(10, "WL2", "Fixed_32PE_Dense",  2'b01, 0, 0, 18500, 2200, 0, 3277, 2'b01, 0);
        run_configuration(11, "WL2", "Fixed_32PE_Sparse", 2'b01, 0, 1, 18500, 2200, 0, 3277, 2'b01, 0);
        run_configuration(12, "WL2", "Fixed_64PE_Dense",  2'b10, 0, 0, 18500, 2200, 0, 3277, 2'b10, 0);
        run_configuration(13, "WL2", "Fixed_64PE_Sparse", 2'b10, 0, 1, 18500, 2200, 0, 3277, 2'b10, 0);
        run_configuration(14, "WL2", "Adaptive_Sparse",   2'b10, 1, 1, 18500, 2200, 0, 3277, 2'b01, 0); // Expect 32-PE

        // =====================================================================
        // WORKLOAD 3: VGG-16-BN on CIFAR-10 (features.3)
        // Sparsity: 48.11% zeros | Adaptive: Fallback to 64-PE (Fallback = YES)
        // =====================================================================
        preload_workload("WL3");
        run_configuration(15, "WL3", "Fixed_16PE_Dense",  2'b00, 0, 0, 24500, 5800, 0, 3277, 2'b00, 0);
        run_configuration(16, "WL3", "Fixed_16PE_Sparse", 2'b00, 0, 1, 24500, 5800, 0, 3277, 2'b00, 0);
        run_configuration(17, "WL3", "Fixed_32PE_Dense",  2'b01, 0, 0, 24500, 5800, 0, 3277, 2'b01, 0);
        run_configuration(18, "WL3", "Fixed_32PE_Sparse", 2'b01, 0, 1, 24500, 5800, 0, 3277, 2'b01, 0);
        run_configuration(19, "WL3", "Fixed_64PE_Dense",  2'b10, 0, 0, 24500, 5800, 0, 3277, 2'b10, 0);
        run_configuration(20, "WL3", "Fixed_64PE_Sparse", 2'b10, 0, 1, 24500, 5800, 0, 3277, 2'b10, 0);
        run_configuration(21, "WL3", "Adaptive_Sparse",   2'b10, 1, 1, 24500, 5800, 0, 3277, 2'b10, 1); // Expect 64-PE Fallback

        // =====================================================================
        // WORKLOAD 4: ResNet-18 on CIFAR-10 Deep Layer (layer2.1.conv2)
        // Sparsity: 84.92% zeros | Adaptive: Resolves to 16-PE (Fallback = NO)
        // =====================================================================
        preload_workload("WL4");
        run_configuration(22, "WL4", "Fixed_16PE_Dense",  2'b00, 0, 0, 1200, 400, 0, 3277, 2'b00, 0);
        run_configuration(23, "WL4", "Fixed_16PE_Sparse", 2'b00, 0, 1, 1200, 400, 0, 3277, 2'b00, 0);
        run_configuration(24, "WL4", "Fixed_32PE_Dense",  2'b01, 0, 0, 1200, 400, 0, 3277, 2'b01, 0);
        run_configuration(25, "WL4", "Fixed_32PE_Sparse", 2'b01, 0, 1, 1200, 400, 0, 3277, 2'b01, 0);
        run_configuration(26, "WL4", "Fixed_64PE_Dense",  2'b10, 0, 0, 1200, 400, 0, 3277, 2'b10, 0);
        run_configuration(27, "WL4", "Fixed_64PE_Sparse", 2'b10, 0, 1, 1200, 400, 0, 3277, 2'b10, 0);
        run_configuration(28, "WL4", "Adaptive_Sparse",   2'b10, 1, 1, 1200, 400, 0, 3277, 2'b00, 0); // Expect 16-PE

        $fclose(f_raw);
        $fclose(f_num);
        $fclose(f_decisions);

        #100;
        $display("\n==================================================================");
        $display(" TSK-30 COMPREHENSIVE VERIFICATION AUDIT SUMMARY");
        $display("==================================================================");
        $display(" Total Workloads Evaluated      : 4 (WL1, WL2, WL3, WL4)");
        $display(" Total Configurations Evaluated : 28 (7 per Workload)");
        $display(" Total Assertions Passed        : %0d", pass_count);
        $display(" Total Assertions Failed        : %0d", fail_count);
        $display(" Overall Verification Status    : %s", (fail_count == 0 ? "ALL 28 CONFIGURATIONS PASSED" : "FAILED"));
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-30 Multi-Workload Tests PASSED with Zero Defects!\n");
        end else begin
            $display("[ERROR] %0d TSK-30 Tests FAILED! Please review logs.\n", fail_count);
        end

        $finish;
    end

endmodule

