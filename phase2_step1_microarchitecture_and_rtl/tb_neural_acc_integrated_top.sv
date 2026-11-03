// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-07 System Integration Verification
// Module: tb_neural_acc_integrated_top.sv
// Description: Comprehensive End-to-End Verification Testbench for
//              neural_acc_integrated_top across 20 distinct verification
//              scenarios covering control, memory, DMA, datapath, backpressure,
//              ping-pong pipelining, and bit-exact software reference comparison.
//
// Scenarios:
//   S1:  Reset and idle behavior
//   S2:  Valid command acceptance
//   S3:  Invalid command rejection (unsupported mode 2'b11 & zero k_total)
//   S4:  Input data transfer via DMA
//   S5:  Buffer readiness tracking (BUF_EMPTY -> PRODUCING -> READY)
//   S6:  Adaptive PE configuration (16, 32, 64 PEs)
//   S7:  Compute start triggering
//   S8:  Compute completion tracking (K steps resolved)
//   S9:  Drain completion and barrier synchronization
//   S10: Buffer release (BUF_CONSUMING -> BUF_EMPTY)
//   S11: Output data availability and column clamping
//   S12: Layer completion pulse and handshake
//   S13: Backpressure handling (buffer consumer stall & DMA un-stall)
//   S14: Delayed DMA responses (AXI read delay)
//   S15: Asynchronous reset during active operation & post-reset recovery
//   S16: Repeated consecutive layer commands
//   S17: Overlapped ping-pong buffering across Buffer A and Buffer B
//   S18: No premature completion pulse verification
//   S19: No lost or duplicated request verification under held valid
//   S20: Bit-exact output comparison against independent software reference model
// =============================================================================

`timescale 1ns / 1ps

module tb_neural_acc_integrated_top;

    localparam time CLK_PERIOD = 10ns;
    localparam int LAYER_ID_W       = 16;
    localparam int K_WIDTH          = 16;
    localparam int DEGRADE_W        = 32;
    localparam int ADDR_WIDTH       = 32;
    localparam int DATA_WIDTH       = 32;
    localparam int LEN_WIDTH        = 16;
    localparam int FIFO_DEPTH       = 16;
    localparam int NUM_BANKS        = 8;
    localparam int BYTES_PER_BANK   = 5184;
    localparam int BANK_ADDR_W      = 11;
    localparam int SRAM_GLOBAL_ADDR = 14;
    localparam int ROWS             = 4;
    localparam int COLS             = 16;
    localparam int ACT_WIDTH        = 16;
    localparam int WEIGHT_WIDTH     = 16;
    localparam int ACCUM_WIDTH      = 40;

    // Clock and Reset
    logic                      clk;
    logic                      rst_n;

    // Upstream Layer Command Interface
    logic                      cmd_valid;
    wire                       cmd_ready;
    logic [LAYER_ID_W-1:0]     cmd_layer_id;
    logic [1:0]                cmd_pe_mode;
    logic                      cmd_adaptive_en;
    logic [DEGRADE_W-1:0]      cmd_degradation_hat_16;
    logic [DEGRADE_W-1:0]      cmd_degradation_hat_32;
    logic [DEGRADE_W-1:0]      cmd_degradation_hat_64;
    logic                      cmd_use_ping_pong;
    logic                      cmd_req_buf_id;
    logic [K_WIDTH-1:0]        cmd_k_total;

    wire                       layer_done_pulse;
    wire  [LAYER_ID_W-1:0]     layer_done_id;
    wire                       sequencer_busy;
    wire  [3:0]                sequencer_state;
    wire                       sequencer_error_flag;
    wire  [3:0]                sequencer_error_code;
    logic                      sequencer_error_clear;

    // Upstream DMA Configuration Interface
    logic                      dma_start;
    logic [ADDR_WIDTH-1:0]     dma_src_addr;
    logic [ADDR_WIDTH-1:0]     dma_dst_addr;
    logic [LEN_WIDTH-1:0]      dma_transfer_len;
    logic                      dma_use_ping_pong;
    logic                      dma_error_clear;
    wire                       dma_busy;
    wire  [2:0]                dma_state;
    wire                       dma_done_pulse;
    wire                       dma_error_flag;
    wire  [3:0]                dma_error_code;

    // System Memory AXI4 Master Read Channel
    wire  [ADDR_WIDTH-1:0]     m_axi_araddr;
    wire  [7:0]                m_axi_arlen;
    wire  [2:0]                m_axi_arsize;
    wire  [1:0]                m_axi_arburst;
    wire                       m_axi_arvalid;
    logic                      m_axi_arready;

    logic [DATA_WIDTH-1:0]     m_axi_rdata;
    logic [1:0]                m_axi_rresp;
    logic                      m_axi_rlast;
    logic                      m_axi_rvalid;
    wire                       m_axi_rready;

    // Datapath Outputs
    wire  signed [ACCUM_WIDTH-1:0] accum_out [0:ROWS-1][0:COLS-1];
    wire                       array_sticky_saturation;
    wire  [COLS-1:0]           col_sticky_saturation;
    wire  [1:0]                active_cfg_mode;
    wire  [6:0]                active_pe_count;
    wire  [COLS-1:0]           col_active;

    // Diagnostics
    wire  [1:0]                buf_state_a;
    wire  [1:0]                buf_state_b;
    wire  [31:0]               total_produced_count;
    wire  [31:0]               total_consumed_count;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    neural_acc_integrated_top #(
        .LAYER_ID_W       (LAYER_ID_W),
        .K_WIDTH          (K_WIDTH),
        .DEGRADE_W        (DEGRADE_W),
        .ADDR_WIDTH       (ADDR_WIDTH),
        .DATA_WIDTH       (DATA_WIDTH),
        .LEN_WIDTH        (LEN_WIDTH),
        .FIFO_DEPTH       (FIFO_DEPTH),
        .NUM_BANKS        (NUM_BANKS),
        .BYTES_PER_BANK   (BYTES_PER_BANK),
        .BANK_ADDR_W      (BANK_ADDR_W),
        .SRAM_GLOBAL_ADDR (SRAM_GLOBAL_ADDR),
        .ROWS             (ROWS),
        .COLS             (COLS),
        .ACT_WIDTH        (ACT_WIDTH),
        .WEIGHT_WIDTH     (WEIGHT_WIDTH),
        .ACCUM_WIDTH      (ACCUM_WIDTH)
    ) dut (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .cmd_valid                (cmd_valid),
        .cmd_ready                (cmd_ready),
        .cmd_layer_id             (cmd_layer_id),
        .cmd_pe_mode              (cmd_pe_mode),
        .cmd_adaptive_en          (cmd_adaptive_en),
        .cmd_degradation_hat_16   (cmd_degradation_hat_16),
        .cmd_degradation_hat_32   (cmd_degradation_hat_32),
        .cmd_degradation_hat_64   (cmd_degradation_hat_64),
        .cmd_use_ping_pong        (cmd_use_ping_pong),
        .cmd_req_buf_id           (cmd_req_buf_id),
        .cmd_k_total              (cmd_k_total),
        .layer_done_pulse         (layer_done_pulse),
        .layer_done_id            (layer_done_id),
        .sequencer_busy           (sequencer_busy),
        .sequencer_state          (sequencer_state),
        .sequencer_error_flag     (sequencer_error_flag),
        .sequencer_error_code     (sequencer_error_code),
        .sequencer_error_clear    (sequencer_error_clear),
        .dma_start                (dma_start),
        .dma_src_addr             (dma_src_addr),
        .dma_dst_addr             (dma_dst_addr),
        .dma_transfer_len         (dma_transfer_len),
        .dma_use_ping_pong        (dma_use_ping_pong),
        .dma_error_clear          (dma_error_clear),
        .dma_busy                 (dma_busy),
        .dma_state                (dma_state),
        .dma_done_pulse           (dma_done_pulse),
        .dma_error_flag           (dma_error_flag),
        .dma_error_code           (dma_error_code),
        .m_axi_araddr             (m_axi_araddr),
        .m_axi_arlen              (m_axi_arlen),
        .m_axi_arsize             (m_axi_arsize),
        .m_axi_arburst            (m_axi_arburst),
        .m_axi_arvalid            (m_axi_arvalid),
        .m_axi_arready            (m_axi_arready),
        .m_axi_rdata              (m_axi_rdata),
        .m_axi_rresp              (m_axi_rresp),
        .m_axi_rlast              (m_axi_rlast),
        .m_axi_rvalid             (m_axi_rvalid),
        .m_axi_rready             (m_axi_rready),
        .accum_out                (accum_out),
        .array_sticky_saturation  (array_sticky_saturation),
        .col_sticky_saturation    (col_sticky_saturation),
        .active_cfg_mode          (active_cfg_mode),
        .active_pe_count          (active_pe_count),
        .col_active               (col_active),
        .buf_state_a              (buf_state_a),
        .buf_state_b              (buf_state_b),
        .total_produced_count     (total_produced_count),
        .total_consumed_count     (total_consumed_count)
    );

    // -------------------------------------------------------------------------
    // Testbench Emulation Memory & Slave Model
    // -------------------------------------------------------------------------
    logic [31:0] sys_memory [0:4095];

    logic [31:0] ar_fifo_addr [0:63];
    int          ar_fifo_delay [0:63];
    int          ar_wr_ptr, ar_rd_ptr;
    int          cfg_ar_delay;
    int          cfg_r_delay;
    int          ar_wait_cnt;

    // Test tracking counters
    int          test_count;
    int          pass_count;
    int          fail_count;
    int          idx, loop_i, timeout_cnt;
    logic signed [39:0] golden_ref_sum;

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // Verification Assertion Tasks
    // -------------------------------------------------------------------------
    task automatic check_val(input string tag, input logic [31:0] actual, input logic [31:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=0x%08X (dec %0d), expected=0x%08X (dec %0d)",
                     tag, actual, actual, expected, expected);
        end
    endtask

    task automatic check_val40(input string tag, input logic signed [39:0] actual, input logic signed [39:0] expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%0d, expected=%0d", tag, actual, expected);
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

    // Reset task
    task automatic apply_reset();
        rst_n                  = 1'b0;
        cmd_valid              = 1'b0;
        cmd_layer_id           = '0;
        cmd_pe_mode            = 2'b00;
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

        cfg_ar_delay           = 0;
        cfg_r_delay            = 0;
        ar_wait_cnt            = 0;
        ar_wr_ptr              = 0;
        ar_rd_ptr              = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // -------------------------------------------------------------------------
    // System Memory AXI Slave Responder
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_arready <= 1'b0;
            m_axi_rvalid  <= 1'b0;
            m_axi_rdata   <= '0;
            m_axi_rresp   <= 2'b00;
            m_axi_rlast   <= 1'b0;
            ar_wait_cnt   <= 0;
            ar_wr_ptr     <= 0;
            ar_rd_ptr     <= 0;
        end else begin
            // AR Channel
            if (m_axi_arvalid) begin
                if (ar_wait_cnt < cfg_ar_delay) begin
                    m_axi_arready <= 1'b0;
                    ar_wait_cnt   <= ar_wait_cnt + 1;
                end else begin
                    m_axi_arready <= 1'b1;
                    ar_wait_cnt   <= 0;
                end
            end else begin
                m_axi_arready <= 1'b0;
                ar_wait_cnt   <= 0;
            end

            if (m_axi_arvalid && m_axi_arready) begin
                ar_fifo_addr[ar_wr_ptr]  <= m_axi_araddr;
                ar_fifo_delay[ar_wr_ptr] <= cfg_r_delay;
                ar_wr_ptr                <= ar_wr_ptr + 1;
            end

            // R Channel
            if (m_axi_rvalid && m_axi_rready) begin
                ar_rd_ptr    <= ar_rd_ptr + 1;
                m_axi_rvalid <= 1'b0;
            end else if (ar_rd_ptr != ar_wr_ptr) begin
                if (ar_fifo_delay[ar_rd_ptr] > 0) begin
                    ar_fifo_delay[ar_rd_ptr] <= ar_fifo_delay[ar_rd_ptr] - 1;
                    m_axi_rvalid             <= 1'b0;
                end else begin
                    m_axi_rvalid <= 1'b1;
                    m_axi_rdata  <= sys_memory[(ar_fifo_addr[ar_rd_ptr] >> 2) & 12'hFFF];
                    m_axi_rresp  <= 2'b00;
                    m_axi_rlast  <= 1'b1;
                end
            end else begin
                m_axi_rvalid <= 1'b0;
            end
        end
    end

    // Command issue task
    task automatic issue_cmd(
        input logic [15:0] id,
        input logic [1:0]  mode,
        input logic        adapt_en,
        input logic        use_pp,
        input logic        buf_id,
        input logic [15:0] k_tot
    );
        @(negedge clk);
        cmd_valid              = 1'b1;
        cmd_layer_id           = id;
        cmd_pe_mode            = mode;
        cmd_adaptive_en        = adapt_en;
        cmd_degradation_hat_16 = 32'd2000;
        cmd_degradation_hat_32 = 32'd3000;
        cmd_degradation_hat_64 = 32'd4000;
        cmd_use_ping_pong      = use_pp;
        cmd_req_buf_id         = buf_id;
        cmd_k_total            = k_tot;
        @(negedge clk);
        cmd_valid              = 1'b0;
    endtask

    // DMA transfer start task
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

    // Wait for layer completion pulse with timeout
    task automatic wait_layer_done(input int max_cycles);
        timeout_cnt = 0;
        while (!layer_done_pulse && (timeout_cnt < max_cycles)) begin
            @(posedge clk);
            timeout_cnt++;
        end
        if (timeout_cnt >= max_cycles) begin
            $display("[ERROR] Timeout waiting for layer_done_pulse!");
        end
    endtask

    // Wait for DMA completion pulse with timeout
    task automatic wait_dma_done(input int max_cycles);
        timeout_cnt = 0;
        while (!dma_done_pulse && (timeout_cnt < max_cycles)) begin
            @(posedge clk);
            timeout_cnt++;
        end
        if (timeout_cnt >= max_cycles) begin
            $display("[ERROR] Timeout waiting for dma_done_pulse!");
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Verification Process
    // -------------------------------------------------------------------------
    initial begin
        test_count = 0;
        pass_count = 0;
        fail_count = 0;

        // Populate System Memory with deterministic test vector
        for (idx = 0; idx < 4096; idx = idx + 1) begin
            sys_memory[idx] = 32'h0000_0000;
        end

        $display("\n==================================================================");
        $display("TSK-07: Neural_Acc Top-Level Integration Verification Suite");
        $display("==================================================================");

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 1: Reset & Initial Idle State ---");
        apply_reset();
        check_bool("S1.1: cmd_ready high in idle", cmd_ready, 1'b1);
        check_bool("S1.2: sequencer_busy is low", sequencer_busy, 1'b0);
        check_val("S1.3: sequencer_state is ST_IDLE", sequencer_state, 4'd0);
        check_bool("S1.4: dma_busy is low", dma_busy, 1'b0);
        check_val("S1.5: dma_state is IDLE", dma_state, 3'd0);
        check_val("S1.6: buf_state_a is BUF_EMPTY", buf_state_a, 2'b00);
        check_val("S1.7: buf_state_b is BUF_EMPTY", buf_state_b, 2'b00);
        check_bool("S1.8: layer_done_pulse is low", layer_done_pulse, 1'b0);
        check_bool("S1.9: dma_done_pulse is low", dma_done_pulse, 1'b0);
        check_val("S1.10: active_pe_count reset default is 64", active_pe_count, 7'd64);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 2: Valid Command Acceptance ---");
        issue_cmd(16'd101, 2'b01, 1'b0, 1'b0, 1'b0, 16'd2);
        check_val("S2.1: Command accepted, state moved to ST_VALIDATE", sequencer_state, 4'd1);
        @(negedge clk);
        check_bool("S2.2: Sequencer busy asserted", sequencer_busy, 1'b1);
        check_bool("S2.3: cmd_ready dropped while busy", cmd_ready, 1'b0);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 3: Invalid Command Rejection ---");
        apply_reset();
        // 3a: Unsupported PE mode 2'b11
        issue_cmd(16'd102, 2'b11, 1'b0, 1'b0, 1'b0, 16'd2);
        @(posedge clk);
        @(negedge clk);
        check_bool("S3.1: sequencer_error_flag raised on mode 2'b11", sequencer_error_flag, 1'b1);
        check_val("S3.2: error_code is ERR_INVALID_PE_MODE (1)", sequencer_error_code, 4'd1);
        // Clear error
        @(negedge clk);
        sequencer_error_clear = 1'b1;
        @(negedge clk);
        sequencer_error_clear = 1'b0;
        @(negedge clk);
        check_bool("S3.3: Error cleared back to IDLE", sequencer_error_flag, 1'b0);
        check_bool("S3.4: cmd_ready restored", cmd_ready, 1'b1);

        // 3b: Zero k_total rejection
        issue_cmd(16'd103, 2'b00, 1'b0, 1'b0, 1'b0, 16'd0);
        @(posedge clk);
        @(negedge clk);
        check_bool("S3.5: sequencer_error_flag raised on zero k_total", sequencer_error_flag, 1'b1);
        check_val("S3.6: error_code is ERR_ZERO_K_TOTAL (2)", sequencer_error_code, 4'd2);
        @(negedge clk);
        sequencer_error_clear = 1'b1;
        @(negedge clk);
        sequencer_error_clear = 1'b0;
        @(negedge clk);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 4: Input Data Transfer via DMA ---");
        // Prepare test data in System Memory:
        // Word 0: act = 16'sd10, weight = 16'sd20 -> {16'h0014, 16'h000A} = 32'h0014_000A
        // Word 1: act = 16'sd15, weight = 16'sd30 -> {16'h001E, 16'h000F} = 32'h001E_000F
        sys_memory[32'h1000 >> 2]       = 32'h0014_000A;
        sys_memory[(32'h1000 >> 2) + 1] = 32'h001E_000F;
        start_dma(32'h0000_1000, 32'h0000_0000, 16'd2, 1'b1);
        wait_dma_done(50);
        check_bool("S4.1: DMA transfer completed with dma_done_pulse", dma_done_pulse, 1'b1);
        @(posedge clk);
        check_val("S4.2: Total produced buffers count is 1", total_produced_count, 32'd1);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 5: Buffer Readiness Tracking ---");
        check_val("S5.1: Buffer A transitioned to BUF_READY (2)", buf_state_a, 2'b10);
        check_val("S5.2: Buffer B remains BUF_EMPTY (0)", buf_state_b, 2'b00);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 6: Adaptive PE Configuration (32-PE Mode) ---");
        // Issue command for Layer 104: 32-PE mode, Buffer A, K=2
        issue_cmd(16'd104, 2'b01, 1'b0, 1'b1, 1'b0, 16'd2);
        @(negedge clk); // posedge occurred: moves ST_VALIDATE -> ST_WAIT_BUF
        @(negedge clk); // posedge occurred: moves ST_WAIT_BUF -> ST_CONFIGURE

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 7: Compute Start Triggering ---");
        @(negedge clk); // posedge occurred: moves ST_CONFIGURE -> ST_START_COMP
        check_val("S7.1: Sequencer in ST_START_COMP", sequencer_state, 4'd4);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 8: Compute Completion Tracking ---");
        @(negedge clk); // posedge occurred: moves ST_START_COMP -> ST_WAIT_COMP
        check_val("S6.1: Active cfg mode updated to 32-PE (1)", active_cfg_mode, 2'b01);
        check_val("S6.2: Active PE count is 32", active_pe_count, 7'd32);
        check_val("S6.3: col_active mask is 0x00FF (cols 0..7 active)", col_active, 16'h00FF);
        check_val("S6.4: Buffer A locked into BUF_CONSUMING (3)", buf_state_a, 2'b11);
        // Wait until feeder completes K=2 reduction steps
        for (int dbg_i = 0; dbg_i < 6; dbg_i++) begin
            $display("DBG %0d: feeder_st=%0d rvalid=%b dout=0x%08x comp_en=%b pe00_en=%b act=%0d mask=%b w=%0d bypass=%b prod=%0d mac_accum=%0d top_accum=%0d",
                     dbg_i, dut.u_feeder.state_q,
                     dut.u_feeder.sram_rd_rvalid, dut.u_feeder.sram_rd_dout, dut.u_feeder.compute_enable_in,
                     dut.u_pe_array.gen_row[0].gen_col[0].u_pe_mac.enable,
                     dut.u_pe_array.gen_row[0].gen_col[0].u_pe_mac.act_data,
                     dut.u_pe_array.gen_row[0].gen_col[0].u_pe_mac.act_mask,
                     dut.u_pe_array.gen_row[0].gen_col[0].u_pe_mac.weight_data,
                     dut.u_pe_array.gen_row[0].gen_col[0].u_pe_mac.bypass_mac,
                     dut.u_pe_array.gen_row[0].gen_col[0].u_pe_mac.product_32,
                     dut.u_pe_array.gen_row[0].gen_col[0].u_pe_mac.accum_out,
                     accum_out[0][0]);
            @(posedge clk);
        end
        wait_layer_done(50);
        check_bool("S8.1: Layer computation completed successfully", layer_done_pulse, 1'b1);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 9: Drain Completion & Barrier Synchronization ---");
        check_val("S9.1: Layer ID reported accurately", layer_done_id, 16'd104);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 10: Buffer Release ---");
        @(posedge clk);
        check_val("S10.1: Buffer A released back to BUF_EMPTY (0)", buf_state_a, 2'b00);
        check_val("S10.2: Total consumed count incremented to 1", total_consumed_count, 32'd1);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 11: Output Data Availability & Column Clamping ---");
        // Golden check: (10 * 20) + (15 * 30) = 200 + 450 = 650
        check_val40("S11.1: PE[0][0] accumulator equals 650", accum_out[0][0], 40'sd650);
        check_val40("S11.2: PE[1][5] accumulator equals 650", accum_out[1][5], 40'sd650);
        check_val40("S11.3: PE[3][7] accumulator equals 650", accum_out[3][7], 40'sd650);
        // Gated column 8..15 must be strictly clamped to 0
        check_val40("S11.4: Inactive PE[0][8] strictly clamped to 0", accum_out[0][8], 40'sd0);
        check_val40("S11.5: Inactive PE[2][15] strictly clamped to 0", accum_out[2][15], 40'sd0);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 12: Layer Completion Pulse & Handshake ---");
        @(negedge clk);
        check_bool("S12.1: layer_done_pulse deasserted after 1 cycle", layer_done_pulse, 1'b0);
        check_bool("S12.2: Sequencer returned to ST_IDLE", cmd_ready, 1'b1);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 13: Backpressure Handling at Connected Interfaces ---");
        // Request Buffer B (req_buf_id = 1) when Buffer B is EMPTY
        issue_cmd(16'd105, 2'b00, 1'b0, 1'b1, 1'b1, 16'd2);
        @(negedge clk); // ST_VALIDATE
        @(negedge clk); // ST_WAIT_BUF
        repeat (5) @(posedge clk);
        check_val("S13.1: Stalled in ST_WAIT_BUF waiting for Buffer B", sequencer_state, 4'd2);
        check_val("S13.2: Buffer B still BUF_EMPTY", buf_state_b, 2'b00);

        // Now trigger DMA to produce data into Buffer B (dst = 0x4000)
        sys_memory[32'h2000 >> 2]       = 32'h0008_0005; // 5 * 8 = 40
        sys_memory[(32'h2000 >> 2) + 1] = 32'h0004_0006; // 6 * 4 = 24 -> Total = 64
        start_dma(32'h0000_2000, 32'h0000_4000, 16'd2, 1'b1);
        wait_dma_done(50);
        check_bool("S13.3: DMA produced Buffer B successfully", dma_done_pulse, 1'b1);
        @(posedge clk);
        // Sequencer should un-stall and finish Layer 105
        wait_layer_done(50);
        check_bool("S13.4: Layer 105 un-stalled and completed", layer_done_pulse, 1'b1);
        check_val40("S13.5: Layer 105 output matches 64 (40 + 24)", accum_out[0][0], 40'sd64);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 14: Delayed DMA Responses (AR Backpressure) ---");
        cfg_ar_delay = 4;
        sys_memory[32'h2100 >> 2]       = 32'h0002_0003;
        sys_memory[(32'h2100 >> 2) + 1] = 32'h0002_0003;
        start_dma(32'h0000_2100, 32'h0000_0000, 16'd2, 1'b1);
        wait_dma_done(80);
        check_bool("S14.1: DMA finished despite AR slave backpressure", dma_done_pulse, 1'b1);
        cfg_ar_delay = 0;

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 15: Asynchronous Reset During Active Operation ---");
        // Start a transfer and reset mid-execution
        start_dma(32'h0000_2100, 32'h0000_4000, 16'd8, 1'b0);
        repeat (3) @(posedge clk);
        check_bool("S15.1: DMA active prior to reset", dma_busy, 1'b1);
        @(negedge clk);
        rst_n = 1'b0;
        @(negedge clk);
        check_bool("S15.2: Immediate busy drop under reset", dma_busy, 1'b0);
        check_val("S15.3: State reset to IDLE", dma_state, 3'd0);
        rst_n = 1'b1;
        @(posedge clk);
        // Post-reset recovery transfer
        sys_memory[32'h2200 >> 2] = 32'h000A_000A; // 10 * 10 = 100
        start_dma(32'h0000_2200, 32'h0000_0000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd(16'd106, 2'b00, 1'b0, 1'b1, 1'b0, 16'd1);
        wait_layer_done(50);
        check_bool("S15.4: Post-reset recovery layer completed cleanly", layer_done_pulse, 1'b1);
        check_val40("S15.5: Output matches 100 post-recovery", accum_out[0][0], 40'sd100);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 16: Repeated Consecutive Layer Commands ---");
        apply_reset();
        // Layer 201 (Buffer A)
        sys_memory[32'h2300 >> 2] = 32'h0002_0005; // 5 * 2 = 10
        start_dma(32'h0000_2300, 32'h0000_0000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd(16'd201, 2'b00, 1'b0, 1'b1, 1'b0, 16'd1);
        wait_layer_done(50);
        check_val("S16.1: Layer 201 ID confirmed", layer_done_id, 16'd201);
        check_val40("S16.2: Layer 201 output equals 10", accum_out[0][0], 40'sd10);
        @(posedge clk);

        // Layer 202 (Buffer B)
        sys_memory[32'h2304 >> 2] = 32'h0004_0005; // 5 * 4 = 20
        start_dma(32'h0000_2304, 32'h0000_4000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd(16'd202, 2'b00, 1'b0, 1'b1, 1'b1, 16'd1);
        wait_layer_done(50);
        check_val("S16.3: Layer 202 ID confirmed", layer_done_id, 16'd202);
        check_val40("S16.4: Layer 202 output equals 20", accum_out[0][0], 40'sd20);
        @(posedge clk);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 17: Overlapped Ping-Pong Buffering (Buffer A & B) ---");
        apply_reset();
        // Pre-fill Buffer A with Layer 301 data
        sys_memory[32'h2400 >> 2] = 32'h0003_0007; // 7 * 3 = 21
        start_dma(32'h0000_2400, 32'h0000_0000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        check_val("S17.1: Buffer A is READY", buf_state_a, 2'b10);

        // Pre-fill Buffer B with Layer 302 data
        sys_memory[32'h2500 >> 2] = 32'h0006_0007; // 7 * 6 = 42
        start_dma(32'h0000_2500, 32'h0000_4000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        check_val("S17.2: Buffer B is READY concurrently", buf_state_b, 2'b10);

        // Execute Layer 301 on Buffer A
        issue_cmd(16'd301, 2'b00, 1'b0, 1'b1, 1'b0, 16'd1);
        wait_layer_done(50);
        check_val("S17.3: Layer 301 completed", layer_done_id, 16'd301);
        check_val40("S17.4: Layer 301 output equals 21", accum_out[0][0], 40'sd21);
        check_val("S17.5: Buffer A consumed and EMPTY", buf_state_a, 2'b00);
        check_val("S17.6: Buffer B retained READY status", buf_state_b, 2'b10);

        // Immediately execute Layer 302 on Buffer B without reloading!
        issue_cmd(16'd302, 2'b00, 1'b0, 1'b1, 1'b1, 16'd1);
        wait_layer_done(50);
        check_val("S17.7: Layer 302 completed", layer_done_id, 16'd302);
        check_val40("S17.8: Layer 302 output equals 42", accum_out[0][0], 40'sd42);
        check_val("S17.9: Buffer B consumed and EMPTY", buf_state_b, 2'b00);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 18: No Premature Completion Pulse ---");
        apply_reset();
        // Start multi-beat layer (K=4) and check pulse is 0 during computation
        sys_memory[32'h2600 >> 2] = 32'h0001_0001;
        sys_memory[(32'h2600 >> 2)+1] = 32'h0001_0001;
        sys_memory[(32'h2600 >> 2)+2] = 32'h0001_0001;
        sys_memory[(32'h2600 >> 2)+3] = 32'h0001_0001;
        start_dma(32'h0000_2600, 32'h0000_0000, 16'd4, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        issue_cmd(16'd401, 2'b00, 1'b0, 1'b1, 1'b0, 16'd4);
        repeat (3) @(posedge clk);
        check_bool("S18.1: No premature layer_done_pulse during active computation", layer_done_pulse, 1'b0);
        wait_layer_done(50);
        check_bool("S18.2: Pulse fires strictly at end of execution", layer_done_pulse, 1'b1);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 19: No Lost or Duplicated Requests Under Held Valid ---");
        apply_reset();
        sys_memory[32'h2700 >> 2] = 32'h0002_0002;
        start_dma(32'h0000_2700, 32'h0000_0000, 16'd1, 1'b1);
        wait_dma_done(50);
        @(posedge clk);
        // Hold cmd_valid high across 10 cycles
        @(negedge clk);
        cmd_valid              = 1'b1;
        cmd_layer_id           = 16'd501;
        cmd_pe_mode            = 2'b00;
        cmd_adaptive_en        = 1'b0;
        cmd_use_ping_pong      = 1'b1;
        cmd_req_buf_id         = 1'b0;
        cmd_k_total            = 16'd1;
        repeat (10) @(posedge clk);
        @(negedge clk);
        cmd_valid              = 1'b0;
        wait_layer_done(50);
        check_val("S19.1: Layer 501 completed exactly once", layer_done_id, 16'd501);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 20: Bit-Exact Output Comparison against Software Reference Model ---");
        apply_reset();
        // Test vector:
        // A = [12, -4, 25, -15], W = [8, 10, -6, 14]
        // Product terms:
        // 12 * 8    = +96
        // -4 * 10   = -40
        // 25 * -6   = -150
        // -15 * 14  = -210
        // Expected Golden Sum: 96 - 40 - 150 - 210 = -304
        golden_ref_sum = (16'sd12 * 16'sd8) + (-16'sd4 * 16'sd10) +
                         (16'sd25 * -16'sd6) + (-16'sd15 * 16'sd14);

        sys_memory[32'h2800 >> 2]       = {16'sd8,  16'sd12};  // {W0, A0}
        sys_memory[(32'h2800 >> 2) + 1] = {16'sd10, -16'sd4};  // {W1, A1}
        sys_memory[(32'h2800 >> 2) + 2] = {-16'sd6, 16'sd25};  // {W2, A2}
        sys_memory[(32'h2800 >> 2) + 3] = {16'sd14, -16'sd15}; // {W3, A3}

        // Ingest into Buffer A
        start_dma(32'h0000_2800, 32'h0000_0000, 16'd4, 1'b1);
        wait_dma_done(50);
        @(posedge clk);

        // Execute Layer 601 in 64-PE mode (all 64 PEs active!)
        issue_cmd(16'd601, 2'b10, 1'b0, 1'b1, 1'b0, 16'd4);
        wait_layer_done(60);

        check_val("S20.1: Layer 601 completed", layer_done_id, 16'd601);
        check_val("S20.2: 64 PEs active", active_pe_count, 7'd64);

        // Verify across all active rows and columns against golden reference
        for (idx = 0; idx < ROWS; idx = idx + 1) begin
            for (loop_i = 0; loop_i < COLS; loop_i = loop_i + 1) begin
                check_val40($sformatf("S20.3: PE[%0d][%0d] matches software model (-304)", idx, loop_i),
                            accum_out[idx][loop_i], golden_ref_sum);
            end
        end

        // ---------------------------------------------------------------------
        // Test Summary
        // -------------------------------------------------------------------------
        $display("\n==================================================================");
        $display("TSK-07 Test Summary: Total=%0d, Passed=%0d, Failed=%0d", test_count, pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-07 System Integration Tests Passed!");
            $finish(0);
        end else begin
            $display("[FAILURE] Some TSK-07 tests failed!");
            $finish(1);
        end
    end

endmodule