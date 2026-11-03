// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-20 Memory Telemetry Monitor
// Module: memory_telemetry_monitor.sv
// Description: Non-invasive, synthesizable hardware telemetry monitor for
//              multi-bank SRAM subsystem. Monitors read/write channel handshakes,
//              stalls, bank conflicts, bank utilization, and bandwidth metrics.
// Baseline RTL: 100% non-invasive observation; does not modify datapath or memory.
// =============================================================================

`timescale 1ns / 1ps

`ifndef MEMORY_TELEMETRY_MONITOR_SV
`define MEMORY_TELEMETRY_MONITOR_SV

module memory_telemetry_monitor #(
    parameter int NUM_BANKS       = 8,
    parameter int BANK_ADDR_W     = 11,
    parameter int NUM_READ_PORTS  = 8,
    parameter int NUM_WRITE_PORTS = 8,
    parameter int DATA_WIDTH      = 32
)(
    input  logic                                            clk,
    input  logic                                            rst_n,
    input  logic                                            telemetry_clear,

    // Monitored Port A Write Channels (Ingestion / Writeback)
    input  logic [NUM_WRITE_PORTS-1:0]                      wr_req,
    input  logic [BANK_ADDR_W+$clog2(NUM_BANKS)-1:0]        wr_addr [0:NUM_WRITE_PORTS-1],
    input  logic [NUM_WRITE_PORTS-1:0]                      wr_ready,
    input  logic [NUM_WRITE_PORTS-1:0]                      wr_ack,
    input  logic [NUM_WRITE_PORTS-1:0]                      wr_conflict_stall,

    // Monitored Port B Read Channels (Datapath Compute Feeder)
    input  logic [NUM_READ_PORTS-1:0]                       rd_req,
    input  logic [BANK_ADDR_W+$clog2(NUM_BANKS)-1:0]        rd_addr [0:NUM_READ_PORTS-1],
    input  logic [NUM_READ_PORTS-1:0]                       rd_ready,
    input  logic [NUM_READ_PORTS-1:0]                       rd_rvalid,
    input  logic [NUM_READ_PORTS-1:0]                       rd_conflict_stall,

    // Monitored Bank Diagnostic Flags
    input  logic [NUM_BANKS-1:0]                            bank_conflict_flags,

    // -------------------------------------------------------------------------
    // Cumulative Telemetry Metrics
    // -------------------------------------------------------------------------
    output logic [31:0]                                     mon_total_cycles,
    output logic [31:0]                                     mon_idle_cycles,
    output logic [31:0]                                     mon_rd_req_cycles,
    output logic [31:0]                                     mon_wr_req_cycles,
    output logic [31:0]                                     mon_rd_accepted_trans,
    output logic [31:0]                                     mon_wr_accepted_trans,
    output logic [31:0]                                     mon_rd_stall_cycles,
    output logic [31:0]                                     mon_wr_stall_cycles,
    output logic [31:0]                                     mon_bank_conflict_cycles,
    output logic [31:0]                                     mon_total_bank_conflicts,

    // Per-Bank Metrics
    output logic [31:0]                                     mon_bank_rd_trans [0:NUM_BANKS-1],
    output logic [31:0]                                     mon_bank_wr_trans [0:NUM_BANKS-1],
    output logic [31:0]                                     mon_bank_conflicts [0:NUM_BANKS-1],

    // Peak Single-Cycle Activity Metrics
    output logic [3:0]                                      mon_peak_rd_per_cycle,
    output logic [3:0]                                      mon_peak_wr_per_cycle
);

    localparam int BANK_SEL_BITS = $clog2(NUM_BANKS);

    // Continuous Bank Address Decoding
    wire [BANK_SEL_BITS-1:0] rd_bank_sel [0:NUM_READ_PORTS-1];
    wire [BANK_SEL_BITS-1:0] wr_bank_sel [0:NUM_WRITE_PORTS-1];
    genvar g_p;
    generate
        for (g_p = 0; g_p < NUM_READ_PORTS; g_p = g_p + 1) begin : gen_rd_sel
            assign rd_bank_sel[g_p] = rd_addr[g_p][BANK_SEL_BITS-1:0];
        end
        for (g_p = 0; g_p < NUM_WRITE_PORTS; g_p = g_p + 1) begin : gen_wr_sel
            assign wr_bank_sel[g_p] = wr_addr[g_p][BANK_SEL_BITS-1:0];
        end
    endgenerate

    // Combinational cycle activity counters
    logic [3:0] rd_acc_this_cycle;
    logic [3:0] wr_acc_this_cycle;
    logic [3:0] conf_this_cycle;
    logic       any_rd_req;
    logic       any_wr_req;
    logic       any_rd_stall;
    logic       any_wr_stall;
    logic       any_conflict;
    logic [3:0] bank_rd_acc_cycle [0:NUM_BANKS-1];
    logic [3:0] bank_wr_acc_cycle [0:NUM_BANKS-1];

    always_comb begin
        rd_acc_this_cycle = '0;
        wr_acc_this_cycle = '0;
        conf_this_cycle   = '0;
        any_rd_req        = |rd_req;
        any_wr_req        = |wr_req;
        any_rd_stall      = |rd_conflict_stall;
        any_wr_stall      = |wr_conflict_stall;
        any_conflict      = |bank_conflict_flags;

        for (int r = 0; r < NUM_READ_PORTS; r = r + 1) begin
            if (rd_req[r] && rd_ready[r]) begin
                rd_acc_this_cycle = rd_acc_this_cycle + 1'b1;
            end
        end

        for (int w = 0; w < NUM_WRITE_PORTS; w = w + 1) begin
            if (wr_req[w] && wr_ready[w]) begin
                wr_acc_this_cycle = wr_acc_this_cycle + 1'b1;
            end
        end

        for (int b = 0; b < NUM_BANKS; b = b + 1) begin
            if (bank_conflict_flags[b]) begin
                conf_this_cycle = conf_this_cycle + 1'b1;
            end
        end

        for (int b = 0; b < NUM_BANKS; b = b + 1) begin
            bank_rd_acc_cycle[b] = '0;
            bank_wr_acc_cycle[b] = '0;
            for (int r = 0; r < NUM_READ_PORTS; r = r + 1) begin
                if (rd_req[r] && rd_ready[r] && (rd_bank_sel[r] == b)) begin
                    bank_rd_acc_cycle[b] = bank_rd_acc_cycle[b] + 1'b1;
                end
            end
            for (int w = 0; w < NUM_WRITE_PORTS; w = w + 1) begin
                if (wr_req[w] && wr_ready[w] && (wr_bank_sel[w] == b)) begin
                    bank_wr_acc_cycle[b] = bank_wr_acc_cycle[b] + 1'b1;
                end
            end
        end
    end

    // Sequential accumulation
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mon_total_cycles         <= '0;
            mon_idle_cycles          <= '0;
            mon_rd_req_cycles        <= '0;
            mon_wr_req_cycles        <= '0;
            mon_rd_accepted_trans    <= '0;
            mon_wr_accepted_trans    <= '0;
            mon_rd_stall_cycles      <= '0;
            mon_wr_stall_cycles      <= '0;
            mon_bank_conflict_cycles <= '0;
            mon_total_bank_conflicts <= '0;
            mon_peak_rd_per_cycle    <= '0;
            mon_peak_wr_per_cycle    <= '0;

            for (int b = 0; b < NUM_BANKS; b = b + 1) begin
                mon_bank_rd_trans[b]   <= '0;
                mon_bank_wr_trans[b]   <= '0;
                mon_bank_conflicts[b]  <= '0;
            end
        end else if (telemetry_clear) begin
            mon_total_cycles         <= '0;
            mon_idle_cycles          <= '0;
            mon_rd_req_cycles        <= '0;
            mon_wr_req_cycles        <= '0;
            mon_rd_accepted_trans    <= '0;
            mon_wr_accepted_trans    <= '0;
            mon_rd_stall_cycles      <= '0;
            mon_wr_stall_cycles      <= '0;
            mon_bank_conflict_cycles <= '0;
            mon_total_bank_conflicts <= '0;
            mon_peak_rd_per_cycle    <= '0;
            mon_peak_wr_per_cycle    <= '0;

            for (int b = 0; b < NUM_BANKS; b = b + 1) begin
                mon_bank_rd_trans[b]   <= '0;
                mon_bank_wr_trans[b]   <= '0;
                mon_bank_conflicts[b]  <= '0;
            end
        end else begin
            mon_total_cycles      <= mon_total_cycles + 1'b1;

            if (!any_rd_req && !any_wr_req) begin
                mon_idle_cycles <= mon_idle_cycles + 1'b1;
            end

            if (any_rd_req) begin
                mon_rd_req_cycles <= mon_rd_req_cycles + 1'b1;
            end

            if (any_wr_req) begin
                mon_wr_req_cycles <= mon_wr_req_cycles + 1'b1;
            end

            mon_rd_accepted_trans <= mon_rd_accepted_trans + rd_acc_this_cycle;
            mon_wr_accepted_trans <= mon_wr_accepted_trans + wr_acc_this_cycle;

            if (any_rd_stall) begin
                mon_rd_stall_cycles <= mon_rd_stall_cycles + 1'b1;
            end

            if (any_wr_stall) begin
                mon_wr_stall_cycles <= mon_wr_stall_cycles + 1'b1;
            end

            if (any_conflict) begin
                mon_bank_conflict_cycles <= mon_bank_conflict_cycles + 1'b1;
            end

            mon_total_bank_conflicts <= mon_total_bank_conflicts + conf_this_cycle;

            if (rd_acc_this_cycle > mon_peak_rd_per_cycle) begin
                mon_peak_rd_per_cycle <= rd_acc_this_cycle;
            end

            if (wr_acc_this_cycle > mon_peak_wr_per_cycle) begin
                mon_peak_wr_per_cycle <= wr_acc_this_cycle;
            end

            // Per-bank transaction tracking
            for (int b = 0; b < NUM_BANKS; b = b + 1) begin
                mon_bank_rd_trans[b] <= mon_bank_rd_trans[b] + bank_rd_acc_cycle[b];
                mon_bank_wr_trans[b] <= mon_bank_wr_trans[b] + bank_wr_acc_cycle[b];
            end

            for (int b = 0; b < NUM_BANKS; b = b + 1) begin
                if (bank_conflict_flags[b]) begin
                    mon_bank_conflicts[b] <= mon_bank_conflicts[b] + 1'b1;
                end
            end
        end
    end

endmodule

`endif // MEMORY_TELEMETRY_MONITOR_SV
