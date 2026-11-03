// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Verification)
// Module: tb_pe_array_40b.sv
// Description: Comprehensive Self-Checking Testbench for Multi-PE Array (pe_array_40b)
// Tests:
//   1. Reset Behavior (Asynchronous rst_n assertion & clear)
//   2. Mode 0: Exactly 16 Active PEs (Cols 0..3 active, Cols 4..15 clamped)
//   3. Mode 1: Exactly 32 Active PEs (Cols 0..7 active, Cols 8..15 clamped)
//   4. Mode 2: Exactly 64 Active PEs (Cols 0..15 all active)
//   5. Multi-cycle Accumulation Correctness against Reference Model
//   6. Exact-Zero Activation Bypass (act_mask=0 and act_data=0)
//   7. Positive and Negative Saturation Clamping with Sticky Flags
//   8. Inactive PE Isolation & Zero-Leaking Prevention
//   9. Dynamic Configuration Switching Between Modes
//  10. Reset Mid-Compute and Inter-Compute Behavior
//  11. Invalid Configuration (2'b11) Safe Handling & Quiescence
//  12. Activation Row-Broadcast Mode
// =============================================================================

`timescale 1ns / 1ps

module tb_pe_array_40b;

    localparam int CLK_PERIOD   = 10;
    localparam int ROWS         = 4;
    localparam int COLS         = 16;
    localparam int ACT_WIDTH    = 16;
    localparam int WEIGHT_WIDTH = 16;
    localparam int ACCUM_WIDTH  = 40;

    localparam logic signed [ACCUM_WIDTH-1:0] SAT_MAX_POS = 40'sh7F_FFFF_FFFF;  // +549,755,813,887
    localparam logic signed [ACCUM_WIDTH-1:0] SAT_MAX_NEG = -40'sh80_0000_0000; // -549,755,813,888

    // Testbench signals
    logic                          clk;
    logic                          rst_n;
    logic [1:0]                    cfg_mode;
    logic                          cfg_invalid;
    logic [6:0]                    active_pe_count;
    logic [COLS-1:0]               col_active;

    logic                          enable;
    logic [COLS-1:0]               col_enable;
    logic                          accum_clear;
    logic                          sat_clear;

    logic                          broadcast_act;
    logic signed [ACT_WIDTH-1:0]    act_data_row [0:ROWS-1];
    logic                           act_mask_row [0:ROWS-1];
    logic signed [ACT_WIDTH-1:0]    act_data     [0:ROWS-1][0:COLS-1];
    logic                           act_mask     [0:ROWS-1][0:COLS-1];
    logic signed [WEIGHT_WIDTH-1:0] weight_data  [0:ROWS-1][0:COLS-1];

    wire signed [ACCUM_WIDTH-1:0]   accum_out         [0:ROWS-1][0:COLS-1];
    wire                            sticky_saturation [0:ROWS-1][0:COLS-1];
    wire                            cycle_skipped     [0:ROWS-1][0:COLS-1];

    wire [COLS-1:0]                 col_sticky_saturation;
    wire [COLS-1:0]                 col_cycle_skipped;
    wire                            array_sticky_saturation;

    int pass_count;
    int fail_count;
    logic test_flag_a;
    logic test_flag_b;

    // Instantiate Device Under Test (DUT)
    pe_array_40b #(
        .ROWS(ROWS),
        .COLS(COLS),
        .ACT_WIDTH(ACT_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_mode(cfg_mode),
        .cfg_invalid(cfg_invalid),
        .active_pe_count(active_pe_count),
        .col_active(col_active),
        .enable(enable),
        .col_enable(col_enable),
        .accum_clear(accum_clear),
        .sat_clear(sat_clear),
        .broadcast_act(broadcast_act),
        .act_data_row(act_data_row),
        .act_mask_row(act_mask_row),
        .act_data(act_data),
        .act_mask(act_mask),
        .weight_data(weight_data),
        .accum_out(accum_out),
        .sticky_saturation(sticky_saturation),
        .cycle_skipped(cycle_skipped),
        .col_sticky_saturation(col_sticky_saturation),
        .col_cycle_skipped(col_cycle_skipped),
        .array_sticky_saturation(array_sticky_saturation)
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
        enable        = 0;
        col_enable    = '1;
        accum_clear   = 0;
        sat_clear     = 0;
        broadcast_act = 0;
        for (int r = 0; r < ROWS; r = r + 1) begin
            act_data_row[r] = '0;
            act_mask_row[r] = '0;
            for (int c = 0; c < COLS; c = c + 1) begin
                act_data[r][c]    = '0;
                act_mask[r][c]    = '0;
                weight_data[r][c] = '0;
            end
        end
    endtask

    // Main verification sequence
    initial begin
        pass_count = 0;
        fail_count = 0;

        $display("==================================================================");
        $display("Starting TSK-01 Multi-PE Array RTL Verification (tb_pe_array_40b)");
        $display("==================================================================");

        clear_inputs();
        cfg_mode = 2'b10; // Default Mode 2
        rst_n    = 0;
        #(CLK_PERIOD * 2);
        rst_n    = 1;
        #(CLK_PERIOD);

        // ---------------------------------------------------------------------
        // TEST 1: Reset Behavior
        // ---------------------------------------------------------------------
        test_flag_a = 1'b1;
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                if (accum_out[r][c] !== 40'sd0 || sticky_saturation[r][c] !== 1'b0 || cycle_skipped[r][c] !== 1'b0)
                    test_flag_a = 1'b0;
            end
        end
        check("TEST-01", "Reset initializes all 64 PEs to zero outputs and clear flags", test_flag_a);

        // ---------------------------------------------------------------------
        // TEST 2: Mode 0 (16 Active PEs: Cols 0..3)
        // ---------------------------------------------------------------------
        @(negedge clk);
        cfg_mode = 2'b00;
        @(negedge clk);
        check("TEST-02A", "Mode 0 config decoding: active_pe_count == 16", (active_pe_count == 7'd16));
        check("TEST-02B", "Mode 0 config decoding: col_active == 16'h000F", (col_active == 16'h000F));
        check("TEST-02C", "Mode 0 config decoding: cfg_invalid == 0", (cfg_invalid == 1'b0));

        // ---------------------------------------------------------------------
        // TEST 3: Mode 1 (32 Active PEs: Cols 0..7)
        // ---------------------------------------------------------------------
        @(negedge clk);
        cfg_mode = 2'b01;
        @(negedge clk);
        check("TEST-03A", "Mode 1 config decoding: active_pe_count == 32", (active_pe_count == 7'd32));
        check("TEST-03B", "Mode 1 config decoding: col_active == 16'h00FF", (col_active == 16'h00FF));
        check("TEST-03C", "Mode 1 config decoding: cfg_invalid == 0", (cfg_invalid == 1'b0));

        // ---------------------------------------------------------------------
        // TEST 4: Mode 2 (64 Active PEs: Cols 0..15)
        // ---------------------------------------------------------------------
        @(negedge clk);
        cfg_mode = 2'b10;
        @(negedge clk);
        check("TEST-04A", "Mode 2 config decoding: active_pe_count == 64", (active_pe_count == 7'd64));
        check("TEST-04B", "Mode 2 config decoding: col_active == 16'hFFFF", (col_active == 16'hFFFF));
        check("TEST-04C", "Mode 2 config decoding: cfg_invalid == 0", (cfg_invalid == 1'b0));

        // ---------------------------------------------------------------------
        // TEST 5: Correct Multi-Cycle Accumulation in Active PEs (Mode 2)
        // ---------------------------------------------------------------------
        @(negedge clk);
        accum_clear = 1;
        @(negedge clk);
        accum_clear = 0;

        // Cycle 1: A = 10, W = 20 -> Prod = 200
        @(negedge clk);
        enable = 1;
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                act_data[r][c]    = 16'sd10;
                act_mask[r][c]    = 1'b1;
                weight_data[r][c] = 16'sd20;
            end
        end

        // Cycle 2: A = 5, W = 30 -> Prod = 150 (Total = 350)
        @(negedge clk);
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                act_data[r][c]    = 16'sd5;
                act_mask[r][c]    = 1'b1;
                weight_data[r][c] = 16'sd30;
            end
        end

        @(negedge clk);
        enable = 0;

        test_flag_a = 1'b1;
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                if (accum_out[r][c] !== 40'sd350)
                    test_flag_a = 1'b0;
            end
        end
        check("TEST-05", "Multi-cycle accumulation in Mode 2 yields exact sum (350) across all 64 PEs", test_flag_a);

        // ---------------------------------------------------------------------
        // TEST 6: Exact-Zero Activation Bypass
        // ---------------------------------------------------------------------
        // A. Mask-driven skip (act_mask = 0)
        @(negedge clk);
        enable = 1;
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                act_data[r][c]    = 16'sd99;
                act_mask[r][c]    = 1'b0; // Exact-zero skip
                weight_data[r][c] = 16'sd88;
            end
        end
        @(posedge clk);
        #1;
        check("TEST-06A", "Zero-mask asserts cycle_skipped without altering accumulator", 
              (cycle_skipped[0][0] == 1'b1 && accum_out[0][0] == 40'sd350 && col_cycle_skipped == 16'hFFFF));

        // B. Value-driven skip (act_data = 0, act_mask = 1)
        @(negedge clk);
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                act_data[r][c]    = 16'sd0; // Zero value
                act_mask[r][c]    = 1'b1;
                weight_data[r][c] = 16'sd77;
            end
        end
        @(posedge clk);
        #1;
        check("TEST-06B", "Zero-activation data asserts cycle_skipped and preserves accumulator",
              (cycle_skipped[0][0] == 1'b1 && accum_out[0][0] == 40'sd350));

        @(negedge clk);
        enable = 0;

        // ---------------------------------------------------------------------
        // TEST 7: Saturation & Sticky Flags
        // ---------------------------------------------------------------------
        // A. Positive saturation
        @(negedge clk);
        accum_clear = 1;
        @(negedge clk);
        accum_clear = 0;
        enable = 1;

        // Accumulate large product: 32767 * 32767 = 1,073,676,289
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                act_data[r][c]    = 16'sd32767;
                act_mask[r][c]    = 1'b1;
                weight_data[r][c] = 16'sd32767;
            end
        end

        // Run 515 cycles: 515 * 1,073,676,289 > +549,755,813,887 (SAT_MAX_POS)
        repeat (515) @(negedge clk);
        enable = 0;

        check("TEST-07A", "Positive overflow clamps at SAT_MAX_POS (+549,755,813,887)", 
              (accum_out[0][0] == SAT_MAX_POS && sticky_saturation[0][0] == 1'b1 && array_sticky_saturation == 1'b1));

        // B. Sticky flag persistence and sat_clear
        @(negedge clk);
        sat_clear = 1;
        @(negedge clk);
        sat_clear = 0;
        check("TEST-07B", "sat_clear clears sticky_saturation while preserving clamped accumulator",
              (accum_out[0][0] == SAT_MAX_POS && sticky_saturation[0][0] == 1'b0 && array_sticky_saturation == 1'b0));

        // C. Negative saturation
        @(negedge clk);
        accum_clear = 1;
        @(negedge clk);
        accum_clear = 0;
        enable = 1;

        // Accumulate large negative product: 32767 * -32768 = -1,073,709,056
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                act_data[r][c]    = 16'sd32767;
                act_mask[r][c]    = 1'b1;
                weight_data[r][c] = -16'sd32768;
            end
        end

        repeat (515) @(negedge clk);
        enable = 0;

        check("TEST-07C", "Negative overflow clamps at SAT_MAX_NEG (-549,755,813,888)",
              (accum_out[0][0] == SAT_MAX_NEG && sticky_saturation[0][0] == 1'b1));

        // ---------------------------------------------------------------------
        // TEST 8: Inactive PE Isolation (Mode 0: Cols 4..15 Clamped)
        // ---------------------------------------------------------------------
        @(negedge clk);
        accum_clear = 1;
        sat_clear   = 1;
        cfg_mode    = 2'b00; // Mode 0: cols 0..3 active, cols 4..15 inactive
        @(negedge clk);
        accum_clear = 0;
        sat_clear   = 0;

        // Drive all PEs with non-zero inputs
        enable = 1;
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                act_data[r][c]    = 16'sd100;
                act_mask[r][c]    = 1'b1;
                weight_data[r][c] = 16'sd200;
            end
        end

        @(negedge clk);
        enable = 0;

        test_flag_a = 1'b1;
        test_flag_b = 1'b1;

        // Columns 0..3 must have accumulated 20,000
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < 4; c = c + 1) begin
                if (accum_out[r][c] !== 40'sd20000) test_flag_a = 1'b0;
            end
        end

        // Columns 4..15 must be strictly isolated with zero output
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 4; c < COLS; c = c + 1) begin
                if (accum_out[r][c] !== 40'sd0 || sticky_saturation[r][c] !== 1'b0 || cycle_skipped[r][c] !== 1'b0)
                    test_flag_b = 1'b0;
            end
        end

        check("TEST-08A", "Mode 0: Active columns (0..3) compute correctly (20,000)", test_flag_a);
        check("TEST-08B", "Mode 0: Inactive columns (4..15) are strictly isolated with zero output", test_flag_b);

        // ---------------------------------------------------------------------
        // TEST 9: Inactive PE Isolation (Mode 1: Cols 8..15 Clamped)
        // ---------------------------------------------------------------------
        @(negedge clk);
        accum_clear = 1;
        cfg_mode    = 2'b01; // Mode 1: cols 0..7 active, cols 8..15 inactive
        @(negedge clk);
        accum_clear = 0;

        enable = 1;
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                act_data[r][c]    = 16'sd50;
                act_mask[r][c]    = 1'b1;
                weight_data[r][c] = 16'sd50;
            end
        end

        @(negedge clk);
        enable = 0;

        test_flag_a = 1'b1;
        test_flag_b = 1'b1;

        // Columns 0..7 must have accumulated 2,500
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < 8; c = c + 1) begin
                if (accum_out[r][c] !== 40'sd2500) test_flag_a = 1'b0;
            end
        end

        // Columns 8..15 must be strictly isolated (0)
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 8; c < COLS; c = c + 1) begin
                if (accum_out[r][c] !== 40'sd0) test_flag_b = 1'b0;
            end
        end

        check("TEST-09A", "Mode 1: Active columns (0..7) compute correctly (2,500)", test_flag_a);
        check("TEST-09B", "Mode 1: Inactive columns (8..15) are strictly isolated with zero output", test_flag_b);

        // ---------------------------------------------------------------------
        // TEST 10: Dynamic Mode Switching Across Layer Barriers
        // ---------------------------------------------------------------------
        // Step 1: Compute in Mode 0
        @(negedge clk);
        accum_clear = 1;
        cfg_mode    = 2'b00;
        @(negedge clk);
        accum_clear = 0;
        enable = 1;
        act_data[0][0]    = 16'sd10; 
        act_mask[0][0]    = 1'b1; 
        weight_data[0][0] = 16'sd10; // +100 in Col 0
        @(negedge clk);
        enable = 0;

        // Step 2: Switch to Mode 1 with accum_clear (Layer Barrier)
        @(negedge clk);
        clear_inputs();
        accum_clear = 1;
        cfg_mode    = 2'b01;
        @(negedge clk);
        accum_clear = 0;
        enable = 1;
        act_data[0][5]    = 16'sd20; 
        act_mask[0][5]    = 1'b1; 
        weight_data[0][5] = 16'sd20; // +400 in Col 5
        @(negedge clk);
        enable = 0;

        check("TEST-10", "Dynamic configuration switch Mode 0 -> Mode 1 executes cleanly across barrier",
              (accum_out[0][5] == 40'sd400 && accum_out[0][0] == 40'sd0 && col_active == 16'h00FF));

        // ---------------------------------------------------------------------
        // TEST 11: Reset Mid-Compute Behavior
        // ---------------------------------------------------------------------
        @(negedge clk);
        cfg_mode = 2'b10;
        accum_clear = 1;
        @(negedge clk);
        accum_clear = 0;
        enable = 1;
        act_data[0][0]    = 16'sd500; 
        act_mask[0][0]    = 1'b1; 
        weight_data[0][0] = 16'sd500;
        @(negedge clk);
        // Mid-compute asynchronous reset assertion
        rst_n = 0;
        #1;
        check("TEST-11A", "Asynchronous rst_n asserted mid-compute immediately resets accumulator to 0",
              (accum_out[0][0] == 40'sd0));

        #(CLK_PERIOD * 2);
        rst_n = 1;
        enable = 0;
        @(negedge clk);
        check("TEST-11B", "Post-reset state remains quiescent at 0", (accum_out[0][0] == 40'sd0));

        // ---------------------------------------------------------------------
        // TEST 12: Invalid Configuration Handling (2'b11)
        // ---------------------------------------------------------------------
        @(negedge clk);
        cfg_mode = 2'b11; // Invalid mode
        @(negedge clk);
        check("TEST-12A", "cfg_mode 2'b11 raises cfg_invalid flag", (cfg_invalid == 1'b1));
        check("TEST-12B", "cfg_mode 2'b11 reports active_pe_count == 0", (active_pe_count == 7'd0));
        check("TEST-12C", "cfg_mode 2'b11 forces col_active == 16'h0000", (col_active == 16'h0000));

        // Drive inputs while in invalid configuration
        enable = 1;
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                act_data[r][c]    = 16'sd100;
                act_mask[r][c]    = 1'b1;
                weight_data[r][c] = 16'sd100;
            end
        end
        @(negedge clk);
        enable = 0;

        test_flag_a = 1'b1;
        for (int r = 0; r < ROWS; r = r + 1) begin
            for (int c = 0; c < COLS; c = c + 1) begin
                if (accum_out[r][c] !== 40'sd0) test_flag_a = 1'b0;
            end
        end
        check("TEST-12D", "Invalid configuration completely blocks computation across all 64 PEs", test_flag_a);

        // ---------------------------------------------------------------------
        // TEST 13: Activation Row-Broadcast Mode
        // ---------------------------------------------------------------------
        @(negedge clk);
        cfg_mode      = 2'b00; // Mode 0 (cols 0..3)
        accum_clear   = 1;
        broadcast_act = 1; // Enable broadcast
        @(negedge clk);
        accum_clear   = 0;

        // Broadcast act_data_row[0] = 15 to all columns in row 0
        act_data_row[0] = 16'sd15;
        act_mask_row[0] = 1'b1;
        for (int c = 0; c < 4; c = c + 1) begin
            weight_data[0][c] = 16'sd10 * (c + 1); // Col 0: 10, Col 1: 20, Col 2: 30, Col 3: 40
        end

        enable = 1;
        @(negedge clk);
        enable = 0;

        check("TEST-13", "Row-broadcast distributes activation to all active columns (150, 300, 450, 600)",
              (accum_out[0][0] == 40'sd150 && accum_out[0][1] == 40'sd300 &&
               accum_out[0][2] == 40'sd450 && accum_out[0][3] == 40'sd600));

        // ---------------------------------------------------------------------
        // Final Summary
        // ---------------------------------------------------------------------
        #(CLK_PERIOD * 2);
        $display("==================================================================");
        $display("TSK-01 Test Summary: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");
        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-01 Multi-PE Array RTL Tests Passed!");
        end else begin
            $display("[FAILURE] %0d Tests Failed in TSK-01 Multi-PE Array RTL!", fail_count);
        end
        $finish;
    end

endmodule
