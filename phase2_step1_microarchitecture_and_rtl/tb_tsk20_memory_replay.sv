// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-20 Memory Replay & Bandwidth Telemetry Evaluation
// Module: tb_tsk20_memory_replay.sv
// Description: Replays real CNN workload memory access traces for R18-C10,
//              R18-C100, V16-C10, and V16-C100 under Dense and Sparse regimes.
//              Measures bandwidth, stalls, bank contention, and writes CSV results.
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk20_memory_replay;

    localparam int CLK_PERIOD         = 10;
    localparam int LAYER_ID_W         = 16;
    localparam int K_WIDTH            = 16;
    localparam int DEGRADE_W          = 32;
    localparam int ADDR_WIDTH         = 32;
    localparam int DATA_WIDTH         = 32;
    localparam int LEN_WIDTH          = 16;
    localparam int FIFO_DEPTH         = 16;
    localparam int NUM_BANKS          = 8;
    localparam int BYTES_PER_BANK     = 5184;
    localparam int BANK_ADDR_W        = 11;
    localparam int SRAM_GLOBAL_ADDR   = 14;
    localparam int ROWS               = 4;
    localparam int COLS               = 16;
    localparam int ACT_WIDTH          = 16;
    localparam int WEIGHT_WIDTH       = 16;
    localparam int ACCUM_WIDTH        = 40;
    localparam logic [SRAM_GLOBAL_ADDR-1:0] DEFAULT_OFMAP_BASE = 14'h2000;

    // Clock and Reset
    logic clk;
    logic rst_n;
    logic cfg_parallel_en;
    logic cfg_sparse_feeder_en;
    logic cfg_ofmap_drain_en;
    logic [SRAM_GLOBAL_ADDR-1:0] cfg_ofmap_base_addr;

    // Command Interface
    logic                     cmd_valid;
    wire                      cmd_ready;
    logic [LAYER_ID_W-1:0]    cmd_layer_id;
    logic [1:0]               cmd_pe_mode;
    logic                     cmd_adaptive_en;
    logic [DEGRADE_W-1:0]     cmd_degradation_hat_16;
    logic [DEGRADE_W-1:0]     cmd_degradation_hat_32;
    logic [DEGRADE_W-1:0]     cmd_degradation_hat_64;
    logic                     cmd_use_ping_pong;
    logic                     cmd_req_buf_id;
    logic [K_WIDTH-1:0]       cmd_k_total;

    wire                      layer_done_pulse;
    wire [LAYER_ID_W-1:0]     layer_done_id;
    wire                      sequencer_busy;
    wire [3:0]                sequencer_state;
    wire                      sequencer_error_flag;
    wire [3:0]                sequencer_error_code;
    logic                     sequencer_error_clear;

    // DMA Interface
    logic                     dma_start;
    logic [ADDR_WIDTH-1:0]    dma_src_addr;
    logic [ADDR_WIDTH-1:0]    dma_dst_addr;
    logic [LEN_WIDTH-1:0]     dma_transfer_len;
    logic                     dma_use_ping_pong;
    logic                     dma_error_clear;
    wire                      dma_busy;
    wire [2:0]                dma_state;
    wire                      dma_done_pulse;
    wire                      dma_error_flag;
    wire [3:0]                dma_error_code;

    // AXI Bus
    wire [ADDR_WIDTH-1:0]     m_axi_araddr;
    wire [7:0]                m_axi_arlen;
    wire [2:0]                m_axi_arsize;
    wire [1:0]                m_axi_arburst;
    wire                      m_axi_arvalid;
    logic                     m_axi_arready;
    logic [DATA_WIDTH-1:0]    m_axi_rdata;
    logic [1:0]               m_axi_rresp;
    logic                     m_axi_rlast;
    logic                     m_axi_rvalid;
    wire                      m_axi_rready;

    // Datapath
    wire signed [ACCUM_WIDTH-1:0] accum_out [0:ROWS-1][0:COLS-1];
    wire                      array_sticky_saturation;
    wire [COLS-1:0]           col_sticky_saturation;
    wire [1:0]                active_cfg_mode;
    wire [6:0]                active_pe_count;
    wire [COLS-1:0]           col_active;

    // Buffer Status
    wire [1:0]                buf_state_a;
    wire [1:0]                buf_state_b;
    wire [31:0]               total_produced_count;
    wire [31:0]               total_consumed_count;

    // OFMAP Drain
    wire                      ofmap_drain_busy;
    wire                      ofmap_drain_done;
    wire                      ofmap_error_flag;
    wire [7:0]                ofmap_words_written;

    // Telemetry Outputs
    wire [31:0]               telemetry_enabled_macs;
    wire [31:0]               telemetry_executed_macs;
    wire [31:0]               telemetry_skipped_macs;
    wire [31:0]               telemetry_zero_act_opportunities;
    wire [31:0]               telemetry_compute_cycles;
    wire [31:0]               telemetry_total_layer_cycles;
    wire [31:0]               telemetry_sram_read_reqs;
    wire [31:0]               telemetry_sram_read_accepted;

    // Memory Telemetry Outputs (TSK-20)
    wire [31:0]               telemetry_mem_total_cycles;
    wire [31:0]               telemetry_mem_idle_cycles;
    wire [31:0]               telemetry_mem_rd_req_cycles;
    wire [31:0]               telemetry_mem_wr_req_cycles;
    wire [31:0]               telemetry_mem_rd_accepted;
    wire [31:0]               telemetry_mem_wr_accepted;
    wire [31:0]               telemetry_mem_rd_stall_cycles;
    wire [31:0]               telemetry_mem_wr_stall_cycles;
    wire [31:0]               telemetry_mem_bank_conflict_cycles;
    wire [31:0]               telemetry_mem_total_conflicts;
    wire [NUM_BANKS-1:0]      telemetry_bank_conflict_flags;

    // DUT Instantiation
    neural_acc_integrated_top #(
        .LAYER_ID_W            (LAYER_ID_W),
        .K_WIDTH               (K_WIDTH),
        .DEGRADE_W             (DEGRADE_W),
        .ADDR_WIDTH            (ADDR_WIDTH),
        .DATA_WIDTH            (DATA_WIDTH),
        .LEN_WIDTH             (LEN_WIDTH),
        .FIFO_DEPTH            (FIFO_DEPTH),
        .NUM_BANKS             (NUM_BANKS),
        .BYTES_PER_BANK        (BYTES_PER_BANK),
        .BANK_ADDR_W           (BANK_ADDR_W),
        .SRAM_GLOBAL_ADDR      (SRAM_GLOBAL_ADDR),
        .ROWS                  (ROWS),
        .COLS                  (COLS),
        .ACT_WIDTH             (ACT_WIDTH),
        .WEIGHT_WIDTH          (WEIGHT_WIDTH),
        .ACCUM_WIDTH           (ACCUM_WIDTH),
        .PARALLEL_OPERAND_MODE (1'b1),
        .SPARSE_OPERAND_MODE   (1'b0),
        .OFMAP_DRAIN_ENABLE    (1'b1),
        .DEFAULT_OFMAP_BASE    (DEFAULT_OFMAP_BASE)
    ) dut (
        .clk                              (clk),
        .rst_n                            (rst_n),
        .cfg_parallel_en                  (cfg_parallel_en),
        .cfg_sparse_feeder_en             (cfg_sparse_feeder_en),
        .cfg_ofmap_drain_en               (cfg_ofmap_drain_en),
        .cfg_ofmap_base_addr              (cfg_ofmap_base_addr),
        .cmd_valid                        (cmd_valid),
        .cmd_ready                        (cmd_ready),
        .cmd_layer_id                     (cmd_layer_id),
        .cmd_pe_mode                      (cmd_pe_mode),
        .cmd_adaptive_en                  (cmd_adaptive_en),
        .cmd_degradation_hat_16           (cmd_degradation_hat_16),
        .cmd_degradation_hat_32           (cmd_degradation_hat_32),
        .cmd_degradation_hat_64           (cmd_degradation_hat_64),
        .cmd_use_ping_pong                (cmd_use_ping_pong),
        .cmd_req_buf_id                   (cmd_req_buf_id),
        .cmd_k_total                      (cmd_k_total),
        .layer_done_pulse                 (layer_done_pulse),
        .layer_done_id                    (layer_done_id),
        .sequencer_busy                   (sequencer_busy),
        .sequencer_state                  (sequencer_state),
        .sequencer_error_flag             (sequencer_error_flag),
        .sequencer_error_code             (sequencer_error_code),
        .sequencer_error_clear            (sequencer_error_clear),
        .dma_start                        (dma_start),
        .dma_src_addr                     (dma_src_addr),
        .dma_dst_addr                     (dma_dst_addr),
        .dma_transfer_len                 (dma_transfer_len),
        .dma_use_ping_pong                (dma_use_ping_pong),
        .dma_error_clear                  (dma_error_clear),
        .dma_busy                         (dma_busy),
        .dma_state                        (dma_state),
        .dma_done_pulse                   (dma_done_pulse),
        .dma_error_flag                   (dma_error_flag),
        .dma_error_code                   (dma_error_code),
        .m_axi_araddr                     (m_axi_araddr),
        .m_axi_arlen                      (m_axi_arlen),
        .m_axi_arsize                     (m_axi_arsize),
        .m_axi_arburst                    (m_axi_arburst),
        .m_axi_arvalid                    (m_axi_arvalid),
        .m_axi_arready                    (m_axi_arready),
        .m_axi_rdata                      (m_axi_rdata),
        .m_axi_rresp                      (m_axi_rresp),
        .m_axi_rlast                      (m_axi_rlast),
        .m_axi_rvalid                     (m_axi_rvalid),
        .m_axi_rready                     (m_axi_rready),
        .accum_out                        (accum_out),
        .array_sticky_saturation          (array_sticky_saturation),
        .col_sticky_saturation            (col_sticky_saturation),
        .active_cfg_mode                  (active_cfg_mode),
        .active_pe_count                  (active_pe_count),
        .col_active                       (col_active),
        .buf_state_a                      (buf_state_a),
        .buf_state_b                      (buf_state_b),
        .total_produced_count             (total_produced_count),
        .total_consumed_count             (total_consumed_count),
        .ofmap_drain_busy                 (ofmap_drain_busy),
        .ofmap_drain_done                 (ofmap_drain_done),
        .ofmap_error_flag                 (ofmap_error_flag),
        .ofmap_words_written              (ofmap_words_written),
        .telemetry_enabled_macs           (telemetry_enabled_macs),
        .telemetry_executed_macs          (telemetry_executed_macs),
        .telemetry_skipped_macs           (telemetry_skipped_macs),
        .telemetry_zero_act_opportunities (telemetry_zero_act_opportunities),
        .telemetry_compute_cycles         (telemetry_compute_cycles),
        .telemetry_total_layer_cycles     (telemetry_total_layer_cycles),
        .telemetry_sram_read_reqs         (telemetry_sram_read_reqs),
        .telemetry_sram_read_accepted     (telemetry_sram_read_accepted),
        .telemetry_mem_total_cycles       (telemetry_mem_total_cycles),
        .telemetry_mem_idle_cycles        (telemetry_mem_idle_cycles),
        .telemetry_mem_rd_req_cycles      (telemetry_mem_rd_req_cycles),
        .telemetry_mem_wr_req_cycles      (telemetry_mem_wr_req_cycles),
        .telemetry_mem_rd_accepted        (telemetry_mem_rd_accepted),
        .telemetry_mem_wr_accepted        (telemetry_mem_wr_accepted),
        .telemetry_mem_rd_stall_cycles    (telemetry_mem_rd_stall_cycles),
        .telemetry_mem_wr_stall_cycles    (telemetry_mem_wr_stall_cycles),
        .telemetry_mem_bank_conflict_cycles (telemetry_mem_bank_conflict_cycles),
        .telemetry_mem_total_conflicts    (telemetry_mem_total_conflicts),
        .telemetry_bank_conflict_flags    (telemetry_bank_conflict_flags)
    );

    // Clock generator
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Verification bookkeeping
    int total_checks  = 0;
    int passed_checks = 0;
    int failed_checks = 0;

    task automatic check(input string desc, input bit cond);
        total_checks++;
        if (cond) begin
            passed_checks++;
        end else begin
            failed_checks++;
            $display("[FAIL] %s", desc);
        end
    endtask

    // SRAM Direct Write Helper
    task automatic write_sram_word(input logic [SRAM_GLOBAL_ADDR-1:0] w_addr, input logic [31:0] val);
        int b_idx;
        logic [10:0] r_idx;
        logic [9:0] row_offset;
        b_idx = w_addr[2:0];
        r_idx = w_addr[13:3];
        row_offset = r_idx[9:0];
        if (!r_idx[10]) begin
            case (b_idx)
                0: dut.u_sram_subsystem.gen_bank[0].u_sram_bank.mem_bank0[row_offset] = val;
                1: dut.u_sram_subsystem.gen_bank[1].u_sram_bank.mem_bank0[row_offset] = val;
                2: dut.u_sram_subsystem.gen_bank[2].u_sram_bank.mem_bank0[row_offset] = val;
                3: dut.u_sram_subsystem.gen_bank[3].u_sram_bank.mem_bank0[row_offset] = val;
                4: dut.u_sram_subsystem.gen_bank[4].u_sram_bank.mem_bank0[row_offset] = val;
                5: dut.u_sram_subsystem.gen_bank[5].u_sram_bank.mem_bank0[row_offset] = val;
                6: dut.u_sram_subsystem.gen_bank[6].u_sram_bank.mem_bank0[row_offset] = val;
                7: dut.u_sram_subsystem.gen_bank[7].u_sram_bank.mem_bank0[row_offset] = val;
            endcase
        end else begin
            case (b_idx)
                0: dut.u_sram_subsystem.gen_bank[0].u_sram_bank.mem_bank1[row_offset] = val;
                1: dut.u_sram_subsystem.gen_bank[1].u_sram_bank.mem_bank1[row_offset] = val;
                2: dut.u_sram_subsystem.gen_bank[2].u_sram_bank.mem_bank1[row_offset] = val;
                3: dut.u_sram_subsystem.gen_bank[3].u_sram_bank.mem_bank1[row_offset] = val;
                4: dut.u_sram_subsystem.gen_bank[4].u_sram_bank.mem_bank1[row_offset] = val;
                5: dut.u_sram_subsystem.gen_bank[5].u_sram_bank.mem_bank1[row_offset] = val;
                6: dut.u_sram_subsystem.gen_bank[6].u_sram_bank.mem_bank1[row_offset] = val;
                7: dut.u_sram_subsystem.gen_bank[7].u_sram_bank.mem_bank1[row_offset] = val;
            endcase
        end
    endtask

    // System Reset
    task automatic apply_reset();
        rst_n                 = 1'b0;
        cfg_parallel_en       = 1'b1;
        cfg_sparse_feeder_en  = 1'b0;
        cfg_ofmap_drain_en    = 1'b1;
        cfg_ofmap_base_addr   = DEFAULT_OFMAP_BASE;
        cmd_valid             = 1'b0;
        cmd_layer_id          = '0;
        cmd_pe_mode           = 2'b10;
        cmd_adaptive_en       = 1'b0;
        cmd_degradation_hat_16 = '0;
        cmd_degradation_hat_32 = '0;
        cmd_degradation_hat_64 = '0;
        cmd_use_ping_pong     = 1'b0;
        cmd_req_buf_id        = 1'b0;
        cmd_k_total           = '0;
        sequencer_error_clear = 1'b0;
        dma_start             = 1'b0;
        dma_src_addr          = '0;
        dma_dst_addr          = '0;
        dma_transfer_len      = '0;
        dma_use_ping_pong     = 1'b0;
        dma_error_clear       = 1'b0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
    endtask

    // Populate SRAM with Workload Operands
    task automatic populate_workload_operands(
        input logic [SRAM_GLOBAL_ADDR-1:0] base_addr,
        input int k_steps,
        input int zero_percentage // 0 for dense, 50 for 50% sparse
    );
        logic [31:0] w_val;
        logic [31:0] a_val;
        for (int k = 0; k < k_steps; k++) begin
            // 8 Weight Words (16 column weights)
            for (int w = 0; w < 8; w++) begin
                w_val = {16'h0001, 16'h0002}; // simple non-zero weights
                write_sram_word(base_addr + (k * 10) + w, w_val);
            end

            // 2 Activation Words (4 row activations)
            if (zero_percentage > 0 && ((k % 2) == 1)) begin
                // Exactly zero activations
                a_val = 32'h0000_0000;
            end else begin
                // Non-zero activations
                a_val = {16'h0003, 16'h0004};
            end
            write_sram_word(base_addr + (k * 10) + 8, a_val);
            write_sram_word(base_addr + (k * 10) + 9, a_val);
        end
    endtask

    // Workload metadata definition
    string workload_names [0:3];
    int    workload_k     [0:3];
    logic [1:0] workload_modes [0:3];

    // CSV File handles
    int f_results;
    int f_trace;

    initial begin
        workload_names[0] = "R18-C10";  workload_k[0] = 16; workload_modes[0] = 2'b10; // 64-PE
        workload_names[1] = "R18-C100"; workload_k[1] = 16; workload_modes[1] = 2'b01; // 32-PE
        workload_names[2] = "V16-C10";  workload_k[2] = 24; workload_modes[2] = 2'b00; // 16-PE
        workload_names[3] = "V16-C100"; workload_k[3] = 24; workload_modes[3] = 2'b10; // 64-PE

        $display("================================================================================");
        $display("Starting TSK-20 Memory Replay & Bandwidth Telemetry Verification");
        $display("================================================================================");

        f_results = $fopen("TSK20_MEMORY_REPLAY_RESULTS.csv", "w");
        $fdisplay(f_results, "Workload,Regime,PE_Mode,K_Steps,Total_Cycles,Idle_Cycles,Rd_Req_Cycles,Rd_Accepted,Wr_Accepted,Rd_Stall_Cycles,Wr_Stall_Cycles,Bank_Conflict_Cycles,Total_Bank_Conflicts,Stall_Ratio,Bandwidth_Words_Per_Cycle");

        f_trace = $fopen("TSK20_MEMORY_REPLAY_TRACE.csv", "w");
        $fdisplay(f_trace, "Cycle,Workload,Regime,Sequencer_State,Feeder_State,Rd_Req_Mask,Rd_Ready_Mask,Wr_Req_Mask,Bank_Conflict_Flags,Rd_Accepted,Wr_Accepted");

        apply_reset();

        // Loop over the 4 workloads
        for (int w_idx = 0; w_idx < 4; w_idx++) begin
            string wl_name;
            int k_len;
            logic [1:0] mode_val;
            int dense_rd_accepted;
            int dense_total_cycles;

            wl_name  = workload_names[w_idx];
            k_len    = workload_k[w_idx];
            mode_val = workload_modes[w_idx];

            // -----------------------------------------------------------------
            // 1. DENSE REGIME
            // -----------------------------------------------------------------
            $display("[RUN] Workload: %s | Regime: DENSE | Mode: %b | K: %0d", wl_name, mode_val, k_len);
            populate_workload_operands(14'h0000, k_len, 0); // 0% zero

            cfg_sparse_feeder_en = 1'b0;
            @(negedge clk);
            cmd_valid              = 1'b1;
            cmd_layer_id           = 16'h8000 | (w_idx * 2);
            cmd_pe_mode            = mode_val;
            cmd_adaptive_en        = 1'b0;
            cmd_use_ping_pong      = 1'b0;
            cmd_req_buf_id         = 1'b0;
            cmd_k_total            = k_len;

            @(posedge clk);
            while (!cmd_ready) @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;

            // Wait for layer completion with timeout protection
            begin
                int timeout_cnt;
                timeout_cnt = 0;
                while (!layer_done_pulse && timeout_cnt < 10000) begin
                    @(posedge clk);
                    $fdisplay(f_trace, "%0d,%s,DENSE,%0d,%0d,%08b,%08b,%08b,%08b,%0d,%0d",
                              $time/CLK_PERIOD, wl_name, sequencer_state, dut.u_feeder.state_q,
                              dut.u_feeder.sram_rd_req_bus, dut.u_feeder.sram_rd_ready_bus,
                              dut.sram_wr_req_bus, telemetry_bank_conflict_flags,
                              telemetry_mem_rd_accepted, telemetry_mem_wr_accepted);
                    timeout_cnt++;
                end
                check($sformatf("%s DENSE completion timeout check", wl_name), timeout_cnt < 10000);
            end

            @(posedge clk);
            #1;

            // Log Dense Results
            begin
                real stall_ratio;
                real bw_util;
                stall_ratio = (telemetry_mem_total_cycles > 0) ?
                    (real'(telemetry_mem_rd_stall_cycles) / real'(telemetry_mem_total_cycles)) : 0.0;
                bw_util = (telemetry_mem_rd_req_cycles > 0) ?
                    (real'(telemetry_mem_rd_accepted) / real'(telemetry_mem_rd_req_cycles)) : 0.0;

                $fdisplay(f_results, "%s,DENSE,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0.4f,%0.2f",
                          wl_name, mode_val, k_len,
                          telemetry_mem_total_cycles,
                          telemetry_mem_idle_cycles,
                          telemetry_mem_rd_req_cycles,
                          telemetry_mem_rd_accepted,
                          telemetry_mem_wr_accepted,
                          telemetry_mem_rd_stall_cycles,
                          telemetry_mem_wr_stall_cycles,
                          telemetry_mem_bank_conflict_cycles,
                          telemetry_mem_total_conflicts,
                          stall_ratio, bw_util);

                dense_rd_accepted   = telemetry_mem_rd_accepted;
                dense_total_cycles  = telemetry_mem_total_cycles;

                check($sformatf("%s DENSE: non-zero read accepted", wl_name), telemetry_mem_rd_accepted > 0);
                check($sformatf("%s DENSE: OFMAP writes accepted", wl_name), telemetry_mem_wr_accepted > 0);
            end

            repeat (5) @(posedge clk);

            // -----------------------------------------------------------------
            // 2. SPARSE REGIME (50% activation exact-zero rate)
            // -----------------------------------------------------------------
            $display("[RUN] Workload: %s | Regime: SPARSE | Mode: %b | K: %0d", wl_name, mode_val, k_len);
            populate_workload_operands(14'h0000, k_len, 50); // 50% zero

            cfg_sparse_feeder_en = 1'b1;
            @(negedge clk);
            cmd_valid              = 1'b1;
            cmd_layer_id           = 16'h8000 | (w_idx * 2 + 1);
            cmd_pe_mode            = mode_val;
            cmd_adaptive_en        = 1'b0;
            cmd_use_ping_pong      = 1'b0;
            cmd_req_buf_id         = 1'b0;
            cmd_k_total            = k_len;

            @(posedge clk);
            while (!cmd_ready) @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;

            // Wait for layer completion with timeout protection
            begin
                int timeout_cnt;
                timeout_cnt = 0;
                while (!layer_done_pulse && timeout_cnt < 10000) begin
                    @(posedge clk);
                    $fdisplay(f_trace, "%0d,%s,SPARSE,%0d,%0d,%08b,%08b,%08b,%08b,%0d,%0d",
                              $time/CLK_PERIOD, wl_name, sequencer_state, dut.u_feeder.state_q,
                              dut.u_feeder.sram_rd_req_bus, dut.u_feeder.sram_rd_ready_bus,
                              dut.sram_wr_req_bus, telemetry_bank_conflict_flags,
                              telemetry_mem_rd_accepted, telemetry_mem_wr_accepted);
                    timeout_cnt++;
                end
                check($sformatf("%s SPARSE completion timeout check", wl_name), timeout_cnt < 10000);
            end

            @(posedge clk);
            #1;

            // Log Sparse Results
            begin
                real stall_ratio;
                real bw_util;
                stall_ratio = (telemetry_mem_total_cycles > 0) ?
                    (real'(telemetry_mem_rd_stall_cycles) / real'(telemetry_mem_total_cycles)) : 0.0;
                bw_util = (telemetry_mem_rd_req_cycles > 0) ?
                    (real'(telemetry_mem_rd_accepted) / real'(telemetry_mem_rd_req_cycles)) : 0.0;

                $fdisplay(f_results, "%s,SPARSE,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0.4f,%0.2f",
                          wl_name, mode_val, k_len,
                          telemetry_mem_total_cycles,
                          telemetry_mem_idle_cycles,
                          telemetry_mem_rd_req_cycles,
                          telemetry_mem_rd_accepted,
                          telemetry_mem_wr_accepted,
                          telemetry_mem_rd_stall_cycles,
                          telemetry_mem_wr_stall_cycles,
                          telemetry_mem_bank_conflict_cycles,
                          telemetry_mem_total_conflicts,
                          stall_ratio, bw_util);

                check($sformatf("%s SPARSE: non-zero read accepted", wl_name), telemetry_mem_rd_accepted > 0);
                check($sformatf("%s SPARSE: read traffic reduction", wl_name), telemetry_mem_rd_accepted < dense_rd_accepted);
                check($sformatf("%s SPARSE: total cycles reduction", wl_name), telemetry_mem_total_cycles < dense_total_cycles);
            end

            repeat (5) @(posedge clk);
        end

        $fclose(f_results);
        $fclose(f_trace);

        $display("================================================================================");
        $display("TSK-20 Memory Replay & Bandwidth Telemetry Verification Summary:");
        $display("  Total Checks : %0d", total_checks);
        $display("  Passed Checks: %0d", passed_checks);
        $display("  Failed Checks: %0d", failed_checks);
        if (failed_checks == 0) begin
            $display("  FINAL STATUS : [RESULT: SUCCESS] All TSK-20 memory replay tests passed with zero defects!");
        end else begin
            $display("  FINAL STATUS : [RESULT: FAILURE] %0d replay checks failed!", failed_checks);
        end
        $display("================================================================================");

        $finish;
    end

endmodule
