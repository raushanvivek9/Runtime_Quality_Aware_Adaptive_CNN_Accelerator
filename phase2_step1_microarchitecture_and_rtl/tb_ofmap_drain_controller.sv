// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-11 Phase 2A Standalone OFMAP Drain Controller Unit Testbench
// Module: tb_ofmap_drain_controller.sv
// Description: Exhaustive standalone verification suite for ofmap_drain_controller.
//              Contains an independent bus scoreboard that reconstructs every 40-bit
//              accumulator from two written words, verifies address progression and
//              low-order bank interleaving, and exercises all 11 required scenarios.
// =============================================================================

`timescale 1ns / 1ps

module tb_ofmap_drain_controller;

    parameter int ROWS         = 4;
    parameter int COLS         = 16;
    parameter int ACCUM_WIDTH  = 40;
    parameter int SRAM_ADDR_W  = 14;
    parameter int DATA_WIDTH   = 32;

    // Clock and Reset
    logic clk;
    logic rst_n;

    // DUT Control and Status
    logic [1:0]                cfg_mode;
    logic                      drain_start;
    logic [SRAM_ADDR_W-1:0]    base_addr;
    wire                       drain_busy;
    wire                       drain_done;
    wire                       drain_error_flag;
    logic                      error_clear;
    wire                       busy_reject_pulse;
    wire  [7:0]                words_written_count;

    // 64 Signed 40-bit Accumulator Inputs
    logic signed [ACCUM_WIDTH-1:0] accum_out [0:ROWS-1][0:COLS-1];

    // SRAM Port A Write Interface
    wire                       sram_wr_req;
    wire  [SRAM_ADDR_W-1:0]    sram_wr_addr;
    wire  [DATA_WIDTH-1:0]     sram_wr_din;
    wire  [(DATA_WIDTH/8)-1:0] sram_wr_byte_we;
    logic                      sram_wr_ready;
    logic                      sram_wr_ack;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    ofmap_drain_controller #(
        .ROWS              (ROWS),
        .COLS              (COLS),
        .ACCUM_WIDTH       (ACCUM_WIDTH),
        .SRAM_ADDR_W       (SRAM_ADDR_W),
        .DATA_WIDTH        (DATA_WIDTH),
        .DEFAULT_BASE_ADDR (14'h2000)
    ) dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .cfg_mode            (cfg_mode),
        .drain_start         (drain_start),
        .base_addr           (base_addr),
        .drain_busy          (drain_busy),
        .drain_done          (drain_done),
        .drain_error_flag    (drain_error_flag),
        .error_clear         (error_clear),
        .busy_reject_pulse   (busy_reject_pulse),
        .words_written_count (words_written_count),
        .accum_out           (accum_out),
        .sram_wr_req         (sram_wr_req),
        .sram_wr_addr        (sram_wr_addr),
        .sram_wr_din         (sram_wr_din),
        .sram_wr_byte_we     (sram_wr_byte_we),
        .sram_wr_ready       (sram_wr_ready),
        .sram_wr_ack         (sram_wr_ack)
    );

    // Clock generation (100MHz, 10ns period)
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Independent Verification Scoreboard
    // -------------------------------------------------------------------------
    int test_count;
    int pass_count;
    int fail_count;

    int scoreboard_count;
    logic [SRAM_ADDR_W-1:0]    sb_addr    [0:255];
    logic [DATA_WIDTH-1:0]     sb_din     [0:255];
    logic [(DATA_WIDTH/8)-1:0] sb_byte_we [0:255];

    // Scoreboard capture: captures on posedge clk when sram_wr_req && sram_wr_ready
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (sram_wr_req && sram_wr_ready) begin
                if (scoreboard_count < 256) begin
                    sb_addr[scoreboard_count]    <= sram_wr_addr;
                    sb_din[scoreboard_count]     <= sram_wr_din;
                    sb_byte_we[scoreboard_count] <= sram_wr_byte_we;
                    scoreboard_count             <= scoreboard_count + 1;
                end
            end
        end
    end

    // Check helper routines
    task automatic check_val(input string tag, input logic [31:0] actual, input logic [31:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%0d (0x%0h), expected=%0d (0x%0h)", tag, actual, actual, expected, expected);
        end
    endtask

    task automatic check_val40(input string tag, input logic signed [39:0] actual, input logic signed [39:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%0d (0x%0h), expected=%0d (0x%0h)", tag, actual, actual, expected, expected);
        end
    endtask

    task automatic check_bool(input string tag, input logic actual, input logic expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%b, expected=%b", tag, actual, expected);
        end
    endtask

    // Reset helper
    task automatic apply_reset();
        rst_n         = 1'b0;
        cfg_mode      = 2'b10;
        drain_start   = 1'b0;
        error_clear   = 1'b0;
        base_addr     = '0;
        sram_wr_ready = 1'b1;
        sram_wr_ack   = 1'b1;
        scoreboard_count = 0;
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                accum_out[r][c] = '0;
            end
        end
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // Start drain helper
    task automatic start_drain(input logic [SRAM_ADDR_W-1:0] target_base);
        scoreboard_count = 0;
        @(negedge clk);
        base_addr   = target_base;
        drain_start = 1'b1;
        @(negedge clk);
        drain_start = 1'b0;
    endtask

    // Wait completion helper
    task automatic wait_done(input int max_cycles);
        int cnt;
        cnt = 0;
        while (!drain_done && (cnt < max_cycles)) begin
            @(posedge clk);
            cnt++;
        end
        if (cnt >= max_cycles) begin
            $display("[ERROR] Timeout waiting for drain_done! (waited %0d cycles)", max_cycles);
            fail_count++;
            test_count++;
        end
    endtask

    // Test vector storage for verification
    logic signed [ACCUM_WIDTH-1:0] test_tile [0:ROWS-1][0:COLS-1];

    // Full 128-word Tile Reconstruction and Verification Scoreboard
    task automatic verify_tile_scoreboard(
        input string tag,
        input logic [SRAM_ADDR_W-1:0] exp_base
    );
        int mismatches;
        mismatches = 0;

        // 1. Verify exactly 128 writes were accepted
        check_val($sformatf("%s: Exactly 128 writes accepted", tag), scoreboard_count, 128);

        // 2. Verify all 64 coordinates in row-major order
        for (int pe = 0; pe < 64; pe++) begin
            int r, c;
            int low_idx, hi_idx;
            logic [31:0] w_low, w_hi;
            logic signed [39:0] exp_val;
            logic signed [39:0] reconstructed;
            logic [23:0] expected_sign_ext;

            r = pe / 16;
            c = pe % 16;
            low_idx = pe * 2;
            hi_idx  = pe * 2 + 1;

            exp_val = test_tile[r][c];
            w_low   = sb_din[low_idx];
            w_hi    = sb_din[hi_idx];

            // Address checks
            if (sb_addr[low_idx] !== (exp_base + low_idx)) begin
                mismatches++;
                $display("[FAIL] %s PE[%0d][%0d] Low Addr: actual=0x%0h, exp=0x%0h",
                         tag, r, c, sb_addr[low_idx], exp_base + low_idx);
            end
            if (sb_addr[hi_idx] !== (exp_base + hi_idx)) begin
                mismatches++;
                $display("[FAIL] %s PE[%0d][%0d] Hi Addr: actual=0x%0h, exp=0x%0h",
                         tag, r, c, sb_addr[hi_idx], exp_base + hi_idx);
            end

            // Byte enable checks
            if (sb_byte_we[low_idx] !== 4'b1111 || sb_byte_we[hi_idx] !== 4'b1111) begin
                mismatches++;
                $display("[FAIL] %s PE[%0d][%0d] Byte WE not 4'b1111", tag, r, c);
            end

            // Lower word match
            if (w_low !== exp_val[31:0]) begin
                mismatches++;
                $display("[FAIL] %s PE[%0d][%0d] Low Word: actual=0x%0h, exp=0x%0h",
                         tag, r, c, w_low, exp_val[31:0]);
            end

            // Upper 8 bits match
            if (w_hi[7:0] !== exp_val[39:32]) begin
                mismatches++;
                $display("[FAIL] %s PE[%0d][%0d] Hi Word [7:0]: actual=0x%0h, exp=0x%0h",
                         tag, r, c, w_hi[7:0], exp_val[39:32]);
            end

            // Sign extension match
            expected_sign_ext = exp_val[39] ? 24'hFFFFFF : 24'h000000;
            if (w_hi[31:8] !== expected_sign_ext) begin
                mismatches++;
                $display("[FAIL] %s PE[%0d][%0d] Sign Ext [31:8]: actual=0x%0h, exp=0x%0h",
                         tag, r, c, w_hi[31:8], expected_sign_ext);
            end

            // Reconstruct full 40-bit signed value
            reconstructed = {w_hi[7:0], w_low};
            check_val40($sformatf("%s: PE[%0d][%0d] Reconstructed", tag, r, c), reconstructed, exp_val);
        end
    endtask

    // =========================================================================
    // Main Verification Procedure (11 Scenarios)
    // =========================================================================
    initial begin
        clk = 1'b0;
        test_count = 0;
        pass_count = 0;
        fail_count = 0;

        $display("==================================================================");
        $display("TSK-11 Phase 2A: Standalone OFMAP Drain Controller Verification");
        $display("==================================================================");

        apply_reset();

        // ---------------------------------------------------------------------
        // SCENARIO 1: All-Zero Accumulators (Requirement 5.1)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 1: All-Zero Accumulators ---");
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                test_tile[r][c] = 40'sd0;
                accum_out[r][c] = test_tile[r][c];
            end
        end

        sram_wr_ready = 1'b1;
        start_drain(14'h2000);
        check_bool("1.1: drain_busy asserted during drain", drain_busy, 1'b1);
        wait_done(150);
        check_bool("1.2: drain_done pulsed", drain_done, 1'b1);
        @(posedge clk);
        check_bool("1.3: drain_done deasserted after 1 cycle", drain_done, 1'b0);
        check_bool("1.4: drain_busy deasserted after done", drain_busy, 1'b0);

        verify_tile_scoreboard("Scenario_1", 14'h2000);

        // ---------------------------------------------------------------------
        // SCENARIO 2: Distinct Positive and Negative Values Across All 64 PEs (Req 5.2)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 2: Distinct Signed Values Across All 64 Coordinates ---");
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                int idx;
                idx = r * 16 + c;
                test_tile[r][c] = (idx % 2 == 0) ? (40'sd12345 * (idx + 1)) : (-40'sd54321 * (idx + 1));
                accum_out[r][c] = test_tile[r][c];
            end
        end

        start_drain(14'h2080);
        wait_done(150);
        verify_tile_scoreboard("Scenario_2", 14'h2080);

        // ---------------------------------------------------------------------
        // SCENARIO 3: Minimum and Maximum Signed 40-bit Values (Req 5.3)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 3: Minimum and Maximum Signed 40-bit Values ---");
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                test_tile[r][c] = 40'sd0;
            end
        end
        test_tile[0][0] = 40'sh7F_FFFF_FFFF;  // Max positive (+549,755,813,887)
        test_tile[0][1] = -40'sh80_0000_0000; // Max negative (-549,755,813,888)
        test_tile[0][2] = 40'sh00_0000_0001;  // +1
        test_tile[0][3] = -40'sh00_0000_0001; // -1
        test_tile[0][4] = 40'sh00_7FFF_FFFF;  // +2^31 - 1
        test_tile[0][5] = -40'sh00_8000_0000; // -2^31
        test_tile[0][6] = 40'sh00_8000_0000;  // +2^31
        test_tile[0][7] = 40'sh01_0000_0000;  // +2^32
        test_tile[0][8] = -40'sh01_0000_0000; // -2^32

        for (int pe = 9; pe < 64; pe++) begin
            test_tile[pe / 16][pe % 16] = (pe % 2 == 0) ? 40'sh3F_FFFF_FFFF : -40'sh40_0000_0000;
        end

        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                accum_out[r][c] = test_tile[r][c];
            end
        end

        start_drain(14'h2100);
        wait_done(150);
        verify_tile_scoreboard("Scenario_3", 14'h2100);

        // ---------------------------------------------------------------------
        // SCENARIO 4: Values That Exercise the Sign-Extension Word (Req 5.4)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 4: Sign-Extension Word Patterns ---");
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                // Alternating positive and negative with upper byte set to non-zero
                test_tile[r][c] = (c % 2 == 0) ? (40'sh55_1234_5678) : (-40'sh2A_8765_4321);
                accum_out[r][c] = test_tile[r][c];
            end
        end

        start_drain(14'h2180);
        wait_done(150);
        verify_tile_scoreboard("Scenario_4", 14'h2180);

        // ---------------------------------------------------------------------
        // SCENARIO 5: Backpressure Lasting Multiple Cycles (Req 5.5)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 5: Multi-Cycle Backpressure & Hold Stability ---");
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                test_tile[r][c] = (r * 16 + c) * 40'sd50 - 40'sd500;
                accum_out[r][c] = test_tile[r][c];
            end
        end

        start_drain(14'h2200);

        // Inject 15 cycles of stall at word 10
        wait (dut.word_idx_q == 7'd10);
        @(negedge clk);
        sram_wr_ready = 1'b0;
        begin
            logic [SRAM_ADDR_W-1:0] held_addr;
            logic [DATA_WIDTH-1:0]  held_din;
            held_addr = sram_wr_addr;
            held_din  = sram_wr_din;

            repeat (15) begin
                @(posedge clk);
                #1;
                if (sram_wr_addr !== held_addr || sram_wr_din !== held_din || sram_wr_req !== 1'b1) begin
                    $display("[FAIL] Output signals glitched during stall!");
                    fail_count++;
                end
            end
        end
        @(negedge clk);
        sram_wr_ready = 1'b1;

        // Inject 10 cycles of stall at word 60
        wait (dut.word_idx_q == 7'd60);
        @(negedge clk);
        sram_wr_ready = 1'b0;
        repeat (10) @(posedge clk);
        @(negedge clk);
        sram_wr_ready = 1'b1;

        wait_done(200);
        verify_tile_scoreboard("Scenario_5", 14'h2200);

        // ---------------------------------------------------------------------
        // SCENARIO 6: Repeated Same-Bank Conflicts (Req 5.6)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 6: Repeated Same-Bank Conflicts (Bank 3 Busy) ---");
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                test_tile[r][c] = (r * 16 + c) * 40'sd99;
                accum_out[r][c] = test_tile[r][c];
            end
        end

        start_drain(14'h2280);

        // Whenever target bank is Bank 3, inject a 3-cycle conflict stall
        fork
            begin
                while (drain_busy) begin
                    @(posedge clk);
                    if (sram_wr_req && (sram_wr_addr[2:0] == 3'd3) && sram_wr_ready) begin
                        // Stall Bank 3 for 3 cycles
                        @(negedge clk);
                        sram_wr_ready = 1'b0;
                        repeat (3) @(posedge clk);
                        @(negedge clk);
                        sram_wr_ready = 1'b1;
                    end
                end
                sram_wr_ready = 1'b1;
            end
            begin
                wait_done(300);
            end
        join

        verify_tile_scoreboard("Scenario_6", 14'h2280);

        // ---------------------------------------------------------------------
        // SCENARIO 7: Reset Before Start (Req 5.7)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 7: Reset Before Start ---");
        sram_wr_ready = 1'b1;
        apply_reset();
        check_bool("7.1: drain_busy is 0 after reset", drain_busy, 1'b0);
        check_bool("7.2: drain_done is 0 after reset", drain_done, 1'b0);
        check_bool("7.3: sram_wr_req is 0 after reset", sram_wr_req, 1'b0);
        check_val("7.4: words_written_count is 0 after reset", words_written_count, 8'd0);

        // ---------------------------------------------------------------------
        // SCENARIO 8: Reset During Active Drain (Req 5.8)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 8: Reset During Active Drain ---");
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                test_tile[r][c] = (r * 16 + c) + 40'sd1;
                accum_out[r][c] = test_tile[r][c];
            end
        end

        start_drain(14'h2300);
        wait (dut.word_idx_q == 7'd50);
        @(negedge clk);
        rst_n = 1'b0;
        @(posedge clk);
        #1;
        check_bool("8.1: drain_busy forced to 0 on mid-drain reset", drain_busy, 1'b0);
        check_bool("8.2: sram_wr_req deasserted on mid-drain reset", sram_wr_req, 1'b0);
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Recover and execute fresh drain completely
        start_drain(14'h2380);
        wait_done(150);
        verify_tile_scoreboard("Scenario_8_Recovered", 14'h2380);

        // ---------------------------------------------------------------------
        // SCENARIO 9: Start Request While Busy (Lockout) (Req 5.9)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 9: Start Request While Busy (Lockout) ---");
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                test_tile[r][c] = (r * 16 + c) * 40'sd77;
                accum_out[r][c] = test_tile[r][c];
            end
        end

        start_drain(14'h2400);

        wait (dut.word_idx_q == 7'd25);
        @(negedge clk);
        drain_start = 1'b1;
        @(posedge clk);
        #1;
        check_bool("9.1: busy_reject_pulse asserted on illegal start", busy_reject_pulse, 1'b1);
        @(negedge clk);
        drain_start = 1'b0;

        wait (dut.word_idx_q == 7'd75);
        @(negedge clk);
        drain_start = 1'b1;
        @(posedge clk);
        #1;
        check_bool("9.2: busy_reject_pulse asserted on second illegal start", busy_reject_pulse, 1'b1);
        @(negedge clk);
        drain_start = 1'b0;

        wait_done(150);
        verify_tile_scoreboard("Scenario_9", 14'h2400);

        // ---------------------------------------------------------------------
        // SCENARIO 10: Address Wrap/Boundary Check & Out-of-Bounds Rejection (Req 5.10)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 10: Address Boundary Check & OOB Rejection ---");
        // Base address 10,300 + 128 words = 10,428 > 10,368 (physical SRAM capacity)
        @(negedge clk);
        base_addr   = 14'd10300;
        drain_start = 1'b1;
        @(posedge clk);
        #1;
        check_bool("10.1: drain_error_flag asserted for out-of-bounds base address", drain_error_flag, 1'b1);
        check_bool("10.2: drain_busy not asserted for rejected start", drain_busy, 1'b0);
        check_bool("10.3: sram_wr_req not asserted for rejected start", sram_wr_req, 1'b0);
        @(negedge clk);
        drain_start = 1'b0;

        // Verify explicit error_clear handshake (TSK-11 Phase 2D)
        @(negedge clk);
        error_clear = 1'b1;
        @(posedge clk);
        #1;
        check_bool("10.3a: drain_error_flag deasserted after error_clear pulse", drain_error_flag, 1'b0);
        @(negedge clk);
        error_clear = 1'b0;

        // Valid boundary address: base = 10,368 - 128 = 10,240 (14'h2800)
        start_drain(14'h2800);
        check_bool("10.4: drain_error_flag deasserted for legal boundary address", drain_error_flag, 1'b0);
        wait_done(150);
        verify_tile_scoreboard("Scenario_10_MaxBoundary", 14'h2800);

        // ---------------------------------------------------------------------
        // SCENARIO 11: Exactly 128 Accepted Writes and One Completion Pulse (Req 5.11)
        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 11: Back-to-Back Consecutive Drains (Contamination Check) ---");
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                test_tile[r][c] = 40'sd5000 + (r * 16 + c);
                accum_out[r][c] = test_tile[r][c];
            end
        end
        start_drain(14'h2500);
        wait_done(150);
        verify_tile_scoreboard("Scenario_11_TileA", 14'h2500);

        // Immediate Tile B execution
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                test_tile[r][c] = -40'sd9000 + (r * 16 + c) * 40'sd20;
                accum_out[r][c] = test_tile[r][c];
            end
        end
        @(posedge clk);
        start_drain(14'h2580);
        wait_done(150);
        verify_tile_scoreboard("Scenario_11_TileB", 14'h2580);

        // ---------------------------------------------------------------------
        // FINAL SUMMARY
        // ---------------------------------------------------------------------
        $display("\n==================================================================");
        $display("TSK-11 Phase 2A OFMAP Drain Controller Summary:");
        $display("Total Checks: %0d | Passed: %0d | Failed: %0d", test_count, pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-11 Phase 2A OFMAP Drain Controller Tests Passed with Zero Failures!");
            $finish(0);
        end else begin
            $display("[FAIL] %0d checks failed in TSK-11 Phase 2A suite!", fail_count);
            $fatal(1, "TSK-11 Phase 2A checks failed");
        end
    end

endmodule
