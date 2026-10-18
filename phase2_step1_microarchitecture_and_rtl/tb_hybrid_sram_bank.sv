// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Integration)
// Module: tb_hybrid_sram_bank.sv
// Description: Focused Testbench for 5,184-Byte Dual-Bank Physical SRAM Model
// =============================================================================

`timescale 1ns / 1ps

module tb_hybrid_sram_bank;

    localparam int CLK_PERIOD = 10;
    localparam int TOTAL_BYTES = 5184;
    localparam int DATA_WIDTH = 32;
    localparam int ADDR_WIDTH = 11;

    logic                  clk;
    logic                  rst_n;
    
    // Port A
    logic                  we_a;
    logic [ADDR_WIDTH-1:0] addr_a;
    logic [DATA_WIDTH-1:0] din_a;
    logic [3:0]            byte_we_a;
    logic                  sram_ready_a;
    
    // Port B
    logic                  re_b;
    logic [ADDR_WIDTH-1:0] addr_b;
    logic [DATA_WIDTH-1:0] dout_b;
    logic                  sram_rvalid_b;
    logic                  sram_ready_b;
    logic                  sram_oob_err;

    int pass_count = 0;
    int fail_count = 0;

    hybrid_sram_bank #(
        .TOTAL_BYTES(TOTAL_BYTES),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .we_a(we_a),
        .addr_a(addr_a),
        .din_a(din_a),
        .byte_we_a(byte_we_a),
        .sram_ready_a(sram_ready_a),
        .re_b(re_b),
        .addr_b(addr_b),
        .dout_b(dout_b),
        .sram_rvalid_b(sram_rvalid_b),
        .sram_ready_b(sram_ready_b),
        .sram_oob_err(sram_oob_err)
    );

    // Clock generation (100MHz)
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
        // Reset and initialization
        we_a = 0; addr_a = 0; din_a = 0; byte_we_a = 0;
        re_b = 0; addr_b = 0;
        rst_n = 0;
        #(CLK_PERIOD * 2);
        rst_n = 1;
        #(CLK_PERIOD);

        $display("==================================================================");
        $display("Starting Focused Verification: hybrid_sram_bank (DEC-P2-01 Option B)");
        $display("==================================================================");

        // 1. Ready status after reset
        check_condition("SRAM-01: Flow control ready after reset", (sram_ready_a == 1'b1 && sram_ready_b == 1'b1 && sram_oob_err == 1'b0));

        // 2. First Logical Address (0) in Bank 0
        @(negedge clk);
        we_a = 1; addr_a = 11'd0; din_a = 32'hA0A0_B0B0; byte_we_a = 4'b1111;
        @(negedge clk);
        we_a = 0;
        re_b = 1; addr_b = 11'd0;
        @(negedge clk);
        check_condition("SRAM-02: Write & Read First Address 0 (Bank 0)", (dout_b == 32'hA0A0_B0B0 && sram_rvalid_b == 1'b1));
        re_b = 0;

        // 3. Last Address in Bank 0 (1023 = 11'h3FF)
        @(negedge clk);
        we_a = 1; addr_a = 11'd1023; din_a = 32'h1234_5678; byte_we_a = 4'b1111;
        @(negedge clk);
        we_a = 0;
        re_b = 1; addr_b = 11'd1023;
        @(negedge clk);
        check_condition("SRAM-03: Write & Read Last Address 1023 (Bank 0 boundary)", (dout_b == 32'h1234_5678 && sram_rvalid_b == 1'b1));
        re_b = 0;

        // 4. First Address in Bank 1 (1024 = 11'h400)
        @(negedge clk);
        we_a = 1; addr_a = 11'd1024; din_a = 32'hDEAD_BEEF; byte_we_a = 4'b1111;
        @(negedge clk);
        we_a = 0;
        re_b = 1; addr_b = 11'd1024;
        @(negedge clk);
        check_condition("SRAM-04: Write & Read First Address 1024 (Bank 1)", (dout_b == 32'hDEAD_BEEF && sram_rvalid_b == 1'b1));
        re_b = 0;

        // 5. Last Valid Logical Address (1295 = 11'd1295 = 11'h50F)
        @(negedge clk);
        we_a = 1; addr_a = 11'd1295; din_a = 32'hCAFE_BABE; byte_we_a = 4'b1111;
        @(negedge clk);
        we_a = 0;
        re_b = 1; addr_b = 11'd1295;
        @(negedge clk);
        check_condition("SRAM-05: Write & Read Last Valid Logical Address 1295 (Bank 1 ceiling)", (dout_b == 32'hCAFE_BABE && sram_rvalid_b == 1'b1));
        re_b = 0;

        // 6. Out-of-Bounds Address Request (1296) - Write Inhibit & OOB Error
        @(negedge clk);
        we_a = 1; addr_a = 11'd1296; din_a = 32'hFFFF_FFFF; byte_we_a = 4'b1111;
        @(negedge clk);
        we_a = 0;
        check_condition("SRAM-06: Out-of-bounds write (1296) asserts sram_oob_err", (sram_oob_err == 1'b1));

        // 7. Out-of-Bounds Read (1296 and 1536) returns 0 and invalid rvalid
        @(negedge clk);
        re_b = 1; addr_b = 11'd1296;
        @(negedge clk);
        check_condition("SRAM-07: Out-of-bounds read (1296) returns zero and rvalid=0", (dout_b == 32'd0 && sram_rvalid_b == 1'b0));
        addr_b = 11'd1536;
        @(negedge clk);
        check_condition("SRAM-08: Out-of-bounds read (1536) returns zero and rvalid=0", (dout_b == 32'd0 && sram_rvalid_b == 1'b0));
        re_b = 0;

        // 8. Independent Dual-Bank Simultaneous Access (Write Bank 0 while Reading Bank 1)
        @(negedge clk);
        we_a = 1; addr_a = 11'd50; din_a = 32'h1122_3344; byte_we_a = 4'b1111;
        re_b = 1; addr_b = 11'd1024; // Bank 1 was written earlier with 32'hDEAD_BEEF
        @(negedge clk);
        check_condition("SRAM-09: Concurrent Write Bank 0 & Read Bank 1", (dout_b == 32'hDEAD_BEEF));
        we_a = 0; re_b = 0;

        // Verify address 50 was written
        @(negedge clk);
        re_b = 1; addr_b = 11'd50;
        @(negedge clk);
        check_condition("SRAM-10: Verify Bank 0 address 50 was written cleanly", (dout_b == 32'h1122_3344));
        re_b = 0;

        // 9. Documented Collision Behavior: Read-Old-Data semantics
        // Address 50 currently holds 32'h1122_3344. In same cycle, write 32'h9988_7766 and read address 50.
        @(negedge clk);
        we_a = 1; addr_a = 11'd50; din_a = 32'h9988_7766; byte_we_a = 4'b1111;
        re_b = 1; addr_b = 11'd50;
        @(negedge clk);
        check_condition("SRAM-11: Read-Old-Data collision on same address (returns old 0x11223344)", (dout_b == 32'h1122_3344));
        we_a = 0; re_b = 0;

        // Next read returns the new data
        @(negedge clk);
        re_b = 1; addr_b = 11'd50;
        @(negedge clk);
        check_condition("SRAM-12: Subsequent read returns new committed data 0x99887766", (dout_b == 32'h9988_7766));
        re_b = 0;

        // 10. Byte Masked Write Verification
        @(negedge clk);
        we_a = 1; addr_a = 11'd100; din_a = 32'h0000_0000; byte_we_a = 4'b1111;
        @(negedge clk);
        // Update only byte 1 [15:8] and byte 3 [31:24]
        we_a = 1; addr_a = 11'd100; din_a = 32'hAA00_BB00; byte_we_a = 4'b1010;
        @(negedge clk);
        we_a = 0;
        re_b = 1; addr_b = 11'd100;
        @(negedge clk);
        check_condition("SRAM-13: Byte-masked write (byte_we=4'b1010) matches 0xAA00BB00", (dout_b == 32'hAA00_BB00));
        re_b = 0;

        $display("==================================================================");
        $display("SRAM Verification Summary: %0d Passed, %0d Failed", pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All SRAM Focused Tests Completed Successfully!");
            $finish(0);
        end else begin
            $display("[ERROR] Failures encountered in SRAM simulation.");
            $finish(1);
        end
    end

endmodule

