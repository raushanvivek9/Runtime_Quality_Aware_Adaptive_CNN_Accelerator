// =============================================================================
// File: tb_tsk12_adaptive_experiment.sv
// Description: Comprehensive Experimental Testbench for Adaptive PE Allocation
//              Evaluation (TSK-12B).
//              Directly evaluates and compares:
//                1. Fixed 16-PE Mode (cmd_pe_mode = 2'b00, cmd_adaptive_en = 0)
//                2. Fixed 32-PE Mode (cmd_pe_mode = 2'b01, cmd_adaptive_en = 0)
//                3. Fixed 64-PE Mode (cmd_pe_mode = 2'b10, cmd_adaptive_en = 0)
//                4. Adaptive PE Mode (cmd_adaptive_en = 1, dynamic degradation)
//
//              Empirically measures:
//                - Execution Cycles: T_total, T_comp, T_drain, T_stall_feed, T_stall_drain
//                - PE Utilization: Enabled PE-cycles, Useful MAC ops, PE Efficiency
//                - Memory Behavior: SRAM Read/Write requests, Bank conflicts, Backpressure
//                - Adaptation Metrics: Resolved mode, Fallback assertions, Mode switch count
//                - Output Correctness: 64-coordinate golden comparison & zero clamping
//
//              Outputs reproducible measurements to tsk12_experiment_results.csv.
// =============================================================================

`timescale 1ns/1ps

module tb_tsk12_adaptive_experiment;

    // -------------------------------------------------------------------------
    // Architectural Parameters
    // -------------------------------------------------------------------------
    localparam int ADDR_WIDTH       = 32;
    localparam int DATA_WIDTH       = 32;
    localparam int LEN_WIDTH        = 16;
    localparam int LAYER_ID_W       = 16;
    localparam int DEGRADE_W        = 16;
    localparam int K_WIDTH          = 16;
    localparam int NUM_BANKS        = 8;
    localparam int BANK_ADDR_W      = 11;
    localparam int SRAM_GLOBAL_ADDR = 14;
    localparam int ROWS             = 4;
    localparam int COLS             = 16;
    localparam int ACT_WIDTH        = 16;
    localparam int WEIGHT_WIDTH     = 16;
    localparam int ACCUM_WIDTH      = 40;

    localparam logic [SRAM_GLOBAL_ADDR-1:0] DEFAULT_OFMAP_BASE = 14'h2000;

    // 40-bit Saturation Constants (10 hex digits = 40 bits)
    localparam logic signed [ACCUM_WIDTH-1:0] SAT_MAX_POS = 40'sh7F_FFFF_FFFF;
    localparam logic signed [ACCUM_WIDTH-1:0] SAT_MAX_NEG = -40'sh80_0000_0000;

    // -------------------------------------------------------------------------
    // Clock and Reset Signals
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;

    // 50 MHz Clock (20ns period)
    initial clk = 1'b0;
    always #10 clk = ~clk;

    // Global Cycle Counter
    longint unsigned clk_cycle;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            clk_cycle <= 0;
        else
            clk_cycle <= clk_cycle + 1;
    end

    // -------------------------------------------------------------------------
    // Top-Level Accelerator Interface Signals
    // -------------------------------------------------------------------------
    logic                                 cfg_parallel_en;
    logic                                 cfg_ofmap_drain_en;
    logic [SRAM_GLOBAL_ADDR-1:0]          cfg_ofmap_base_addr;

    logic                                 cmd_valid;
    wire                                  cmd_ready;
    logic [LAYER_ID_W-1:0]                cmd_layer_id;
    logic [1:0]                           cmd_pe_mode;
    logic                                 cmd_adaptive_en;
    logic [DEGRADE_W-1:0]                 cmd_degradation_hat_16;
    logic [DEGRADE_W-1:0]                 cmd_degradation_hat_32;
    logic [DEGRADE_W-1:0]                 cmd_degradation_hat_64;
    logic                                 cmd_use_ping_pong;
    logic                                 cmd_req_buf_id;
    logic [K_WIDTH-1:0]                   cmd_k_total;

    wire                                  layer_done_pulse;
    wire  [LAYER_ID_W-1:0]                layer_done_id;
    wire                                  sequencer_busy;
    wire  [3:0]                           sequencer_state;
    wire                                  sequencer_error_flag;
    wire  [3:0]                           sequencer_error_code;
    logic                                 sequencer_error_clear;

    logic                                 dma_start;
    logic [ADDR_WIDTH-1:0]                dma_src_addr;
    logic [ADDR_WIDTH-1:0]                dma_dst_addr;
    logic [LEN_WIDTH-1:0]                 dma_transfer_len;
    logic                                 dma_use_ping_pong;
    logic                                 dma_error_clear;
    wire                                  dma_busy;
    wire  [2:0]                           dma_state;
    wire                                  dma_done_pulse;
    wire                                  dma_error_flag;
    wire  [3:0]                           dma_error_code;

    wire  [ADDR_WIDTH-1:0]                m_axi_araddr;
    wire  [7:0]                           m_axi_arlen;
    wire  [2:0]                           m_axi_arsize;
    wire  [1:0]                           m_axi_arburst;
    wire                                  m_axi_arvalid;
    logic                                 m_axi_arready;
    logic [DATA_WIDTH-1:0]                m_axi_rdata;
    logic [1:0]                           m_axi_rresp;
    logic                                 m_axi_rlast;
    logic                                 m_axi_rvalid;
    wire                                  m_axi_rready;

    wire  [1:0]                           active_cfg_mode;
    wire  [6:0]                           active_pe_count;
    wire  [COLS-1:0]                      col_active;
    wire  [1:0]                           buf_state_a;
    wire  [1:0]                           buf_state_b;
    wire  [31:0]                          total_produced_count;
    wire  [31:0]                          total_consumed_count;
    wire signed [ACCUM_WIDTH-1:0]         accum_out [0:ROWS-1][0:COLS-1];

    wire                                  ofmap_drain_busy;
    wire                                  ofmap_drain_done;
    wire                                  ofmap_error_flag;
    wire  [7:0]                           ofmap_words_written;

    // -------------------------------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------------------------------
    neural_acc_integrated_top #(
        .ADDR_WIDTH            (ADDR_WIDTH),
        .DATA_WIDTH            (DATA_WIDTH),
        .LEN_WIDTH             (LEN_WIDTH),
        .LAYER_ID_W            (LAYER_ID_W),
        .DEGRADE_W             (DEGRADE_W),
        .K_WIDTH               (K_WIDTH),
        .FIFO_DEPTH            (16),
        .NUM_BANKS             (NUM_BANKS),
        .BYTES_PER_BANK        (5184),
        .BANK_ADDR_W           (BANK_ADDR_W),
        .SRAM_GLOBAL_ADDR      (SRAM_GLOBAL_ADDR),
        .ROWS                  (ROWS),
        .COLS                  (COLS),
        .ACT_WIDTH             (ACT_WIDTH),
        .WEIGHT_WIDTH          (WEIGHT_WIDTH),
        .ACCUM_WIDTH           (ACCUM_WIDTH),
        .PARALLEL_OPERAND_MODE (1'b1),
        .OFMAP_DRAIN_ENABLE    (1'b1),
        .DEFAULT_OFMAP_BASE    (DEFAULT_OFMAP_BASE)
    ) dut (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .cfg_parallel_en           (cfg_parallel_en),
        .cfg_ofmap_drain_en        (cfg_ofmap_drain_en),
        .cfg_ofmap_base_addr       (cfg_ofmap_base_addr),

        .cmd_valid                 (cmd_valid),
        .cmd_ready                 (cmd_ready),
        .cmd_layer_id              (cmd_layer_id),
        .cmd_pe_mode               (cmd_pe_mode),
        .cmd_adaptive_en           (cmd_adaptive_en),
        .cmd_degradation_hat_16    (cmd_degradation_hat_16),
        .cmd_degradation_hat_32    (cmd_degradation_hat_32),
        .cmd_degradation_hat_64    (cmd_degradation_hat_64),
        .cmd_use_ping_pong         (cmd_use_ping_pong),
        .cmd_req_buf_id            (cmd_req_buf_id),
        .cmd_k_total               (cmd_k_total),

        .layer_done_pulse          (layer_done_pulse),
        .layer_done_id             (layer_done_id),
        .sequencer_busy            (sequencer_busy),
        .sequencer_state           (sequencer_state),
        .sequencer_error_flag      (sequencer_error_flag),
        .sequencer_error_code      (sequencer_error_code),
        .sequencer_error_clear     (sequencer_error_clear),

        .dma_start                 (dma_start),
        .dma_src_addr              (dma_src_addr),
        .dma_dst_addr              (dma_dst_addr),
        .dma_transfer_len          (dma_transfer_len),
        .dma_use_ping_pong         (dma_use_ping_pong),
        .dma_error_clear           (dma_error_clear),
        .dma_busy                  (dma_busy),
        .dma_state                 (dma_state),
        .dma_done_pulse            (dma_done_pulse),
        .dma_error_flag            (dma_error_flag),
        .dma_error_code            (dma_error_code),

        .m_axi_araddr              (m_axi_araddr),
        .m_axi_arlen               (m_axi_arlen),
        .m_axi_arsize              (m_axi_arsize),
        .m_axi_arburst             (m_axi_arburst),
        .m_axi_arvalid             (m_axi_arvalid),
        .m_axi_arready             (m_axi_arready),
        .m_axi_rdata               (m_axi_rdata),
        .m_axi_rresp               (m_axi_rresp),
        .m_axi_rlast               (m_axi_rlast),
        .m_axi_rvalid              (m_axi_rvalid),
        .m_axi_rready              (m_axi_rready),

        .active_cfg_mode           (active_cfg_mode),
        .active_pe_count           (active_pe_count),
        .col_active                (col_active),
        .buf_state_a               (buf_state_a),
        .buf_state_b               (buf_state_b),
        .total_produced_count      (total_produced_count),
        .total_consumed_count      (total_consumed_count),
        .accum_out                 (accum_out),

        .ofmap_drain_busy          (ofmap_drain_busy),
        .ofmap_drain_done          (ofmap_drain_done),
        .ofmap_error_flag          (ofmap_error_flag),
        .ofmap_words_written       (ofmap_words_written)
    );

    // -------------------------------------------------------------------------
    // Simulated System Memory Array (AXI4 Backing Store)
    // -------------------------------------------------------------------------
    logic [31:0] sys_memory [0:8191];

    logic [31:0] axi_rd_addr_q;
    logic [7:0]  axi_rd_len_q;
    logic [7:0]  axi_rd_cnt_q;
    logic        axi_rd_active_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_arready   <= 1'b1;
            m_axi_rvalid    <= 1'b0;
            m_axi_rdata     <= '0;
            m_axi_rlast     <= 1'b0;
            m_axi_rresp     <= 2'b00;
            axi_rd_addr_q   <= '0;
            axi_rd_len_q    <= '0;
            axi_rd_cnt_q    <= '0;
            axi_rd_active_q <= 1'b0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                axi_rd_addr_q   <= m_axi_araddr;
                axi_rd_len_q    <= m_axi_arlen;
                axi_rd_cnt_q    <= '0;
                axi_rd_active_q <= 1'b1;
                m_axi_arready   <= 1'b0;
            end

            if (axi_rd_active_q) begin
                if (!m_axi_rvalid || m_axi_rready) begin
                    m_axi_rvalid <= 1'b1;
                    m_axi_rdata  <= sys_memory[(axi_rd_addr_q >> 2) + axi_rd_cnt_q];
                    m_axi_rresp  <= 2'b00;
                    if (axi_rd_cnt_q == axi_rd_len_q) begin
                        m_axi_rlast     <= 1'b1;
                        axi_rd_active_q <= 1'b0;
                        m_axi_arready   <= 1'b1;
                    end else begin
                        m_axi_rlast     <= 1'b0;
                        axi_rd_cnt_q    <= axi_rd_cnt_q + 1'b1;
                    end
                end
            end else if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                m_axi_rlast  <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Verification Scoreboard & Global Counters
    // -------------------------------------------------------------------------
    int test_count;
    int pass_count;
    int fail_count;
    int timeout_cnt;

    // Golden 40-bit Tile Buffer
    logic signed [ACCUM_WIDTH-1:0] golden_tile [0:ROWS-1][0:COLS-1];

    // CSV File Descriptors for TSK-12D-C Feeder Optimization
    int csv_fdr_fd;
    int csv_fdr_root_fd;

    // -------------------------------------------------------------------------
    // Detailed Experimental Metrics Instrumentation Registers
    // -------------------------------------------------------------------------
    logic        meas_run_active;
    longint      meas_cmd_start_cycle;
    longint      meas_cmd_handshake_cycle;
    longint      meas_comp_start_cycle_r;
    longint      meas_layer_done_cycle;
    longint      meas_comp_start_cycle;
    longint      meas_comp_done_cycle;

    int          t_total_cycles;
    int          t_comp_cycles;
    int          t_drain_cycles;
    int          t_launch_cycles;
    int          t_feeder_stall_cycles;
    int          t_drain_stall_cycles;
    int          t_total_stall_cycles;

    longint      pe_active_cycles_sum;
    int          hw_mac_enabled_events;
    int          hw_mac_skipped_events;
    int          hw_mac_executed_events;
    int          sram_rd_reqs_count;
    int          sram_rd_accepted_count;
    int          bank_conflict_cycles;
    int          sram_wr_reqs_count;
    int          sram_wr_accepted_count;
    int          useful_macs_count;
    int          mode_switch_count;
    int          fallback_count;

    // Real-time Instrumentation Accumulator
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_drain_cycles           <= 0;
            t_feeder_stall_cycles    <= 0;
            t_drain_stall_cycles     <= 0;
            pe_active_cycles_sum     <= 0;
            sram_rd_reqs_count       <= 0;
            sram_rd_accepted_count   <= 0;
            bank_conflict_cycles     <= 0;
            sram_wr_reqs_count       <= 0;
            sram_wr_accepted_count   <= 0;
            mode_switch_count        <= 0;
            fallback_count           <= 0;
            meas_cmd_handshake_cycle <= 0;
            meas_comp_start_cycle_r  <= 0;
            hw_mac_enabled_events    <= 0;
            hw_mac_skipped_events    <= 0;
            hw_mac_executed_events   <= 0;
        end else if (meas_run_active) begin
            // 1. Drain active cycles
            if (dut.ofmap_drain_busy) begin
                t_drain_cycles <= t_drain_cycles + 1;
            end

            // 2. Drain stall cycles (OFMAP request backpressured by SRAM Port 1)
            if (dut.sram_wr_req_bus[1] && !dut.sram_wr_ready_bus[1]) begin
                t_drain_stall_cycles <= t_drain_stall_cycles + 1;
            end

            // 3. Feeder stall cycles
            if (dut.u_feeder.feeder_busy) begin
                if ((dut.u_feeder.state_q == 3'd2) && !dut.u_feeder.ready_64 && (dut.active_cfg_mode == 2'b10)) begin
                    t_feeder_stall_cycles <= t_feeder_stall_cycles + 1;
                end else if ((dut.u_feeder.state_q == 3'd2) && !dut.u_feeder.ready_32 && (dut.active_cfg_mode == 2'b01)) begin
                    t_feeder_stall_cycles <= t_feeder_stall_cycles + 1;
                end else if ((dut.u_feeder.state_q == 3'd2) && !dut.u_feeder.ready_16 && (dut.active_cfg_mode == 2'b00)) begin
                    t_feeder_stall_cycles <= t_feeder_stall_cycles + 1;
                end else if ((dut.u_feeder.state_q == 3'd3) && !dut.u_feeder.act_ready) begin
                    t_feeder_stall_cycles <= t_feeder_stall_cycles + 1;
                end else if ((dut.u_feeder.state_q == 3'd4) && !dut.u_feeder.act_rvalid) begin
                    t_feeder_stall_cycles <= t_feeder_stall_cycles + 1;
                end
            end

            // Bank conflicts
            if (|dut.u_sram_subsystem.bank_conflict_flags) begin
                bank_conflict_cycles <= bank_conflict_cycles + 1;
            end

            // 4. Enabled PE-Cycles (accumulated when pe_array_enable == 1)
            if (dut.pe_array_enable) begin
                pe_active_cycles_sum <= pe_active_cycles_sum + dut.active_pe_count;
            end

            // 5. SRAM Read Requests (raw requests) & Accepted Reads
            begin : blk_rd_count
                int rd_req_sum;
                int rd_acc_sum;
                rd_req_sum = 0;
                rd_acc_sum = 0;
                for (int b = 0; b < NUM_BANKS; b++) begin
                    if (dut.sram_rd_req_bus[b]) begin
                        rd_req_sum = rd_req_sum + 1;
                        if (dut.sram_rd_ready_bus[b]) begin
                            rd_acc_sum = rd_acc_sum + 1;
                        end
                    end
                end
                sram_rd_reqs_count     <= sram_rd_reqs_count + rd_req_sum;
                sram_rd_accepted_count <= sram_rd_accepted_count + rd_acc_sum;
            end

            // 6. SRAM Write Requests (Port 1 OFMAP write strobes)
            if (dut.sram_wr_req_bus[1]) begin
                sram_wr_reqs_count <= sram_wr_reqs_count + 1;
            end

            // 7. Accepted Writes
            if (dut.sram_wr_req_bus[1] && dut.sram_wr_ready_bus[1]) begin
                sram_wr_accepted_count <= sram_wr_accepted_count + 1;
            end

            // 8. Mode changes and fallback events
            if (dut.pe_configuration_changed) begin
                mode_switch_count <= mode_switch_count + 1;
            end
            if (dut.u_pe_controller.fallback_d && dut.u_pe_controller.start_req) begin
                fallback_count <= fallback_count + 1;
            end

            // 9. Launch Latency Tracking: Synchronous clock-edge sampling
            if (cmd_valid && cmd_ready) begin
                meas_cmd_handshake_cycle <= clk_cycle;
            end
            if (dut.compute_start) begin
                meas_comp_start_cycle_r <= clk_cycle;
            end

            // 10. Direct Hardware MAC Skip-Event Instrumentation
            // Sampled strictly during active compute window when pe_array_enable == 1
            if (dut.pe_array_enable) begin : blk_mac_events
                int clk_mac_en;
                int clk_mac_skip;
                int clk_mac_exec;
                clk_mac_en   = 0;
                clk_mac_skip = 0;
                clk_mac_exec = 0;

                for (int r = 0; r < ROWS; r++) begin
                    for (int c = 0; c < COLS; c++) begin
                        if (dut.col_active[c]) begin
                            clk_mac_en = clk_mac_en + 1;
                            if (dut.u_pe_array.cycle_skipped[r][c]) begin
                                clk_mac_skip = clk_mac_skip + 1;
                            end else begin
                                clk_mac_exec = clk_mac_exec + 1;
                            end
                        end
                    end
                end

                hw_mac_enabled_events  <= hw_mac_enabled_events + clk_mac_en;
                hw_mac_skipped_events  <= hw_mac_skipped_events + clk_mac_skip;
                hw_mac_executed_events <= hw_mac_executed_events + clk_mac_exec;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Verification & Protocol Assertions
    // -------------------------------------------------------------------------
    wire [7:0] exp_drain_req_words = (dut.active_cfg_mode == 2'b00) ? 8'd32 :
                                     (dut.active_cfg_mode == 2'b01) ? 8'd64 :
                                     8'd128;

    always @(posedge clk) begin
        if (rst_n && layer_done_pulse) begin
            if (cfg_ofmap_drain_en && sram_wr_accepted_count < exp_drain_req_words) begin
                $fatal(1, "[CRITICAL PROTOCOL VIOLATION] layer_done_pulse fired before all accepted writes! accepted=%0d, expected=%0d at cycle %0d",
                         sram_wr_accepted_count, exp_drain_req_words, clk_cycle);
            end
            if (sequencer_error_flag || ofmap_error_flag) begin
                $fatal(1, "[CRITICAL PROTOCOL VIOLATION] layer_done_pulse fired while in error state! at cycle %0d", clk_cycle);
            end
        end
    end

    // Direct Physical SRAM Memory Accessor Functions
    function automatic logic [31:0] read_bank_row(input int b_idx, input logic [10:0] r_idx);
        logic [9:0] row_offset;
        row_offset = r_idx[9:0];
        if (!r_idx[10]) begin
            case (b_idx)
                0: return dut.u_sram_subsystem.gen_bank[0].u_sram_bank.mem_bank0[row_offset];
                1: return dut.u_sram_subsystem.gen_bank[1].u_sram_bank.mem_bank0[row_offset];
                2: return dut.u_sram_subsystem.gen_bank[2].u_sram_bank.mem_bank0[row_offset];
                3: return dut.u_sram_subsystem.gen_bank[3].u_sram_bank.mem_bank0[row_offset];
                4: return dut.u_sram_subsystem.gen_bank[4].u_sram_bank.mem_bank0[row_offset];
                5: return dut.u_sram_subsystem.gen_bank[5].u_sram_bank.mem_bank0[row_offset];
                6: return dut.u_sram_subsystem.gen_bank[6].u_sram_bank.mem_bank0[row_offset];
                7: return dut.u_sram_subsystem.gen_bank[7].u_sram_bank.mem_bank0[row_offset];
            endcase
        end else begin
            case (b_idx)
                0: return dut.u_sram_subsystem.gen_bank[0].u_sram_bank.mem_bank1[row_offset];
                1: return dut.u_sram_subsystem.gen_bank[1].u_sram_bank.mem_bank1[row_offset];
                2: return dut.u_sram_subsystem.gen_bank[2].u_sram_bank.mem_bank1[row_offset];
                3: return dut.u_sram_subsystem.gen_bank[3].u_sram_bank.mem_bank1[row_offset];
                4: return dut.u_sram_subsystem.gen_bank[4].u_sram_bank.mem_bank1[row_offset];
                5: return dut.u_sram_subsystem.gen_bank[5].u_sram_bank.mem_bank1[row_offset];
                6: return dut.u_sram_subsystem.gen_bank[6].u_sram_bank.mem_bank1[row_offset];
                7: return dut.u_sram_subsystem.gen_bank[7].u_sram_bank.mem_bank1[row_offset];
            endcase
        end
    endfunction

    function automatic logic [31:0] read_sram_word(input logic [SRAM_GLOBAL_ADDR-1:0] w_addr);
        return read_bank_row(w_addr[2:0], w_addr[13:3]);
    endfunction

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

    function automatic logic signed [39:0] read_sram_accum(input logic [SRAM_GLOBAL_ADDR-1:0] base, input int coord_idx);
        logic [SRAM_GLOBAL_ADDR-1:0] lo_addr, hi_addr;
        logic [31:0] lo_word, hi_word;
        lo_addr = base + (coord_idx * 2);
        hi_addr = base + (coord_idx * 2) + 1;
        lo_word = read_sram_word(lo_addr);
        hi_word = read_sram_word(hi_addr);
        return {hi_word[7:0], lo_word};
    endfunction

    // Check helper routines
    task automatic check_val(input string tag, input logic [31:0] actual, input logic [31:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%0d (0x%0h), expected=%0d (0x%0h)", tag, actual, actual, expected, expected);
            $fatal(1, "[ASSERTION FAILED] %s: actual=%0d, expected=%0d", tag, actual, expected);
        end
    endtask

    task automatic check_val40(input string tag, input logic signed [39:0] actual, input logic signed [39:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%0d (0x%0h), expected=%0d (0x%0h)", tag, actual, actual, expected, expected);
            $fatal(1, "[ASSERTION FAILED] %s: actual=%0d, expected=%0d", tag, actual, expected);
        end
    endtask

    task automatic check_bool(input string tag, input logic actual, input logic expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%b, expected=%b", tag, actual, expected);
            $fatal(1, "[ASSERTION FAILED] %s: actual=%b, expected=%b", tag, actual, expected);
        end
    endtask

    // Reset Sequence
    task automatic apply_reset();
        rst_n                  = 1'b0;
        cfg_parallel_en        = 1'b1;
        cfg_ofmap_drain_en     = 1'b1;
        cfg_ofmap_base_addr    = DEFAULT_OFMAP_BASE;
        cmd_valid              = 1'b0;
        cmd_layer_id           = '0;
        cmd_pe_mode            = 2'b10;
        cmd_adaptive_en        = 1'b0;
        cmd_degradation_hat_16 = '0;
        cmd_degradation_hat_32 = '0;
        cmd_degradation_hat_64 = '0;
        cmd_use_ping_pong      = 1'b0;
        cmd_req_buf_id         = 1'b0;
        cmd_k_total            = '0;
        sequencer_error_clear  = 1'b0;
        dma_start              = 1'b0;
        dma_src_addr           = '0;
        dma_dst_addr           = '0;
        dma_transfer_len       = '0;
        dma_use_ping_pong      = 1'b0;
        dma_error_clear        = 1'b0;
        meas_run_active        = 1'b0;

        // Clear OFMAP buffer region to clean known zero state
        for (int w = 0; w < 128; w++) begin
            write_sram_word(DEFAULT_OFMAP_BASE + w, 32'd0);
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
    endtask

    // DMA Dispatch (dst_addr is byte address in SRAM)
    task automatic start_dma(
        input logic [31:0] src,
        input logic [31:0] dst,
        input logic [15:0] len,
        input logic        use_pp
    );
        @(negedge clk);
        dma_src_addr      = src;
        dma_dst_addr      = dst;
        dma_transfer_len  = len;
        dma_use_ping_pong = use_pp;
        dma_start         = 1'b1;
        @(negedge clk);
        dma_start         = 1'b0;
    endtask

    // Wait for DMA completion
    task automatic wait_dma_done(input int max_cycles);
        timeout_cnt = 0;
        while (!dma_done_pulse && (timeout_cnt < max_cycles * 10)) begin
            @(posedge clk);
            timeout_cnt++;
        end
        if (timeout_cnt >= max_cycles * 10) begin
            $fatal(1, "[ERROR] Timeout waiting for dma_done_pulse!");
        end
    endtask

    // Issue Layer Command
    task automatic issue_cmd(
        input logic [15:0] id,
        input logic [1:0]  mode,
        input logic        adapt_en,
        input logic [15:0] d16,
        input logic [15:0] d32,
        input logic [15:0] d64,
        input logic        use_pp,
        input logic        buf_id,
        input logic [15:0] k_tot
    );
        @(negedge clk);
        cmd_valid              = 1'b1;
        cmd_layer_id           = id;
        cmd_pe_mode            = mode;
        cmd_adaptive_en        = adapt_en;
        cmd_degradation_hat_16 = d16;
        cmd_degradation_hat_32 = d32;
        cmd_degradation_hat_64 = d64;
        cmd_use_ping_pong      = use_pp;
        cmd_req_buf_id         = buf_id;
        cmd_k_total            = k_tot;
        @(negedge clk);
        cmd_valid              = 1'b0;
    endtask

    // Helper: Pack 10-Word Memory Frame for One K-Step
    task automatic pack_k_step(
        input int word_offset,
        input logic [255:0] w_packed,
        input logic [63:0]  a_packed
    );
        sys_memory[word_offset + 0] = w_packed[31:0];
        sys_memory[word_offset + 1] = w_packed[63:32];
        sys_memory[word_offset + 2] = w_packed[95:64];
        sys_memory[word_offset + 3] = w_packed[127:96];
        sys_memory[word_offset + 4] = w_packed[159:128];
        sys_memory[word_offset + 5] = w_packed[191:160];
        sys_memory[word_offset + 6] = w_packed[223:192];
        sys_memory[word_offset + 7] = w_packed[255:224];
        sys_memory[word_offset + 8] = a_packed[31:0];
        sys_memory[word_offset + 9] = a_packed[63:32];
    endtask

    // Operands storage for workload generator
    logic signed [ACT_WIDTH-1:0]    t_act [0:ROWS-1][0:31];
    logic signed [WEIGHT_WIDTH-1:0] t_wt  [0:COLS-1][0:31];

    // Compute Golden Reference and Pack AXI Memory
    task automatic generate_and_pack_operands(
        input int k_len,
        input int active_columns,
        input bit is_sparse_50
    );
        // Initialize Golden Reference Tile to Zero
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                golden_tile[r][c] = 40'sd0;
            end
        end

        useful_macs_count = 0;

        // Perform 40-bit saturating accumulation per microarchitecture specification
        for (int k = 0; k < k_len; k++) begin
            for (int r = 0; r < ROWS; r++) begin
                logic signed [15:0] a_val;
                a_val = t_act[r][k];

                for (int c = 0; c < COLS; c++) begin
                    logic signed [15:0] w_val;
                    logic signed [31:0] prod;
                    logic signed [ACCUM_WIDTH:0] next_sum;

                    w_val = t_wt[c][k];

                    // Active column accumulation with zero-bypass logic
                    if (c < active_columns) begin
                        if (a_val != 16'sd0) begin
                            useful_macs_count++;
                            prod = a_val * w_val;
                            next_sum = golden_tile[r][c] + prod;

                            // 40-bit saturation
                            if (next_sum > SAT_MAX_POS) begin
                                golden_tile[r][c] = SAT_MAX_POS;
                            end else if (next_sum < SAT_MAX_NEG) begin
                                golden_tile[r][c] = SAT_MAX_NEG;
                            end else begin
                                golden_tile[r][c] = next_sum[ACCUM_WIDTH-1:0];
                            end
                        end
                    end else begin
                        // Inactive columns strictly clamped to zero
                        golden_tile[r][c] = 40'sd0;
                    end
                end
            end
        end

        // Pack 10 words per K-step into sys_memory
        for (int k = 0; k < k_len; k++) begin
            logic [255:0] w_pack;
            logic [63:0]  a_pack;
            for (int c = 0; c < 16; c++) begin
                w_pack[c*16 +: 16] = t_wt[c][k];
            end
            for (int r = 0; r < 4; r++) begin
                a_pack[r*16 +: 16] = t_act[r][k];
            end
            pack_k_step(k * 10, w_pack, a_pack);
        end
    endtask

    // Verify OFMAP Tile from Physical SRAM Memory against Golden Reference
    task automatic verify_sram_ofmap(
        input string tag,
        input logic [SRAM_GLOBAL_ADDR-1:0] base_addr,
        input int expected_active_cols,
        input bit check_untouched
    );
        int mismatches;
        int expected_total_pes;
        int expected_total_words;
        mismatches = 0;
        expected_total_pes   = ROWS * expected_active_cols;
        expected_total_words = expected_total_pes * 2;

        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < expected_active_cols; c++) begin
                int coord;
                logic [SRAM_GLOBAL_ADDR-1:0] lo_addr, hi_addr;
                logic [31:0] lo_word, hi_word;
                logic signed [39:0] sram_accum;
                logic signed [39:0] expected_accum;
                logic [31:0] expected_hi_word;

                coord = (r * expected_active_cols) + c;
                lo_addr = base_addr + (coord * 2);
                hi_addr = base_addr + (coord * 2) + 1;
                lo_word = read_sram_word(lo_addr);
                hi_word = read_sram_word(hi_addr);
                sram_accum = {hi_word[7:0], lo_word};

                expected_accum = golden_tile[r][c];
                expected_hi_word = {{24{expected_accum[39]}}, expected_accum[39:32]};

                if (sram_accum !== expected_accum) begin
                    mismatches++;
                    if (mismatches == 1) begin
                        $display("[FIRST MISMATCH] %s at (r=%0d, c=%0d): sram_accum=%0d, expected=%0d",
                                 tag, r, c, sram_accum, expected_accum);
                    end
                end

                check_val40($sformatf("%s: SRAM accum PE[%0d][%0d]", tag, r, c), sram_accum, expected_accum);
                check_val($sformatf("%s: Low Word [31:0] PE[%0d][%0d]", tag, r, c), lo_word, expected_accum[31:0]);
                check_val($sformatf("%s: Hi Word Sign-Ext PE[%0d][%0d]", tag, r, c), hi_word, expected_hi_word);
            end
        end

        // Verify that unwritten region beyond compact tile is untouched (0)
        if (check_untouched && expected_total_words < 128) begin
            for (int w = expected_total_words; w < 128; w++) begin
                logic [31:0] unwritten_word;
                unwritten_word = read_sram_word(base_addr + w);
                check_val($sformatf("%s: Untouched word at offset %0d", tag, w), unwritten_word, 32'd0);
            end
        end

        if (mismatches == 0) begin
            $display("[PASS] %s: All %0d active coordinates in SRAM match bit-exact reference!", tag, expected_total_pes);
        end
    endtask

    // -------------------------------------------------------------------------
    // Execution Engine: Run Workload Configuration & Record Metrics
    // -------------------------------------------------------------------------
    task automatic run_experiment_run(
        input string wl_id,
        input string cfg_id,
        input int    k_len,
        input logic [1:0]  req_mode,
        input logic        adapt_en,
        input logic [15:0] d16,
        input logic [15:0] d32,
        input logic [15:0] d64,
        input logic [15:0] layer_id,
        input logic        need_reset,
        input logic        need_dma,
        input logic        induce_contention
    );
        int expected_active_cols;
        int expected_active_pes;
        int expected_resolved_mode;
        int expected_ofmap_writes;
        int expected_feeder_reads;

        // Determine expected resolved mode based on ratified adaptive policy
        if (!adapt_en) begin
            expected_resolved_mode = req_mode;
        end else begin
            if (d16 <= 16'd3277) begin
                expected_resolved_mode = 0; // 16PE
            end else if (d32 <= 16'd3277) begin
                expected_resolved_mode = 1; // 32PE
            end else begin
                expected_resolved_mode = 2; // Fallback 64PE
            end
        end

        if (expected_resolved_mode == 0) begin
            expected_active_cols  = 4;
            expected_active_pes   = 16;
            expected_ofmap_writes = 32;
            expected_feeder_reads = k_len * 4;
        end else if (expected_resolved_mode == 1) begin
            expected_active_cols  = 8;
            expected_active_pes   = 32;
            expected_ofmap_writes = 64;
            expected_feeder_reads = k_len * 6;
        end else begin
            expected_active_cols  = 16;
            expected_active_pes   = 64;
            expected_ofmap_writes = 128;
            expected_feeder_reads = k_len * 10;
        end

        if (need_reset) begin
            apply_reset();
        end

        if (need_dma) begin
            // Load operands into Buffer A (10 words * k_len * 4 bytes)
            start_dma(32'h0000_0000, 32'h0000_0000, k_len * 10 * 4, 1'b0);
            wait_dma_done(200);
            check_bool($sformatf("%s_%s: DMA completed", wl_id, cfg_id), dma_done_pulse, 1'b1);
        end

        // Clear run instrumentation registers
        t_drain_cycles           = 0;
        t_feeder_stall_cycles    = 0;
        t_drain_stall_cycles     = 0;
        pe_active_cycles_sum     = 0;
        sram_rd_reqs_count       = 0;
        sram_rd_accepted_count   = 0;
        bank_conflict_cycles     = 0;
        sram_wr_reqs_count       = 0;
        sram_wr_accepted_count   = 0;
        t_launch_cycles          = 0;
        meas_cmd_handshake_cycle = 0;
        meas_comp_start_cycle_r  = 0;
        hw_mac_enabled_events    = 0;
        hw_mac_skipped_events    = 0;
        hw_mac_executed_events   = 0;

        // Start measurement window
        meas_run_active      = 1'b1;
        meas_cmd_start_cycle = clk_cycle;

        // Dispatch layer command
        issue_cmd(layer_id, req_mode, adapt_en, d16, d32, d64, 1'b0, 1'b0, k_len);

        // Wait for compute start probe
        while (!dut.compute_start && !layer_done_pulse) @(posedge clk);
        meas_comp_start_cycle = clk_cycle;

        // Wait for compute done probe
        while (!dut.feeder_compute_done && !layer_done_pulse) @(posedge clk);
        meas_comp_done_cycle = clk_cycle;

        // If contention test is requested, launch concurrent DMA write to Bank 0
        if (induce_contention) begin
            while (!dut.ofmap_drain_busy) @(posedge clk);
            // Launch concurrent DMA to Bank 0 (byte addr 0)
            start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        end

        // Wait for layer completion pulse
        timeout_cnt = 0;
        while (!layer_done_pulse && (timeout_cnt < 2000)) begin
            @(posedge clk);
            timeout_cnt++;
        end
        if (timeout_cnt >= 2000) begin
            $fatal(1, "[ERROR] Timeout waiting for layer_done_pulse in %s_%s!", wl_id, cfg_id);
        end
        meas_layer_done_cycle = clk_cycle;
        meas_run_active       = 1'b0;

        // Finalize metric calculations
        t_total_cycles       = int'(meas_layer_done_cycle - meas_cmd_start_cycle);
        t_comp_cycles        = int'(meas_comp_done_cycle - meas_comp_start_cycle);
        t_total_stall_cycles = t_feeder_stall_cycles + t_drain_stall_cycles;
        t_launch_cycles      = int'(meas_comp_start_cycle_r - meas_cmd_handshake_cycle);

        // Verify configuration registers
        check_val($sformatf("%s_%s: Active PE count", wl_id, cfg_id), dut.active_pe_count, expected_active_pes);
        check_val($sformatf("%s_%s: Active CFG mode", wl_id, cfg_id), dut.active_cfg_mode, expected_resolved_mode);
        check_val($sformatf("%s_%s: Layer ID check", wl_id, cfg_id), layer_done_id, layer_id);
        check_val($sformatf("%s_%s: %0d OFMAP writes", wl_id, cfg_id, expected_ofmap_writes), sram_wr_accepted_count, expected_ofmap_writes);
        check_val($sformatf("%s_%s: %0d accepted feeder reads", wl_id, cfg_id, expected_feeder_reads), sram_rd_accepted_count, expected_feeder_reads);

        // Verify launch latency and hardware MAC event counts
        check_val($sformatf("%s_%s: Launch latency", wl_id, cfg_id), t_launch_cycles, 3);
        check_val($sformatf("%s_%s: HW MAC enabled events", wl_id, cfg_id), hw_mac_enabled_events, k_len * expected_active_pes);
        check_val($sformatf("%s_%s: HW MAC conservation", wl_id, cfg_id), (hw_mac_skipped_events + hw_mac_executed_events), hw_mac_enabled_events);
        check_val($sformatf("%s_%s: HW MAC executed matches useful", wl_id, cfg_id), hw_mac_executed_events, useful_macs_count);

        // Verify SRAM contents for active coordinates
        verify_sram_ofmap($sformatf("%s_%s", wl_id, cfg_id), DEFAULT_OFMAP_BASE, expected_active_cols, need_reset);

        // Display results table row
        $display("| %-5s | %-5s | K=%-2d | Res=%1d (%2d PE) | T_tot=%3d | T_cmp=%2d | T_drn=%3d | T_lnch=%1d | Stl=%2d | Rd_req=%3d | Rd_acc=%3d | Wr_req=%3d | Wr_acc=%3d | PASS |",
                 wl_id, cfg_id, k_len, expected_resolved_mode, expected_active_pes,
                 t_total_cycles, t_comp_cycles, t_drain_cycles, t_launch_cycles, t_total_stall_cycles,
                 sram_rd_reqs_count, sram_rd_accepted_count, sram_wr_reqs_count, sram_wr_accepted_count);

        // Log row to TSK-12D-C CSV file (24 columns)
        if (csv_fdr_fd != 0) begin
            $fdisplay(csv_fdr_fd, "%s,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,PASS,%0d,%0d,%0d,%0d",
                      wl_id, cfg_id, k_len, d16, d32, expected_resolved_mode, expected_active_pes,
                      t_total_cycles, t_comp_cycles, t_drain_cycles, t_total_stall_cycles,
                      t_feeder_stall_cycles, bank_conflict_cycles,
                      pe_active_cycles_sum, useful_macs_count, sram_rd_reqs_count, sram_rd_accepted_count,
                      sram_wr_reqs_count, sram_wr_accepted_count,
                      t_launch_cycles, hw_mac_enabled_events, hw_mac_skipped_events, hw_mac_executed_events);
        end
        if (csv_fdr_root_fd != 0) begin
            $fdisplay(csv_fdr_root_fd, "%s,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,PASS,%0d,%0d,%0d,%0d",
                      wl_id, cfg_id, k_len, d16, d32, expected_resolved_mode, expected_active_pes,
                      t_total_cycles, t_comp_cycles, t_drain_cycles, t_total_stall_cycles,
                      t_feeder_stall_cycles, bank_conflict_cycles,
                      pe_active_cycles_sum, useful_macs_count, sram_rd_reqs_count, sram_rd_accepted_count,
                      sram_wr_reqs_count, sram_wr_accepted_count,
                      t_launch_cycles, hw_mac_enabled_events, hw_mac_skipped_events, hw_mac_executed_events);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Test Execution Flow
    // -------------------------------------------------------------------------
    initial begin
        $display("==========================================================================================");
        $display("   TSK-12D-C: MODE-DEPENDENT OPERAND FETCHING EVALUATION TESTBENCH");
        $display("==========================================================================================");

        test_count = 0;
        pass_count = 0;
        fail_count = 0;

        // Open TSK-12D-C CSV output files (both local and root-relative)
        csv_fdr_fd = $fopen("tsk12d_feeder_optimization_results.csv", "w");
        csv_fdr_root_fd = $fopen("../tsk12d_feeder_optimization_results.csv", "w");
        if (csv_fdr_fd == 0 && csv_fdr_root_fd == 0) begin
            $fatal(1, "[ERROR] Failed to open tsk12d_feeder_optimization_results.csv for writing!");
        end

        // Write TSK-12D-C CSV Header (24 columns)
        if (csv_fdr_fd != 0) begin
            $fdisplay(csv_fdr_fd, "workload_id,config_id,k_steps,deg_hat_16,deg_hat_32,resolved_mode,active_pes,total_cycles,compute_cycles,drain_cycles,stall_cycles,feeder_stall_cycles,bank_conflict_cycles,active_pe_cycles,useful_macs,sram_rd_reqs,sram_rd_accepted,sram_wr_reqs,sram_wr_accepted,verified,t_launch_cycles,hw_mac_enabled_events,hw_mac_skipped_events,hw_mac_executed_events");
        end
        if (csv_fdr_root_fd != 0) begin
            $fdisplay(csv_fdr_root_fd, "workload_id,config_id,k_steps,deg_hat_16,deg_hat_32,resolved_mode,active_pes,total_cycles,compute_cycles,drain_cycles,stall_cycles,feeder_stall_cycles,bank_conflict_cycles,active_pe_cycles,useful_macs,sram_rd_reqs,sram_rd_accepted,sram_wr_reqs,sram_wr_accepted,verified,t_launch_cycles,hw_mac_enabled_events,hw_mac_skipped_events,hw_mac_executed_events");
        end

        $display("\n=================================================================================================================================");
        $display("| WL ID | CFG   | Reduct | Mode Resolved  | T_tot | T_cmp | T_drn | T_ln | Stl | Rd_req | Rd_acc | Wr_req | Wr_acc | Status |");
        $display("=================================================================================================================================");

        // =====================================================================
        // WORKLOAD 1: Minimal Reduction (K=1, Distinct Signed Operands)
        // =====================================================================
        // Setup K=1 distinct signed operands
        t_act[0][0] = 16'sd12;  t_act[1][0] = -16'sd7;
        t_act[2][0] = 16'sd18;  t_act[3][0] = -16'sd25;
        for (int c = 0; c < 16; c++) begin
            t_wt[c][0] = (c - 7) * 4;
        end

        // 1. Config A: Fixed 16-PE Mode
        generate_and_pack_operands(1, 4, 1'b0);
        run_experiment_run("WL-01", "CFG_A", 1, 2'b00, 1'b0, 16'd0, 16'd0, 16'd0, 16'd101, 1'b1, 1'b1, 1'b0);

        // 2. Config B: Fixed 32-PE Mode
        generate_and_pack_operands(1, 8, 1'b0);
        run_experiment_run("WL-01", "CFG_B", 1, 2'b01, 1'b0, 16'd0, 16'd0, 16'd0, 16'd102, 1'b1, 1'b1, 1'b0);

        // 3. Config C: Fixed 64-PE Mode
        generate_and_pack_operands(1, 16, 1'b0);
        run_experiment_run("WL-01", "CFG_C", 1, 2'b10, 1'b0, 16'd0, 16'd0, 16'd0, 16'd103, 1'b1, 1'b1, 1'b0);

        // 4. Config D: Adaptive PE Mode (D16=2000, D32=4000 -> Resolves to 16-PE)
        generate_and_pack_operands(1, 4, 1'b0);
        run_experiment_run("WL-01", "CFG_D", 1, 2'b10, 1'b1, 16'd2000, 16'd4000, 16'd0, 16'd104, 1'b1, 1'b1, 1'b0);

        // =====================================================================
        // WORKLOAD 2: Short Reduction (K=2, Mixed Signs)
        // =====================================================================
        t_act[0][0] = 16'sd15;  t_act[1][0] = -16'sd20; t_act[2][0] = 16'sd30;  t_act[3][0] = -16'sd10;
        t_act[0][1] = -16'sd10; t_act[1][1] = 16'sd25;  t_act[2][1] = -16'sd15; t_act[3][1] = 16'sd35;
        for (int c = 0; c < 16; c++) begin
            t_wt[c][0] = (c + 1) * 3;
            t_wt[c][1] = -(c + 2) * 2;
        end

        // 1. Config A: Fixed 16-PE Mode
        generate_and_pack_operands(2, 4, 1'b0);
        run_experiment_run("WL-02", "CFG_A", 2, 2'b00, 1'b0, 16'd0, 16'd0, 16'd0, 16'd201, 1'b1, 1'b1, 1'b0);

        // 2. Config B: Fixed 32-PE Mode
        generate_and_pack_operands(2, 8, 1'b0);
        run_experiment_run("WL-02", "CFG_B", 2, 2'b01, 1'b0, 16'd0, 16'd0, 16'd0, 16'd202, 1'b1, 1'b1, 1'b0);

        // 3. Config C: Fixed 64-PE Mode
        generate_and_pack_operands(2, 16, 1'b0);
        run_experiment_run("WL-02", "CFG_C", 2, 2'b10, 1'b0, 16'd0, 16'd0, 16'd0, 16'd203, 1'b1, 1'b1, 1'b0);

        // 4. Config D: Adaptive PE Mode (D16=4000, D32=2500 -> Resolves to 32-PE)
        generate_and_pack_operands(2, 8, 1'b0);
        run_experiment_run("WL-02", "CFG_D", 2, 2'b10, 1'b1, 16'd4000, 16'd2500, 16'd0, 16'd204, 1'b1, 1'b1, 1'b0);

        // =====================================================================
        // WORKLOAD 3: Standard Tile (K=4, Distinct Operands)
        // =====================================================================
        for (int k = 0; k < 4; k++) begin
            for (int r = 0; r < 4; r++) begin
                t_act[r][k] = (r + 1) * (k + 2) * 5 * ((r % 2 == 0) ? 1 : -1);
            end
            for (int c = 0; c < 16; c++) begin
                t_wt[c][k] = (c - 8) * (k + 1) * 3;
            end
        end

        // 1. Config A: Fixed 16-PE Mode
        generate_and_pack_operands(4, 4, 1'b0);
        run_experiment_run("WL-03", "CFG_A", 4, 2'b00, 1'b0, 16'd0, 16'd0, 16'd0, 16'd301, 1'b1, 1'b1, 1'b0);

        // 2. Config B: Fixed 32-PE Mode
        generate_and_pack_operands(4, 8, 1'b0);
        run_experiment_run("WL-03", "CFG_B", 4, 2'b01, 1'b0, 16'd0, 16'd0, 16'd0, 16'd302, 1'b1, 1'b1, 1'b0);

        // 3. Config C: Fixed 64-PE Mode
        generate_and_pack_operands(4, 16, 1'b0);
        run_experiment_run("WL-03", "CFG_C", 4, 2'b10, 1'b0, 16'd0, 16'd0, 16'd0, 16'd303, 1'b1, 1'b1, 1'b0);

        // 4. Config D: Adaptive PE Mode (D16=5000, D32=6000 -> Conservative Fallback to 64-PE)
        generate_and_pack_operands(4, 16, 1'b0);
        run_experiment_run("WL-03", "CFG_D", 4, 2'b00, 1'b1, 16'd5000, 16'd6000, 16'd0, 16'd304, 1'b1, 1'b1, 1'b0);

        // =====================================================================
        // WORKLOAD 4: Deep Accumulation (K=8, Long Reduction)
        // =====================================================================
        for (int k = 0; k < 8; k++) begin
            for (int r = 0; r < 4; r++) begin
                t_act[r][k] = (k * 7 + r * 3) - 15;
            end
            for (int c = 0; c < 16; c++) begin
                t_wt[c][k] = (c * 5 - k * 4) + 10;
            end
        end

        // 1. Config A: Fixed 16-PE Mode
        generate_and_pack_operands(8, 4, 1'b0);
        run_experiment_run("WL-04", "CFG_A", 8, 2'b00, 1'b0, 16'd0, 16'd0, 16'd0, 16'd401, 1'b1, 1'b1, 1'b0);

        // 2. Config B: Fixed 32-PE Mode
        generate_and_pack_operands(8, 8, 1'b0);
        run_experiment_run("WL-04", "CFG_B", 8, 2'b01, 1'b0, 16'd0, 16'd0, 16'd0, 16'd402, 1'b1, 1'b1, 1'b0);

        // 3. Config C: Fixed 64-PE Mode
        generate_and_pack_operands(8, 16, 1'b0);
        run_experiment_run("WL-04", "CFG_C", 8, 2'b10, 1'b0, 16'd0, 16'd0, 16'd0, 16'd403, 1'b1, 1'b1, 1'b0);

        // 4. Config D: Adaptive PE Mode (D16=1500, D32=3000 -> Resolves to 16-PE)
        generate_and_pack_operands(8, 4, 1'b0);
        run_experiment_run("WL-04", "CFG_D", 8, 2'b10, 1'b1, 16'd1500, 16'd3000, 16'd0, 16'd404, 1'b1, 1'b1, 1'b0);

        // =====================================================================
        // WORKLOAD 5: Zero-Activation Frame (50% Exact Zero Activations)
        // =====================================================================
        // Rows 1 and 3 are exact zero (0x0000), Rows 0 and 2 are active
        for (int k = 0; k < 4; k++) begin
            t_act[0][k] = 16'sd40 + k;
            t_act[1][k] = 16'sd0;   // Exact zero -> cycle_skipped
            t_act[2][k] = -16'sd30 - k;
            t_act[3][k] = 16'sd0;   // Exact zero -> cycle_skipped

            for (int c = 0; c < 16; c++) begin
                t_wt[c][k] = 16'sd20 + c;
            end
        end

        // 1. Config A: Fixed 16-PE Mode
        generate_and_pack_operands(4, 4, 1'b1);
        run_experiment_run("WL-05", "CFG_A", 4, 2'b00, 1'b0, 16'd0, 16'd0, 16'd0, 16'd501, 1'b1, 1'b1, 1'b0);

        // 2. Config B: Fixed 32-PE Mode
        generate_and_pack_operands(4, 8, 1'b1);
        run_experiment_run("WL-05", "CFG_B", 4, 2'b01, 1'b0, 16'd0, 16'd0, 16'd0, 16'd502, 1'b1, 1'b1, 1'b0);

        // 3. Config C: Fixed 64-PE Mode
        generate_and_pack_operands(4, 16, 1'b1);
        run_experiment_run("WL-05", "CFG_C", 4, 2'b10, 1'b0, 16'd0, 16'd0, 16'd0, 16'd503, 1'b1, 1'b1, 1'b0);

        // 4. Config D: Adaptive PE Mode (D16=2500 -> 16-PE)
        generate_and_pack_operands(4, 4, 1'b1);
        run_experiment_run("WL-05", "CFG_D", 4, 2'b10, 1'b1, 16'd2500, 16'd4000, 16'd0, 16'd504, 1'b1, 1'b1, 1'b0);

        // =====================================================================
        // WORKLOAD 6: Saturation Stress (Extreme Pos/Neg Boundaries)
        // =====================================================================
        for (int k = 0; k < 4; k++) begin
            t_act[0][k] = 16'sd30000;
            t_act[1][k] = 16'sd30000;
            t_act[2][k] = -16'sd30000;
            t_act[3][k] = -16'sd30000;

            for (int c = 0; c < 16; c++) begin
                t_wt[c][k] = 16'sd30000;
            end
        end

        // 1. Config A: Fixed 16-PE Mode
        generate_and_pack_operands(4, 4, 1'b0);
        run_experiment_run("WL-06", "CFG_A", 4, 2'b00, 1'b0, 16'd0, 16'd0, 16'd0, 16'd601, 1'b1, 1'b1, 1'b0);

        // 2. Config B: Fixed 32-PE Mode
        generate_and_pack_operands(4, 8, 1'b0);
        run_experiment_run("WL-06", "CFG_B", 4, 2'b01, 1'b0, 16'd0, 16'd0, 16'd0, 16'd602, 1'b1, 1'b1, 1'b0);

        // 3. Config C: Fixed 64-PE Mode
        generate_and_pack_operands(4, 16, 1'b0);
        run_experiment_run("WL-06", "CFG_C", 4, 2'b10, 1'b0, 16'd0, 16'd0, 16'd0, 16'd603, 1'b1, 1'b1, 1'b0);

        // 4. Config D: Adaptive PE Mode (D16=3100 -> 16-PE)
        generate_and_pack_operands(4, 4, 1'b0);
        run_experiment_run("WL-06", "CFG_D", 4, 2'b10, 1'b1, 16'd3100, 16'd5000, 16'd0, 16'd604, 1'b1, 1'b1, 1'b0);

        // =====================================================================
        // WORKLOAD 7: Multi-Layer Sequence (Back-to-Back Layers Without Reset)
        // =====================================================================
        $display("\n--- WORKLOAD 7: Back-to-Back Consecutive Layers (Zero Reset) ---");
        // Layer 1: 16-PE mode, K=2
        t_act[0][0] = 16'sd10; t_act[1][0] = 16'sd20; t_act[2][0] = 16'sd30; t_act[3][0] = 16'sd40;
        t_act[0][1] = 16'sd5;  t_act[1][1] = 16'sd15; t_act[2][1] = 16'sd25; t_act[3][1] = 16'sd35;
        for (int c = 0; c < 16; c++) begin
            t_wt[c][0] = 16'sd2 + c;
            t_wt[c][1] = 16'sd4 + c;
        end
        generate_and_pack_operands(2, 4, 1'b0);
        run_experiment_run("WL-07", "LAY_1", 2, 2'b00, 1'b0, 16'd0, 16'd0, 16'd0, 16'd701, 1'b1, 1'b1, 1'b0);

        // Layer 2: 32-PE mode, K=2 immediately following Layer 1 without reset!
        t_act[0][0] = -16'sd12; t_act[1][0] = 16'sd22; t_act[2][0] = -16'sd32; t_act[3][0] = 16'sd42;
        t_act[0][1] = 16'sd6;   t_act[1][1] = -16'sd16; t_act[2][1] = 16'sd26;  t_act[3][1] = -16'sd36;
        for (int c = 0; c < 16; c++) begin
            t_wt[c][0] = -(16'sd3 + c);
            t_wt[c][1] = 16'sd5 + c;
        end
        generate_and_pack_operands(2, 8, 1'b0);
        // Note: need_reset = 0! Demonstrates seamless multi-layer execution
        run_experiment_run("WL-07", "LAY_2", 2, 2'b01, 1'b0, 16'd0, 16'd0, 16'd0, 16'd702, 1'b0, 1'b1, 1'b0);

        // =====================================================================
        // WORKLOAD 8: Memory Contention & Backpressure Stress
        // =====================================================================
        $display("\n--- WORKLOAD 8: Memory Backpressure & Port 0/1 Contention ---");
        for (int r = 0; r < 4; r++) t_act[r][0] = 16'sd14 + r;
        for (int c = 0; c < 16; c++) t_wt[c][0]  = 16'sd22 + c;
        generate_and_pack_operands(1, 16, 1'b0);

        // Induce contention: concurrent DMA targeting Bank 0 while OFMAP is draining
        run_experiment_run("WL-08", "STALL", 1, 2'b10, 1'b0, 16'd0, 16'd0, 16'd0, 16'd801, 1'b1, 1'b1, 1'b1);

        // =====================================================================
        // WORKLOAD 9: Adaptive Degradation Threshold Sweep
        // =====================================================================
        $display("\n--- WORKLOAD 9: Adaptive Degradation Threshold Sweep ---");
        for (int r = 0; r < 4; r++) begin
            t_act[r][0] = 16'sd25 + r;
            t_act[r][1] = -16'sd15 - r;
        end
        for (int c = 0; c < 16; c++) begin
            t_wt[c][0] = 16'sd18 + c;
            t_wt[c][1] = -16'sd12 - c;
        end

        // Sweep Point 1: D16=2000 (<= 3277) -> Resolves to 16-PE
        generate_and_pack_operands(2, 4, 1'b0);
        run_experiment_run("WL-09", "SWP_1", 2, 2'b10, 1'b1, 16'd2000, 16'd4000, 16'd0, 16'd901, 1'b1, 1'b1, 1'b0);

        // Sweep Point 2: D16=4000 (> 3277), D32=3000 (<= 3277) -> Resolves to 32-PE
        generate_and_pack_operands(2, 8, 1'b0);
        run_experiment_run("WL-09", "SWP_2", 2, 2'b10, 1'b1, 16'd4000, 16'd3000, 16'd0, 16'd902, 1'b1, 1'b1, 1'b0);

        // Sweep Point 3: D16=4000 (> 3277), D32=5000 (> 3277) -> Resolves to 64-PE (Fallback)
        generate_and_pack_operands(2, 16, 1'b0);
        run_experiment_run("WL-09", "SWP_3", 2, 2'b10, 1'b1, 16'd4000, 16'd5000, 16'd0, 16'd903, 1'b1, 1'b1, 1'b0);

        // Sweep Point 4: Exact boundary test: D16=3277 (<= 3277) -> Resolves to 16-PE
        generate_and_pack_operands(2, 4, 1'b0);
        run_experiment_run("WL-09", "SWP_4", 2, 2'b10, 1'b1, 16'd3277, 16'd4000, 16'd0, 16'd904, 1'b1, 1'b1, 1'b0);

        // Sweep Point 5: Exact boundary test: D16=3278 (> 3277), D32=3277 (<= 3277) -> Resolves to 32-PE
        generate_and_pack_operands(2, 8, 1'b0);
        run_experiment_run("WL-09", "SWP_5", 2, 2'b10, 1'b1, 16'd3278, 16'd3277, 16'd0, 16'd905, 1'b1, 1'b1, 1'b0);

        // =====================================================================
        // WORKLOAD 10: Mode-Dependent Contention & Backpressure Stress
        // =====================================================================
        $display("\n--- WORKLOAD 10: Mode-Dependent Backpressure & Port 0/1 Contention ---");
        // 10.1: 16-PE Mode under contention (32 writes under contention)
        for (int r = 0; r < 4; r++) t_act[r][0] = 16'sd11 + r;
        for (int c = 0; c < 16; c++) t_wt[c][0]  = 16'sd21 + c;
        generate_and_pack_operands(1, 4, 1'b0);
        run_experiment_run("WL-10", "ST_16", 1, 2'b00, 1'b0, 16'd0, 16'd0, 16'd0, 16'd1001, 1'b1, 1'b1, 1'b1);

        // 10.2: 32-PE Mode under contention (64 writes under contention)
        generate_and_pack_operands(1, 8, 1'b0);
        run_experiment_run("WL-10", "ST_32", 1, 2'b01, 1'b0, 16'd0, 16'd0, 16'd0, 16'd1002, 1'b1, 1'b1, 1'b1);

        // =====================================================================
        // WORKLOAD 11: Invalid Output Base Address & Recovery Without Reset
        // =====================================================================
        $display("\n--- WORKLOAD 11: Invalid Base Address & Error Recovery Without Reset ---");
        apply_reset();
        sram_wr_accepted_count = 0;

        // Set illegal base address for 16-PE mode (10,350 + 32 = 10,382 > 10,368)
        cfg_ofmap_base_addr = 14'd10350;
        for (int r = 0; r < 4; r++) t_act[r][0] = 16'sd8;
        for (int c = 0; c < 16; c++) t_wt[c][0]  = 16'sd8;
        generate_and_pack_operands(1, 4, 1'b0);
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b0);
        wait_dma_done(100);

        issue_cmd(16'd1101, 2'b00, 1'b0, 16'd0, 16'd0, 16'd0, 1'b0, 1'b0, 16'd1);

        begin
            int err_wait;
            err_wait = 0;
            while (!sequencer_error_flag && (err_wait < 300)) begin
                @(posedge clk);
                err_wait++;
            end
            if (err_wait >= 300) begin
                $fatal(1, "[ERROR] Timeout waiting for sequencer_error_flag on invalid base address!");
            end
        end

        check_bool("WL-11_ERR: ofmap_error_flag asserted", ofmap_error_flag, 1'b1);
        check_bool("WL-11_ERR: sequencer_error_flag asserted", sequencer_error_flag, 1'b1);
        check_val("WL-11_ERR: sequencer_error_code is ERR_OFMAP_DRAIN", sequencer_error_code, 4'd5);
        check_val("WL-11_ERR: Zero SRAM writes accepted", sram_wr_accepted_count, 0);

        for (int w = 0; w < 30; w++) begin
            @(posedge clk);
            if (layer_done_pulse) begin
                $fatal(1, "[ERROR] layer_done_pulse asserted on failed command!");
            end
        end
        check_bool("WL-11_ERR: layer_done_pulse strictly suppressed", 1'b1, 1'b1);

        // Clear error via sequencer_error_clear pulse (recovery without reset)
        @(negedge clk);
        sequencer_error_clear = 1'b1;
        @(posedge clk);
        #1;
        check_bool("WL-11_RCV: Sequencer error cleared", sequencer_error_flag, 1'b0);
        check_bool("WL-11_RCV: OFMAP error cleared", ofmap_error_flag, 1'b0);
        check_bool("WL-11_RCV: cmd_ready restored", cmd_ready, 1'b1);
        @(negedge clk);
        sequencer_error_clear = 1'b0;

        // Restore legal base address and run valid 16-PE layer WITHOUT reset
        cfg_ofmap_base_addr = DEFAULT_OFMAP_BASE;
        run_experiment_run("WL-11", "RCV", 1, 2'b00, 1'b0, 16'd0, 16'd0, 16'd0, 16'd1102, 1'b0, 1'b1, 1'b0);

        // Close CSV files
        if (csv_fdr_fd != 0) $fclose(csv_fdr_fd);
        if (csv_fdr_root_fd != 0) $fclose(csv_fdr_root_fd);

        // Final Summary
        $display("\n==========================================================================================");
        $display("   TSK-12D-C EXPERIMENTAL EVALUATION COMPLETE");
        $display("   Total Checks Evaluated: %0d", test_count);
        $display("   Checks Passed:          %0d", pass_count);
        $display("   Checks Failed:          %0d", fail_count);
        $display("   CSV Export Status:      SUCCESS (tsk12d_feeder_optimization_results.csv)");
        $display("==========================================================================================");

        if (fail_count == 0) begin
            $display("[RESULT: SUCCESS] All TSK-12D-C experiments passed with zero defects!");
            $finish;
        end else begin
            $fatal(1, "[RESULT: FAILURE] %0d verification checks failed!", fail_count);
        end
    end

endmodule
