// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Integration)
// Module: tb_mac_saturation.sv
// Description: Focused Testbench for Signed 40-bit Saturating MAC Unit & Sticky Clear
// Specification: DEC-P2-07 Option A & SATURATION_STATUS_CONTRACT.md
// =============================================================================

`timescale 1ns / 1ps

module tb_mac_saturation;

    localparam int CLK_PERIOD = 10;
    localparam int ACT_WIDTH = 16;
    localparam int WEIGHT_WIDTH = 16;
    localparam int ACCUM_WIDTH = 40;

    localparam logic signed [39:0] SAT_MAX_POS = 40'sh7F_FFFF_FFFF;  // +549,755,813,887
    localparam logic signed [39:0] SAT_MAX_NEG = -40'sh80_0000_0000; // -549,755,813,888

    logic                          clk;
    logic                          rst_n;
    logic                          enable;
    logic                          accum_clear;
    logic                          sat_clear;
    logic signed [ACT_WIDTH-1:0]   act_data;
    logic                          act_mask;
    logic signed [WEIGHT_WIDTH-1:0] weight_data;
    
    logic signed [ACCUM_WIDTH-1:0] accum_out;
    logic                          sticky_saturation;
    logic                          cycle_skipped;

    int pass_count = 0;
    int fail_count = 0;

    mac_unit_40b #(
        .ACT_WIDTH(ACT_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .accum_clear(accum_clear),
        .sat_clear(sat_clear),
        .act_data(act_data),
        .act_mask(act_mask),
        .weight_data(weight_data),
        .accum_out(accum_out),
        .sticky_saturation(sticky_saturation),
        .cycle_skipped(cycle_skipped)
    );

    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    task check_condition(input string test_name, input logic cond);
        if (cond) begin
            $display("[PASS] %s", test_name);
            pass_count++;
        end else begin
            $display("[FAIL] %s", test_name);
            fail_count++;
        end
    endtask

    initial begin
        // Initialize
        enable = 0; accum_clear = 0; sat_clear = 0;
        act_data = 0; act_mask = 0; weight_data = 0;
        rst_n = 0;
        #(CLK_PERIOD * 2);
        rst_n = 1;
        #(CLK_PERIOD);

        $display("==================================================================");
        $display("Starting Focused Verification: mac_unit_40b Saturation & Clear");
        $display("==================================================================");

        // 1. Nominal accumulation within bounds: no saturation
        @(negedge clk);
        enable = 1; act_mask = 1;
        act_data = 16'sd1000; weight_data = 16'sd1000; // +1,000,000
        @(negedge clk);
        enable = 0;
        check_condition("MAC-SAT-01: Nominal accumulation without saturation", (accum_out == 40'sd1000000 && sticky_saturation == 1'b0));

        // 2. Exact Positive Limit: inject product bringing accum to exactly +549,755,813,887
        // Reset accumulator to 0 first
        @(negedge clk);
        accum_clear = 1;
        @(negedge clk);
        accum_clear = 0;
        check_condition("MAC-SAT-02: Accumulator clear restores accum_out to 0", (accum_out == 40'sd0 && sticky_saturation == 1'b0));

        // Accumulate up to exact boundary
        // We can drive DUT internal accum or accumulate products.
        // Let's test boundary by accumulating products:
        // 32767 * 1000 = 32,767,000.
        // Or directly check overflow clamping:
        // Let's accumulate large positive products
        // To reach near 2^39 in simulation:
        // We can do a sequence or force accum_out in a test hook or test large product:
        // Let's test overflow:
        // When accum_out is near max or we drive multiple cycles:
        // Wait, 40-bit is 549 billion. 32767*1000 = 3.27e7 per cycle. That takes ~16,000 cycles.
        // In verilog simulation, 16,000 cycles is very fast (1 millisecond of sim time)!
        // Let's do a loop:
        for (int i = 0; i < 16777; i++) begin
            @(negedge clk);
            enable = 1; act_mask = 1;
            act_data = 16'sd32767; weight_data = 16'sd1000;
        end
        // Now accum is at 16777 * 32,767,000 = 549,731,959,000.
        // Remaining to reach exact +549,755,813,887 is: 23,854,887.
        // 23,854 * 1000 = 23,854,000.
        @(negedge clk);
        act_data = 16'sd23854; weight_data = 16'sd1000;
        // Remaining: 887.
        @(negedge clk);
        act_data = 16'sd887; weight_data = 16'sd1;
        @(negedge clk);
        enable = 0;
        check_condition("MAC-SAT-03: Exact positive boundary (+549755813887) reached without saturation", 
            (accum_out == SAT_MAX_POS && sticky_saturation == 1'b0));

        // 3. Positive Overflow: 1 more unit causes positive saturation
        @(negedge clk);
        enable = 1; act_mask = 1;
        act_data = 16'sd1; weight_data = 16'sd1; // +1 overflow
        @(negedge clk);
        enable = 0;
        check_condition("MAC-SAT-04: Positive overflow clamps to +549755813887 and sets sticky saturation", 
            (accum_out == SAT_MAX_POS && sticky_saturation == 1'b1));

        // 4. Sticky persistence across subsequent operations (even zeros or skips)
        for (int i = 0; i < 10; i++) begin
            @(negedge clk);
            enable = 1; act_mask = 0; // skip
            act_data = 16'sd0; weight_data = 16'sd0;
        end
        @(negedge clk);
        enable = 0;
        check_condition("MAC-SAT-05: Sticky saturation persists across 10 skipped flits", (sticky_saturation == 1'b1));

        // 5. Accumulator clear preserves sticky flag
        @(negedge clk);
        accum_clear = 1;
        @(negedge clk);
        accum_clear = 0;
        check_condition("MAC-SAT-06: accum_clear zeroes accumulator but preserves sticky saturation", 
            (accum_out == 40'sd0 && sticky_saturation == 1'b1));

        // 6. Explicit sat_clear clears sticky flag
        @(negedge clk);
        sat_clear = 1;
        @(negedge clk);
        sat_clear = 0;
        check_condition("MAC-SAT-07: sat_clear pulse deasserts sticky saturation to 0", (sticky_saturation == 1'b0));

        // 7. Negative Exact Limit and Negative Overflow
        // Let's loop down to negative boundary:
        // Need -549,755,813,888.
        for (int i = 0; i < 16777; i++) begin
            @(negedge clk);
            enable = 1; act_mask = 1;
            act_data = -16'sd32767; weight_data = 16'sd1000;
        end
        // -549,731,959,000.
        // Need -23,854,888 more.
        @(negedge clk);
        act_data = -16'sd23854; weight_data = 16'sd1000;
        @(negedge clk);
        act_data = -16'sd888; weight_data = 16'sd1;
        @(negedge clk);
        enable = 0;
        check_condition("MAC-SAT-08: Exact negative boundary (-549755813888) reached without saturation", 
            (accum_out == SAT_MAX_NEG && sticky_saturation == 1'b0));

        // Negative overflow: 1 more negative unit
        @(negedge clk);
        enable = 1; act_mask = 1;
        act_data = -16'sd1; weight_data = 16'sd1;
        @(negedge clk);
        enable = 0;
        check_condition("MAC-SAT-09: Negative overflow clamps to -549755813888 and sets sticky saturation", 
            (accum_out == SAT_MAX_NEG && sticky_saturation == 1'b1));

        // 8. Simultaneous clear and saturation (saturation takes precedence)
        // With accumulator at SAT_MAX_NEG, add -1000 (overflow) while asserting sat_clear = 1
        @(negedge clk);
        enable = 1; act_mask = 1; sat_clear = 1;
        act_data = -16'sd1000; weight_data = 16'sd1;
        @(negedge clk);
        enable = 0; sat_clear = 0;
        check_condition("MAC-SAT-10: Simultaneous sat_clear and saturation: saturation wins", (sticky_saturation == 1'b1));

        // 9. Reset clears both accumulator and sticky saturation
        @(negedge clk);
        rst_n = 0;
        @(negedge clk);
        rst_n = 1;
        check_condition("MAC-SAT-11: Asynchronous rst_n clears both accumulator and sticky saturation", 
            (accum_out == 40'sd0 && sticky_saturation == 1'b0));

        $display("==================================================================");
        $display("MAC Saturation Summary: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All MAC Saturation & Clear Tests Completed Successfully!");
            $finish(0);
        end else begin
            $display("[ERROR] Failures encountered in MAC saturation simulation.");
            $finish(1);
        end
    end

endmodule

