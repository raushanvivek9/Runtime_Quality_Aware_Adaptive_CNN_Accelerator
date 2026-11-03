// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-20 Memory Telemetry Microbenchmarks
// Module: tb_tsk20_memory_telemetry.sv
// Description: Synthetic microbenchmarks evaluating multi-bank SRAM subsystem
//              handshake protocol, bank contention, arbitration priorities,
//              simultaneous read/write, drain contention, and telemetry accuracy.
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk20_memory_telemetry;

    localparam int NUM_BANKS       = 8;
    localparam int BYTES_PER_BANK  = 5184;
    localparam int DATA_WIDTH      = 32;
    localparam int BANK_ADDR_W     = 11;
    localparam int GLOBAL_ADDR_W   = BANK_ADDR_W + $clog2(NUM_BANKS); // 14
    localparam int CLK_PERIOD      = 10;

    // Clock and Reset
    logic clk;
    logic rst_n;
    logic telemetry_clear;

    // Port A Write Channels
    logic [NUM_BANKS-1:0]                      wr_req;
    logic [GLOBAL_ADDR_W-1:0]                  wr_addr [0:NUM_BANKS-1];
    logic [DATA_WIDTH-1:0]                     wr_din  [0:NUM_BANKS-1];
    logic [DATA_WIDTH/8-1:0]                   wr_byte_we [0:NUM_BANKS-1];
    wire  [NUM_BANKS-1:0]                      wr_ready;
    wire  [NUM_BANKS-1:0]                      wr_ack;
    wire  [NUM_BANKS-1:0]                      wr_conflict_stall;

    // Port B Read Channels
    logic [NUM_BANKS-1:0]                      rd_req;
    logic [GLOBAL_ADDR_W-1:0]                  rd_addr [0:NUM_BANKS-1];
    wire  [NUM_BANKS-1:0]                      rd_ready;
    wire  [NUM_BANKS-1:0]                      rd_rvalid;
    wire  [DATA_WIDTH-1:0]                     rd_dout [0:NUM_BANKS-1];
    wire  [NUM_BANKS-1:0]                      rd_conflict_stall;

    // Diagnostic & Telemetry
    wire  [NUM_BANKS-1:0]                      bank_conflict_flags;
    wire  [NUM_BANKS-1:0]                      bank_oob_err;
    wire                                       oob_error_any;
    wire  [31:0]                               total_conflicts_count;
    wire  [31:0]                               total_read_accesses;
    wire  [31:0]                               total_write_accesses;

    // Telemetry Monitor Outputs
    wire  [31:0]                               mon_total_cycles;
    wire  [31:0]                               mon_idle_cycles;
    wire  [31:0]                               mon_rd_req_cycles;
    wire  [31:0]                               mon_wr_req_cycles;
    wire  [31:0]                               mon_rd_accepted_trans;
    wire  [31:0]                               mon_wr_accepted_trans;
    wire  [31:0]                               mon_rd_stall_cycles;
    wire  [31:0]                               mon_wr_stall_cycles;
    wire  [31:0]                               mon_bank_conflict_cycles;
    wire  [31:0]                               mon_total_bank_conflicts;
    wire  [31:0]                               mon_bank_rd_trans [0:NUM_BANKS-1];
    wire  [31:0]                               mon_bank_wr_trans [0:NUM_BANKS-1];
    wire  [31:0]                               mon_bank_conflicts [0:NUM_BANKS-1];
    wire  [3:0]                                mon_peak_rd_per_cycle;
    wire  [3:0]                                mon_peak_wr_per_cycle;

    // Verification bookkeeping
    int total_checks = 0;
    int passed_checks = 0;
    int failed_checks = 0;

    task check(input string desc, input bit cond);
        total_checks++;
        if (cond) begin
            passed_checks++;
        end else begin
            failed_checks++;
            $display("[FAIL] %s", desc);
        end
    endtask

    // Clock generator
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // DUT: multibank_sram_subsystem
    multibank_sram_subsystem #(
        .NUM_BANKS       (NUM_BANKS),
        .BYTES_PER_BANK  (BYTES_PER_BANK),
        .DATA_WIDTH      (DATA_WIDTH),
        .BANK_ADDR_W     (BANK_ADDR_W),
        .NUM_READ_PORTS  (NUM_BANKS),
        .NUM_WRITE_PORTS (NUM_BANKS)
    ) dut_sram (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .bank_enable           (8'hFF),
        .wr_req                (wr_req),
        .wr_addr               (wr_addr),
        .wr_din                (wr_din),
        .wr_byte_we            (wr_byte_we),
        .wr_ready              (wr_ready),
        .wr_ack                (wr_ack),
        .wr_conflict_stall     (wr_conflict_stall),
        .rd_req                (rd_req),
        .rd_addr               (rd_addr),
        .rd_ready              (rd_ready),
        .rd_rvalid             (rd_rvalid),
        .rd_dout               (rd_dout),
        .rd_conflict_stall     (rd_conflict_stall),
        .bank_conflict_flags   (bank_conflict_flags),
        .bank_oob_err          (bank_oob_err),
        .oob_error_any         (oob_error_any),
        .total_conflicts_count (total_conflicts_count),
        .total_read_accesses   (total_read_accesses),
        .total_write_accesses  (total_write_accesses)
    );

    // Telemetry Monitor
    memory_telemetry_monitor #(
        .NUM_BANKS       (NUM_BANKS),
        .BANK_ADDR_W     (BANK_ADDR_W),
        .NUM_READ_PORTS  (NUM_BANKS),
        .NUM_WRITE_PORTS (NUM_BANKS),
        .DATA_WIDTH      (DATA_WIDTH)
    ) dut_mon (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .telemetry_clear          (telemetry_clear),
        .wr_req                   (wr_req),
        .wr_addr                  (wr_addr),
        .wr_ready                 (wr_ready),
        .wr_ack                   (wr_ack),
        .wr_conflict_stall        (wr_conflict_stall),
        .rd_req                   (rd_req),
        .rd_addr                  (rd_addr),
        .rd_ready                 (rd_ready),
        .rd_rvalid                (rd_rvalid),
        .rd_conflict_stall        (rd_conflict_stall),
        .bank_conflict_flags      (bank_conflict_flags),
        .mon_total_cycles         (mon_total_cycles),
        .mon_idle_cycles          (mon_idle_cycles),
        .mon_rd_req_cycles        (mon_rd_req_cycles),
        .mon_wr_req_cycles        (mon_wr_req_cycles),
        .mon_rd_accepted_trans    (mon_rd_accepted_trans),
        .mon_wr_accepted_trans    (mon_wr_accepted_trans),
        .mon_rd_stall_cycles      (mon_rd_stall_cycles),
        .mon_wr_stall_cycles      (mon_wr_stall_cycles),
        .mon_bank_conflict_cycles (mon_bank_conflict_cycles),
        .mon_total_bank_conflicts (mon_total_bank_conflicts),
        .mon_bank_rd_trans        (mon_bank_rd_trans),
        .mon_bank_wr_trans        (mon_bank_wr_trans),
        .mon_bank_conflicts       (mon_bank_conflicts),
        .mon_peak_rd_per_cycle    (mon_peak_rd_per_cycle),
        .mon_peak_wr_per_cycle    (mon_peak_wr_per_cycle)
    );

    // Initial setup task
    task reset_system();
        rst_n           = 1'b0;
        telemetry_clear = 1'b0;
        wr_req          = '0;
        rd_req          = '0;
        for (int i = 0; i < NUM_BANKS; i++) begin
            wr_addr[i]    = '0;
            wr_din[i]     = '0;
            wr_byte_we[i] = 4'hF;
            rd_addr[i]    = '0;
        end
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // Main Test Sequence
    initial begin
        $display("================================================================================");
        $display("Starting TSK-20 Memory Telemetry Microbenchmark Verification Suite");
        $display("================================================================================");

        reset_system();

        // ---------------------------------------------------------------------
        // Scenario 1: Conflict-Free Multi-Bank Parallel Read (Bank 0..7)
        // -------------------------------------------------------------------------
        $display("[SCENARIO 1] Conflict-Free Multi-Bank Parallel Read");
        // Each read port i targets address i (Bank i)
        for (int i = 0; i < NUM_BANKS; i++) begin
            rd_req[i]  = 1'b1;
            rd_addr[i] = i; // Bank i
        end
        @(posedge clk);
        #1;
        check("S1: All 8 read ports ready", rd_ready == 8'hFF);
        check("S1: Zero read conflict stalls", rd_conflict_stall == 8'h00);
        check("S1: Zero bank conflict flags", bank_conflict_flags == 8'h00);
        check("S1: All 8 read valid responses", rd_rvalid == 8'hFF);

        rd_req = '0;
        @(posedge clk); // Deassert
        #1;
        check("S1: Telemetry accepted 8 reads", mon_rd_accepted_trans == 8);
        check("S1: Telemetry peak rd per cycle == 8", mon_peak_rd_per_cycle == 8);
        check("S1: Zero conflict cycles", mon_bank_conflict_cycles == 0);

        // ---------------------------------------------------------------------
        // Scenario 2: Severe Same-Bank Read Contention (4 ports request Bank 0)
        // ---------------------------------------------------------------------
        $display("[SCENARIO 2] Severe Same-Bank Read Contention (Ports 0..3 -> Bank 0)");
        // Ports 0, 1, 2, 3 request addresses 0, 8, 16, 24 (All Bank 0!)
        rd_req     = 8'b0000_1111;
        rd_addr[0] = 14'd0;  // Bank 0
        rd_addr[1] = 14'd8;  // Bank 0
        rd_addr[2] = 14'd16; // Bank 0
        rd_addr[3] = 14'd24; // Bank 0
        @(posedge clk);
        #1;
        // Priority arbitration grants port 0, stalls ports 1..3
        check("S2: Port 0 granted", rd_ready[0] == 1'b1 && rd_conflict_stall[0] == 1'b0);
        check("S2: Port 1 stalled", rd_ready[1] == 1'b0 && rd_conflict_stall[1] == 1'b1);
        check("S2: Port 2 stalled", rd_ready[2] == 1'b0 && rd_conflict_stall[2] == 1'b1);
        check("S2: Port 3 stalled", rd_ready[3] == 1'b0 && rd_conflict_stall[3] == 1'b1);
        check("S2: Bank 0 conflict flag asserted", bank_conflict_flags[0] == 1'b1);
        check("S2: Telemetry recorded bank conflict cycle", mon_bank_conflict_cycles == 1);
        check("S2: Telemetry recorded rd stall cycle", mon_rd_stall_cycles == 1);
        check("S2: Port 0 received valid data", rd_rvalid[0] == 1'b1);
        check("S2: Ports 1..3 no valid data", rd_rvalid[3:1] == 3'b000);

        rd_req = '0;
        @(posedge clk);
        #1;

        // ---------------------------------------------------------------------
        // Scenario 3: Simultaneous Read & Write to Independent Banks
        // ---------------------------------------------------------------------
        $display("[SCENARIO 3] Concurrent Independent Port A Write & Port B Read");
        // Port A0 writes to Bank 2 (addr 2), Port B0 reads from Bank 5 (addr 5)
        wr_req[0]     = 1'b1;
        wr_addr[0]    = 14'd2;
        wr_din[0]     = 32'hDEADBEEF;
        wr_byte_we[0] = 4'hF;

        rd_req[0]     = 1'b1;
        rd_addr[0]    = 14'd5;
        @(posedge clk);
        #1;
        check("S3: Write Port 0 ready", wr_ready[0] == 1'b1 && wr_ack[0] == 1'b1);
        check("S3: Read Port 0 ready", rd_ready[0] == 1'b1);
        check("S3: Zero conflict flags", bank_conflict_flags == 8'h00);
        check("S3: Read data valid received", rd_rvalid[0] == 1'b1);

        wr_req = '0;
        rd_req = '0;
        @(posedge clk);
        #1;
        check("S3: Telemetry wr accepted incremented", mon_wr_accepted_trans == 1);

        // ---------------------------------------------------------------------
        // Scenario 4: Write Channel Contention (Port A0 vs Port A1 -> Bank 4)
        // ---------------------------------------------------------------------
        $display("[SCENARIO 4] Write Channel Contention (Port A0 vs Port A1 -> Bank 4)");
        wr_req[0]     = 1'b1;
        wr_addr[0]    = 14'd4; // Bank 4
        wr_din[0]     = 32'h11111111;
        wr_byte_we[0] = 4'hF;

        wr_req[1]     = 1'b1;
        wr_addr[1]    = 14'd12; // Bank 4 (12 % 8 = 4)
        wr_din[1]     = 32'h22222222;
        wr_byte_we[1] = 4'hF;
        @(posedge clk);
        #1;
        check("S4: Write Port 0 granted", wr_ready[0] == 1'b1 && wr_ack[0] == 1'b1 && wr_conflict_stall[0] == 1'b0);
        check("S4: Write Port 1 stalled", wr_ready[1] == 1'b0 && wr_ack[1] == 1'b0 && wr_conflict_stall[1] == 1'b1);
        check("S4: Bank 4 conflict flag asserted", bank_conflict_flags[4] == 1'b1);
        check("S4: Telemetry recorded wr stall", mon_wr_stall_cycles == 1);

        wr_req = '0;
        @(posedge clk);

        // ---------------------------------------------------------------------
        // Scenario 5: Telemetry Clear & Reset Verification
        // ---------------------------------------------------------------------
        $display("[SCENARIO 5] Telemetry Clear Pulse");
        telemetry_clear = 1'b1;
        @(posedge clk);
        #1;
        telemetry_clear = 1'b0;
        check("S5: Telemetry reset total cycles", mon_total_cycles == 0);
        check("S5: Telemetry reset accepted rd", mon_rd_accepted_trans == 0);
        check("S5: Telemetry reset accepted wr", mon_wr_accepted_trans == 0);
        check("S5: Telemetry reset bank conflicts", mon_total_bank_conflicts == 0);

        // ---------------------------------------------------------------------
        // Scenario 6: Sparsity Sweep (Dense vs 50% vs 100% idle)
        // ---------------------------------------------------------------------
        $display("[SCENARIO 6] Telemetry Sparsity Sweep (Simulated Handshakes)");
        // Cycle 1: Dense (all 8 ports active)
        for (int i = 0; i < NUM_BANKS; i++) begin
            rd_req[i]  = 1'b1;
            rd_addr[i] = i;
        end
        @(posedge clk);

        // Cycle 2: 50% Sparse (only 4 ports active: 0, 2, 4, 6)
        rd_req = 8'b0101_0101;
        for (int i = 0; i < NUM_BANKS; i++) rd_addr[i] = i;
        @(posedge clk);

        // Cycle 3: 100% Sparse (0 ports active)
        rd_req = 8'b0000_0000;
        @(posedge clk);
        #1;

        check("S6: Total cycles monitored == 3", mon_total_cycles == 3);
        check("S6: 1 idle cycle recorded", mon_idle_cycles == 1);
        check("S6: Total reads accepted == 12", mon_rd_accepted_trans == 12);
        check("S6: Bank 0 received 2 reads", mon_bank_rd_trans[0] == 2);
        check("S6: Bank 1 received 1 read", mon_bank_rd_trans[1] == 1);

        // ---------------------------------------------------------------------
        // Final Summary
        // ---------------------------------------------------------------------
        $display("================================================================================");
        $display("TSK-20 Memory Telemetry Microbenchmark Verification Summary:");
        $display("  Total Checks : %0d", total_checks);
        $display("  Passed Checks: %0d", passed_checks);
        $display("  Failed Checks: %0d", failed_checks);
        if (failed_checks == 0) begin
            $display("  FINAL STATUS : [RESULT: SUCCESS] All TSK-20 microbenchmarks passed with zero defects!");
        end else begin
            $display("  FINAL STATUS : [RESULT: FAILURE] %0d microbenchmark checks failed!", failed_checks);
        end
        $display("================================================================================");

        $finish;
    end

endmodule
