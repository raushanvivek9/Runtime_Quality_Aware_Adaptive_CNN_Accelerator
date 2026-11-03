// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-22 Power Switching Activity Generation Testbench
// Module: tb_power_switching_activity.sv
// Description: Executes representative CNN layer workloads with full VCD signal
//              dumping for dynamic power estimation and toggle rate profiling.
// =============================================================================

`timescale 1ns / 1ps

module tb_power_switching_activity;

    localparam int CLK_PERIOD       = 10;
    localparam int SRAM_GLOBAL_ADDR = 14;

    logic clk;
    logic rst_n;
    logic cfg_parallel_en;
    logic cfg_sparse_feeder_en;
    logic cfg_ofmap_drain_en;
    logic [SRAM_GLOBAL_ADDR-1:0] cfg_ofmap_base_addr;

    logic        cmd_valid;
    wire         cmd_ready;
    logic [15:0] cmd_layer_id;
    logic [1:0]  cmd_pe_mode;
    logic        cmd_adaptive_en;
    logic [31:0] cmd_degradation_hat_16;
    logic [31:0] cmd_degradation_hat_32;
    logic [31:0] cmd_degradation_hat_64;
    logic        cmd_use_ping_pong;
    logic        cmd_req_buf_id;
    logic [15:0] cmd_k_total;

    wire         layer_done_pulse;
    wire [15:0]  layer_done_id;
    wire         sequencer_busy;
    wire [3:0]   sequencer_state;
    wire         sequencer_error_flag;
    wire [3:0]   sequencer_error_code;
    logic        sequencer_error_clear;

    // Clock
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Top Module
    neural_acc_integrated_top #(
        .PARALLEL_OPERAND_MODE (1'b1),
        .OFMAP_DRAIN_ENABLE    (1'b1)
    ) dut (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .cfg_parallel_en         (cfg_parallel_en),
        .cfg_sparse_feeder_en    (cfg_sparse_feeder_en),
        .cfg_ofmap_drain_en      (cfg_ofmap_drain_en),
        .cfg_ofmap_base_addr     (cfg_ofmap_base_addr),
        .cmd_valid               (cmd_valid),
        .cmd_ready               (cmd_ready),
        .cmd_layer_id            (cmd_layer_id),
        .cmd_pe_mode             (cmd_pe_mode),
        .cmd_adaptive_en         (cmd_adaptive_en),
        .cmd_degradation_hat_16  (cmd_degradation_hat_16),
        .cmd_degradation_hat_32  (cmd_degradation_hat_32),
        .cmd_degradation_hat_64  (cmd_degradation_hat_64),
        .cmd_use_ping_pong       (cmd_use_ping_pong),
        .cmd_req_buf_id          (cmd_req_buf_id),
        .cmd_k_total             (cmd_k_total),
        .layer_done_pulse        (layer_done_pulse),
        .layer_done_id           (layer_done_id),
        .sequencer_busy          (sequencer_busy),
        .sequencer_state         (sequencer_state),
        .sequencer_error_flag    (sequencer_error_flag),
        .sequencer_error_code    (sequencer_error_code),
        .sequencer_error_clear   (sequencer_error_clear),
        .dma_start               (1'b0),
        .dma_src_addr            ('0),
        .dma_dst_addr            ('0),
        .dma_transfer_len        ('0),
        .dma_use_ping_pong       (1'b0),
        .dma_error_clear         (1'b0),
        .dma_busy                (),
        .dma_state               (),
        .dma_done_pulse          (),
        .dma_error_flag          (),
        .dma_error_code          (),
        .m_axi_araddr            (),
        .m_axi_arlen             (),
        .m_axi_arsize            (),
        .m_axi_arburst           (),
        .m_axi_arvalid           (),
        .m_axi_arready           (1'b1),
        .m_axi_rdata             ('0),
        .m_axi_rresp             ('0),
        .m_axi_rlast             (1'b0),
        .m_axi_rvalid            (1'b0),
        .m_axi_rready            (),
        .accum_out               (),
        .array_sticky_saturation (),
        .col_sticky_saturation   (),
        .active_cfg_mode         (),
        .active_pe_count         (),
        .col_active              (),
        .buf_state_a             (),
        .buf_state_b             (),
        .total_produced_count    (),
        .total_consumed_count    (),
        .ofmap_drain_busy        (),
        .ofmap_drain_done        (),
        .ofmap_error_flag        (),
        .ofmap_words_written     (),
        .telemetry_enabled_macs  (),
        .telemetry_executed_macs (),
        .telemetry_skipped_macs  (),
        .telemetry_zero_act_opportunities (),
        .telemetry_compute_cycles(),
        .telemetry_total_layer_cycles (),
        .telemetry_sram_read_reqs(),
        .telemetry_sram_read_accepted (),
        .telemetry_mem_total_cycles   (),
        .telemetry_mem_idle_cycles    (),
        .telemetry_mem_rd_req_cycles  (),
        .telemetry_mem_wr_req_cycles  (),
        .telemetry_mem_rd_accepted    (),
        .telemetry_mem_wr_accepted    (),
        .telemetry_mem_rd_stall_cycles(),
        .telemetry_mem_wr_stall_cycles(),
        .telemetry_mem_bank_conflict_cycles (),
        .telemetry_mem_total_conflicts(),
        .telemetry_bank_conflict_flags()
    );

    // VCD Dump Control
    initial begin
        $dumpfile("neural_acc_switching_activity.vcd");
        $dumpvars(0, tb_power_switching_activity.dut);
    end

    // Direct SRAM Ingestion
    task automatic write_sram(input int addr, input logic [31:0] data);
        int b_idx;
        logic [10:0] r_idx;
        b_idx = addr[2:0];
        r_idx = addr[13:3];
        if (!r_idx[10]) begin
            case (b_idx)
                0: dut.u_sram_subsystem.gen_bank[0].u_sram_bank.mem_bank0[r_idx[9:0]] = data;
                1: dut.u_sram_subsystem.gen_bank[1].u_sram_bank.mem_bank0[r_idx[9:0]] = data;
                2: dut.u_sram_subsystem.gen_bank[2].u_sram_bank.mem_bank0[r_idx[9:0]] = data;
                3: dut.u_sram_subsystem.gen_bank[3].u_sram_bank.mem_bank0[r_idx[9:0]] = data;
                4: dut.u_sram_subsystem.gen_bank[4].u_sram_bank.mem_bank0[r_idx[9:0]] = data;
                5: dut.u_sram_subsystem.gen_bank[5].u_sram_bank.mem_bank0[r_idx[9:0]] = data;
                6: dut.u_sram_subsystem.gen_bank[6].u_sram_bank.mem_bank0[r_idx[9:0]] = data;
                7: dut.u_sram_subsystem.gen_bank[7].u_sram_bank.mem_bank0[r_idx[9:0]] = data;
            endcase
        end
    endtask

    // Simulation Execution
    initial begin
        rst_n                 = 1'b0;
        cfg_parallel_en       = 1'b1;
        cfg_sparse_feeder_en  = 1'b1; // enable sparse skipping
        cfg_ofmap_drain_en    = 1'b1;
        cfg_ofmap_base_addr   = 14'h2000;
        cmd_valid             = 1'b0;
        cmd_layer_id          = 16'h8001;
        cmd_pe_mode           = 2'b10; // 64-PE
        cmd_adaptive_en       = 1'b0;
        cmd_degradation_hat_16= '0;
        cmd_degradation_hat_32= '0;
        cmd_degradation_hat_64= '0;
        cmd_use_ping_pong     = 1'b0;
        cmd_req_buf_id        = 1'b0;
        cmd_k_total           = 16'd16;
        sequencer_error_clear = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // Preload sample operands
        for (int k = 0; k < 16; k++) begin
            for (int w = 0; w < 8; w++) begin
                write_sram(k * 10 + w, 32'h0001_0002);
            end
            write_sram(k * 10 + 8, (k % 2 == 0) ? 32'h0003_0004 : 32'h0000_0000);
            write_sram(k * 10 + 9, (k % 2 == 0) ? 32'h0005_0006 : 32'h0000_0000);
        end

        // Trigger Layer
        @(negedge clk);
        cmd_valid = 1'b1;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        @(negedge clk);
        cmd_valid = 1'b0;

        // Run until completion
        while (!layer_done_pulse) @(posedge clk);
        repeat (10) @(posedge clk);

        $display("[SUCCESS] Switching activity VCD successfully generated!");
        $finish;
    end

endmodule

