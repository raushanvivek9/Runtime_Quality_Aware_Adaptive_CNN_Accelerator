// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-06 AXI4/DMA Interface Verification
// Module: tb_dma_controller.sv
// Description: Comprehensive self-checking testbench for dma_controller.
//              Covers all 18 specified scenarios plus ping-pong coordination:
//                S1:  Reset and initial idle state
//                S2:  Valid short transfer (2 beats)
//                S3:  Multi-beat transfer (8 beats)
//                S4:  Transfer-length counter accuracy
//                S5:  Source-address progression (+4 bytes/beat)
//                S6:  Destination-address progression (+4 bytes/beat)
//                S7:  Read-request backpressure (arready held low)
//                S8:  Read-response delay (no premature writes)
//                S9:  Write-request backpressure (wready held low)
//                S10: Delayed write response (bvalid delay & wait state)
//                S11: Zero-length transfer rejection (ERR_ZERO_LEN)
//                S12: Invalid & overflowing address rejection
//                S13: Held start request (no duplicate execution)
//                S14: Reset while idle
//                S15: Reset during active transfer (immediate abort & FIFO flush)
//                S16: Error handling on slave responses (rresp & bresp SLVERR)
//                S17: Repeated transfers across different source & destination
//                S18: No completion before all write responses received
//                S19: Ping-pong buffer coordination & backpressure
// =============================================================================

`timescale 1ns / 1ps

module tb_dma_controller;

    localparam time CLK_PERIOD = 10ns;
    localparam int ADDR_WIDTH  = 32;
    localparam int DATA_WIDTH  = 32;
    localparam int LEN_WIDTH   = 16;
    localparam int FIFO_DEPTH  = 16;

    // Error Codes
    localparam logic [3:0] ERR_NONE           = 4'd0;
    localparam logic [3:0] ERR_ZERO_LEN       = 4'd1;
    localparam logic [3:0] ERR_ADDR_OVERFLOW  = 4'd2;
    localparam logic [3:0] ERR_UNALIGNED_ADDR = 4'd3;
    localparam logic [3:0] ERR_SLV_READ_RESP  = 4'd4;
    localparam logic [3:0] ERR_SLV_WRITE_RESP = 4'd5;

    // FSM States
    localparam logic [2:0] ST_IDLE      = 3'd0;
    localparam logic [2:0] ST_VALIDATE  = 3'd1;
    localparam logic [2:0] ST_STREAM    = 3'd2;
    localparam logic [2:0] ST_WAIT_RESP = 3'd3;
    localparam logic [2:0] ST_DONE      = 3'd4;
    localparam logic [2:0] ST_ERROR     = 3'd5;

    // Clock and Reset
    logic                      clk;
    logic                      rst_n;

    // Control & Configuration Interface
    logic                      dma_start;
    logic [ADDR_WIDTH-1:0]     dma_src_addr;
    logic [ADDR_WIDTH-1:0]     dma_dst_addr;
    logic [LEN_WIDTH-1:0]      dma_transfer_len;
    logic                      dma_use_ping_pong;
    logic                      dma_error_clear;

    wire                       dma_busy;
    wire [2:0]                 dma_state;
    wire                       dma_done_pulse;
    wire                       dma_error_flag;
    wire [3:0]                 dma_error_code;

    // Ping-Pong Coordination
    logic                      pp_producer_ready;
    wire                       pp_producer_start;
    wire                       pp_producer_done;

    // AXI4 Master Read Channel
    wire [ADDR_WIDTH-1:0]      m_axi_araddr;
    wire [7:0]                 m_axi_arlen;
    wire [2:0]                 m_axi_arsize;
    wire [1:0]                 m_axi_arburst;
    wire                       m_axi_arvalid;
    logic                      m_axi_arready;

    logic [DATA_WIDTH-1:0]     m_axi_rdata;
    logic [1:0]                m_axi_rresp;
    logic                      m_axi_rlast;
    logic                      m_axi_rvalid;
    wire                       m_axi_rready;

    // AXI4 Master Write Channel
    wire [ADDR_WIDTH-1:0]      m_axi_awaddr;
    wire [7:0]                 m_axi_awlen;
    wire [2:0]                 m_axi_awsize;
    wire [1:0]                 m_axi_awburst;
    wire                       m_axi_awvalid;
    logic                      m_axi_awready;

    wire [DATA_WIDTH-1:0]      m_axi_wdata;
    wire [(DATA_WIDTH/8)-1:0]  m_axi_wstrb;
    wire                       m_axi_wlast;
    wire                       m_axi_wvalid;
    logic                      m_axi_wready;

    logic [1:0]                m_axi_bresp;
    logic                      m_axi_bvalid;
    wire                       m_axi_bready;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT)
    // -------------------------------------------------------------------------
    dma_controller #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .LEN_WIDTH  (LEN_WIDTH),
        .FIFO_DEPTH (FIFO_DEPTH)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .dma_start         (dma_start),
        .dma_src_addr      (dma_src_addr),
        .dma_dst_addr      (dma_dst_addr),
        .dma_transfer_len  (dma_transfer_len),
        .dma_use_ping_pong (dma_use_ping_pong),
        .dma_error_clear   (dma_error_clear),
        .dma_busy          (dma_busy),
        .dma_state         (dma_state),
        .dma_done_pulse    (dma_done_pulse),
        .dma_error_flag    (dma_error_flag),
        .dma_error_code    (dma_error_code),
        .pp_producer_ready (pp_producer_ready),
        .pp_producer_start (pp_producer_start),
        .pp_producer_done  (pp_producer_done),
        .m_axi_araddr      (m_axi_araddr),
        .m_axi_arlen       (m_axi_arlen),
        .m_axi_arsize      (m_axi_arsize),
        .m_axi_arburst     (m_axi_arburst),
        .m_axi_arvalid     (m_axi_arvalid),
        .m_axi_arready     (m_axi_arready),
        .m_axi_rdata       (m_axi_rdata),
        .m_axi_rresp       (m_axi_rresp),
        .m_axi_rlast       (m_axi_rlast),
        .m_axi_rvalid      (m_axi_rvalid),
        .m_axi_rready      (m_axi_rready),
        .m_axi_awaddr      (m_axi_awaddr),
        .m_axi_awlen       (m_axi_awlen),
        .m_axi_awsize      (m_axi_awsize),
        .m_axi_awburst     (m_axi_awburst),
        .m_axi_awvalid     (m_axi_awvalid),
        .m_axi_awready     (m_axi_awready),
        .m_axi_wdata       (m_axi_wdata),
        .m_axi_wstrb       (m_axi_wstrb),
        .m_axi_wlast       (m_axi_wlast),
        .m_axi_wvalid      (m_axi_wvalid),
        .m_axi_wready      (m_axi_wready),
        .m_axi_bresp       (m_axi_bresp),
        .m_axi_bvalid      (m_axi_bvalid),
        .m_axi_bready      (m_axi_bready)
    );

    // -------------------------------------------------------------------------
    // Testbench Memory & Slave Emulation State
    // -------------------------------------------------------------------------
    logic [31:0] src_memory [0:4095];
    logic [31:0] dst_memory [0:4095];

    // Queues for pipelined responses
    logic [31:0] ar_fifo_addr [0:63];
    int          ar_fifo_delay [0:63];
    int          ar_wr_ptr, ar_rd_ptr;

    logic [31:0] aw_fifo_addr [0:63];
    int          aw_wr_ptr, aw_rd_ptr;

    int          b_fifo_delay [0:63];
    int          b_wr_ptr, b_rd_ptr;

    // Configuration knobs
    int          cfg_ar_delay;
    int          cfg_r_delay;
    int          cfg_aw_delay;
    int          cfg_w_delay;
    int          cfg_b_delay;
    logic        cfg_rresp_err;
    logic        cfg_bresp_err;

    // Delay counters
    int          ar_wait_cnt;
    int          aw_wait_cnt;
    int          w_wait_cnt;

    // Test tracking counters
    int          test_count;
    int          pass_count;
    int          fail_count;
    int          idx;
    int          loop_i;
    int          timeout_cnt;

    // Monitored transaction counts
    int          mon_ar_cnt;
    int          mon_r_cnt;
    int          mon_aw_cnt;
    int          mon_w_cnt;
    int          mon_b_cnt;

    // Monitored address progression arrays
    logic [31:0] mon_araddr_hist [0:15];
    logic [31:0] mon_awaddr_hist [0:15];

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // Verification Check Tasks
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

    task automatic check_bool(input string tag, input logic actual, input logic expected);
        test_count++;
        if (actual === expected) begin
            pass_count++;
        end else begin
            fail_count++;
            $display("[FAIL] %s: actual=%b, expected=%b", tag, actual, expected);
        end
    endtask

    task automatic flush_slave();
        ar_wr_ptr     = 0;
        ar_rd_ptr     = 0;
        aw_wr_ptr     = 0;
        aw_rd_ptr     = 0;
        b_wr_ptr      = 0;
        b_rd_ptr      = 0;
        ar_wait_cnt   = 0;
        aw_wait_cnt   = 0;
        w_wait_cnt    = 0;
        cfg_rresp_err = 1'b0;
        cfg_bresp_err = 1'b0;
        m_axi_arready = 1'b0;
        m_axi_rvalid  = 1'b0;
        m_axi_awready = 1'b0;
        m_axi_wready  = 1'b0;
        m_axi_bvalid  = 1'b0;
    endtask

    task automatic clear_dma_error();
        @(negedge clk);
        dma_error_clear = 1'b1;
        @(negedge clk);
        dma_error_clear = 1'b0;
        @(negedge clk);
    endtask

    // Reset task
    task automatic apply_reset();
        rst_n             = 1'b0;
        dma_start         = 1'b0;
        dma_src_addr      = '0;
        dma_dst_addr      = '0;
        dma_transfer_len  = '0;
        dma_use_ping_pong = 1'b0;
        dma_error_clear   = 1'b0;
        pp_producer_ready = 1'b1;

        cfg_ar_delay      = 0;
        cfg_r_delay       = 0;
        cfg_aw_delay      = 0;
        cfg_w_delay       = 0;
        cfg_b_delay       = 0;
        cfg_rresp_err     = 1'b0;
        cfg_bresp_err     = 1'b0;

        ar_wait_cnt       = 0;
        aw_wait_cnt       = 0;
        w_wait_cnt        = 0;

        ar_wr_ptr         = 0;
        ar_rd_ptr         = 0;
        aw_wr_ptr         = 0;
        aw_rd_ptr         = 0;
        b_wr_ptr          = 0;
        b_rd_ptr          = 0;

        mon_ar_cnt        = 0;
        mon_r_cnt         = 0;
        mon_aw_cnt        = 0;
        mon_w_cnt         = 0;
        mon_b_cnt         = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // -------------------------------------------------------------------------
    // AXI Slave Emulation Model
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_arready <= 1'b0;
            m_axi_rvalid  <= 1'b0;
            m_axi_rdata   <= '0;
            m_axi_rresp   <= 2'b00;
            m_axi_rlast   <= 1'b0;

            m_axi_awready <= 1'b0;
            m_axi_wready  <= 1'b0;
            m_axi_bvalid  <= 1'b0;
            m_axi_bresp   <= 2'b00;

            ar_wait_cnt   <= 0;
            aw_wait_cnt   <= 0;
            w_wait_cnt    <= 0;
            ar_wr_ptr     <= 0;
            ar_rd_ptr     <= 0;
            aw_wr_ptr     <= 0;
            aw_rd_ptr     <= 0;
            b_wr_ptr      <= 0;
            b_rd_ptr      <= 0;
        end else begin
            // -----------------------------------------------------------------
            // 1. Read Address Channel (AR) Slave
            // -----------------------------------------------------------------
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

            // On handshake: enqueue read request
            if (m_axi_arvalid && m_axi_arready) begin
                ar_fifo_addr[ar_wr_ptr]  <= m_axi_araddr;
                ar_fifo_delay[ar_wr_ptr] <= cfg_r_delay;
                ar_wr_ptr                <= ar_wr_ptr + 1;
                if (mon_ar_cnt < 16) mon_araddr_hist[mon_ar_cnt] <= m_axi_araddr;
                mon_ar_cnt               <= mon_ar_cnt + 1;
            end

            // -----------------------------------------------------------------
            // 2. Read Data Channel (R) Slave
            // -----------------------------------------------------------------
            if (m_axi_rvalid && m_axi_rready) begin
                ar_rd_ptr    <= ar_rd_ptr + 1;
                m_axi_rvalid <= 1'b0;
                mon_r_cnt    <= mon_r_cnt + 1;
            end else if (ar_rd_ptr != ar_wr_ptr) begin
                if (ar_fifo_delay[ar_rd_ptr] > 0) begin
                    ar_fifo_delay[ar_rd_ptr] <= ar_fifo_delay[ar_rd_ptr] - 1;
                    m_axi_rvalid             <= 1'b0;
                end else begin
                    m_axi_rvalid <= 1'b1;
                    m_axi_rdata  <= (cfg_rresp_err) ? 32'hDEAD_BEEF :
                                    src_memory[(ar_fifo_addr[ar_rd_ptr] >> 2) & 12'hFFF];
                    m_axi_rresp  <= (cfg_rresp_err) ? 2'b10 : 2'b00;
                    m_axi_rlast  <= 1'b1;
                end
            end else begin
                m_axi_rvalid <= 1'b0;
            end

            // -----------------------------------------------------------------
            // 3. Write Address Channel (AW) Slave
            // -----------------------------------------------------------------
            if (m_axi_awvalid) begin
                if (aw_wait_cnt < cfg_aw_delay) begin
                    m_axi_awready <= 1'b0;
                    aw_wait_cnt   <= aw_wait_cnt + 1;
                end else begin
                    m_axi_awready <= 1'b1;
                    aw_wait_cnt   <= 0;
                end
            end else begin
                m_axi_awready <= 1'b0;
                aw_wait_cnt   <= 0;
            end

            if (m_axi_awvalid && m_axi_awready) begin
                aw_fifo_addr[aw_wr_ptr] <= m_axi_awaddr;
                aw_wr_ptr               <= aw_wr_ptr + 1;
                if (mon_aw_cnt < 16) mon_awaddr_hist[mon_aw_cnt] <= m_axi_awaddr;
                mon_aw_cnt              <= mon_aw_cnt + 1;
            end

            // -----------------------------------------------------------------
            // 4. Write Data Channel (W) Slave
            // -----------------------------------------------------------------
            if (m_axi_wvalid) begin
                if (w_wait_cnt < cfg_w_delay) begin
                    m_axi_wready <= 1'b0;
                    w_wait_cnt   <= w_wait_cnt + 1;
                end else begin
                    m_axi_wready <= 1'b1;
                    w_wait_cnt   <= 0;
                end
            end else begin
                m_axi_wready <= 1'b0;
                w_wait_cnt   <= 0;
            end

            if (m_axi_wvalid && m_axi_wready) begin
                dst_memory[(aw_fifo_addr[aw_rd_ptr] >> 2) & 12'hFFF] <= m_axi_wdata;
                aw_rd_ptr              <= aw_rd_ptr + 1;
                b_fifo_delay[b_wr_ptr] <= cfg_b_delay;
                b_wr_ptr               <= b_wr_ptr + 1;
                mon_w_cnt              <= mon_w_cnt + 1;
            end

            // -----------------------------------------------------------------
            // 5. Write Response Channel (B) Slave
            // -----------------------------------------------------------------
            if (m_axi_bvalid && m_axi_bready) begin
                b_rd_ptr     <= b_rd_ptr + 1;
                m_axi_bvalid <= 1'b0;
                mon_b_cnt    <= mon_b_cnt + 1;
            end else if (b_rd_ptr != b_wr_ptr) begin
                if (b_fifo_delay[b_rd_ptr] > 0) begin
                    b_fifo_delay[b_rd_ptr] <= b_fifo_delay[b_rd_ptr] - 1;
                    m_axi_bvalid           <= 1'b0;
                end else begin
                    m_axi_bvalid <= 1'b1;
                    m_axi_bresp  <= (cfg_bresp_err) ? 2'b10 : 2'b00;
                end
            end else begin
                m_axi_bvalid <= 1'b0;
            end
        end
    end

    // Helper task to initiate DMA transfer
    task automatic start_dma(
        input logic [31:0] src,
        input logic [31:0] dst,
        input logic [15:0] len,
        input logic        pp_en
    );
        @(negedge clk);
        dma_src_addr      = src;
        dma_dst_addr      = dst;
        dma_transfer_len  = len;
        dma_use_ping_pong = pp_en;
        dma_start         = 1'b1;
        @(negedge clk);
        dma_start         = 1'b0;
    endtask

    // Helper task to wait for completion pulse with timeout
    task automatic wait_done(input int max_cycles);
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

        // Populate Source Memory with deterministic pattern
        for (idx = 0; idx < 4096; idx = idx + 1) begin
            src_memory[idx] = 32'hA000_0000 + idx;
            dst_memory[idx] = 32'h0000_0000;
        end

        $display("\n==================================================================");
        $display("TSK-06: AXI4/DMA Controller Verification Suite Starting");
        $display("==================================================================");

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 1: Reset & Initial Idle State ---");
        apply_reset();
        check_bool("S1.1: dma_busy is low post-reset", dma_busy, 1'b0);
        check_val("S1.2: dma_state is ST_IDLE", dma_state, ST_IDLE);
        check_bool("S1.3: dma_done_pulse is low", dma_done_pulse, 1'b0);
        check_bool("S1.4: dma_error_flag is low", dma_error_flag, 1'b0);
        check_val("S1.5: dma_error_code is ERR_NONE", dma_error_code, ERR_NONE);
        check_bool("S1.6: pp_producer_start is low", pp_producer_start, 1'b0);
        check_bool("S1.7: pp_producer_done is low", pp_producer_done, 1'b0);
        check_bool("S1.8: m_axi_arvalid is quiescent", m_axi_arvalid, 1'b0);
        check_bool("S1.9: m_axi_awvalid is quiescent", m_axi_awvalid, 1'b0);
        check_bool("S1.10: m_axi_wvalid is quiescent", m_axi_wvalid, 1'b0);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 2: Valid Short Transfer (2 Beats) ---");
        start_dma(32'h0000_1000, 32'h0000_2000, 16'd2, 1'b0);
        wait_done(50);
        check_bool("S2.1: dma_done_pulse observed", dma_done_pulse, 1'b1);
        @(negedge clk);
        check_bool("S2.2: dma_busy returned to 0", dma_busy, 1'b0);
        check_val("S2.3: dma_state back to ST_IDLE", dma_state, ST_IDLE);
        check_val("S2.4: dst_memory[0] matches src", dst_memory[32'h2000 >> 2], src_memory[32'h1000 >> 2]);
        check_val("S2.5: dst_memory[1] matches src", dst_memory[(32'h2000 >> 2) + 1], src_memory[(32'h1000 >> 2) + 1]);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 3: Multi-Beat Transfer (8 Beats) ---");
        mon_ar_cnt = 0; mon_r_cnt = 0; mon_aw_cnt = 0; mon_w_cnt = 0; mon_b_cnt = 0;
        start_dma(32'h0000_0100, 32'h0000_0500, 16'd8, 1'b0);
        wait_done(100);
        check_bool("S3.1: 8-beat transfer completed", dma_done_pulse, 1'b1);
        for (loop_i = 0; loop_i < 8; loop_i = loop_i + 1) begin
            check_val($sformatf("S3.2.%0d: Data beat %0d match", loop_i, loop_i),
                      dst_memory[(32'h0500 >> 2) + loop_i],
                      src_memory[(32'h0100 >> 2) + loop_i]);
        end

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 4: Transfer-Length Counter Accuracy ---");
        check_val("S4.1: AR handshakes exactly 8", mon_ar_cnt, 8);
        check_val("S4.2: R handshakes exactly 8", mon_r_cnt, 8);
        check_val("S4.3: AW handshakes exactly 8", mon_aw_cnt, 8);
        check_val("S4.4: W handshakes exactly 8", mon_w_cnt, 8);
        check_val("S4.5: B handshakes exactly 8", mon_b_cnt, 8);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 5: Source-Address Progression (+4 bytes/beat) ---");
        mon_ar_cnt = 0;
        mon_aw_cnt = 0;
        start_dma(32'h0000_3000, 32'h0000_4000, 16'd4, 1'b0);
        wait_done(50);
        check_val("S5.1: Beat 0 ARADDR == 0x3000", mon_araddr_hist[0], 32'h0000_3000);
        check_val("S5.2: Beat 1 ARADDR == 0x3004", mon_araddr_hist[1], 32'h0000_3004);
        check_val("S5.3: Beat 2 ARADDR == 0x3008", mon_araddr_hist[2], 32'h0000_3008);
        check_val("S5.4: Beat 3 ARADDR == 0x300C", mon_araddr_hist[3], 32'h0000_300C);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 6: Destination-Address Progression (+4 bytes/beat) ---");
        check_val("S6.1: Beat 0 AWADDR == 0x4000", mon_awaddr_hist[0], 32'h0000_4000);
        check_val("S6.2: Beat 1 AWADDR == 0x4004", mon_awaddr_hist[1], 32'h0000_4004);
        check_val("S6.3: Beat 2 AWADDR == 0x4008", mon_awaddr_hist[2], 32'h0000_4008);
        check_val("S6.4: Beat 3 AWADDR == 0x400C", mon_awaddr_hist[3], 32'h0000_400C);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 7: Read-Request Backpressure (arready delay) ---");
        cfg_ar_delay = 3;
        start_dma(32'h0000_1200, 32'h0000_2200, 16'd3, 1'b0);
        // During transfer, while arready is 0, arvalid must stay high
        @(posedge clk);
        @(negedge clk);
        check_bool("S7.1: arvalid asserted during backpressure", m_axi_arvalid, 1'b1);
        wait_done(80);
        check_bool("S7.2: Transfer completes despite AR backpressure", dma_done_pulse, 1'b1);
        cfg_ar_delay = 0;

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 8: Read-Response Delay (no premature writes) ---");
        cfg_r_delay = 4;
        start_dma(32'h0000_1300, 32'h0000_2300, 16'd2, 1'b0);
        @(posedge clk);
        @(negedge clk);
        check_bool("S8.1: wvalid remains low while awaiting read data", m_axi_wvalid, 1'b0);
        wait_done(80);
        check_bool("S8.2: Transfer completes accurately after read response delay", dma_done_pulse, 1'b1);
        cfg_r_delay = 0;

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 9: Write-Request Backpressure (wready delay) ---");
        cfg_w_delay = 3;
        start_dma(32'h0000_1400, 32'h0000_2400, 16'd2, 1'b0);
        wait_done(80);
        check_bool("S9.1: Transfer completes despite W backpressure", dma_done_pulse, 1'b1);
        cfg_w_delay = 0;

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 10: Delayed Write Response (bvalid delay) ---");
        cfg_b_delay = 5;
        start_dma(32'h0000_1500, 32'h0000_2500, 16'd2, 1'b0);
        // Wait until all data beats are written, then check we are in ST_WAIT_RESP
        repeat (10) @(posedge clk);
        check_bool("S10.1: dma_busy held high during write response wait", dma_busy, 1'b1);
        wait_done(50);
        check_bool("S10.2: Completion pulse fires only after delayed B response", dma_done_pulse, 1'b1);
        cfg_b_delay = 0;

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 11: Zero-Length Transfer Rejection ---");
        start_dma(32'h0000_1000, 32'h0000_2000, 16'd0, 1'b0);
        @(posedge clk);
        @(negedge clk);
        check_bool("S11.1: Error flag raised on zero length", dma_error_flag, 1'b1);
        check_val("S11.2: Error code is ERR_ZERO_LEN", dma_error_code, ERR_ZERO_LEN);
        check_val("S11.3: FSM enters ST_ERROR", dma_state, ST_ERROR);
        // Clear error
        clear_dma_error();
        check_bool("S11.4: Error cleared back to IDLE", dma_error_flag, 1'b0);
        check_val("S11.5: State returned to ST_IDLE", dma_state, ST_IDLE);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 12: Invalid & Overflowing Address Rejection ---");
        // 12a: Unaligned source address
        start_dma(32'h0000_1002, 32'h0000_2000, 16'd4, 1'b0);
        @(posedge clk);
        @(negedge clk);
        check_bool("S12.1: Error flag on unaligned source address", dma_error_flag, 1'b1);
        check_val("S12.2: Error code is ERR_UNALIGNED_ADDR", dma_error_code, ERR_UNALIGNED_ADDR);
        clear_dma_error();

        // 12b: Unaligned destination address
        start_dma(32'h0000_1000, 32'h0000_2001, 16'd4, 1'b0);
        @(posedge clk);
        @(negedge clk);
        check_bool("S12.3: Error flag on unaligned destination address", dma_error_flag, 1'b1);
        check_val("S12.4: Error code is ERR_UNALIGNED_ADDR", dma_error_code, ERR_UNALIGNED_ADDR);
        clear_dma_error();

        // 12c: Address overflow
        start_dma(32'hFFFF_FFF0, 32'h0000_2000, 16'd8, 1'b0);
        @(posedge clk);
        @(negedge clk);
        check_bool("S12.5: Error flag on 32-bit address overflow", dma_error_flag, 1'b1);
        check_val("S12.6: Error code is ERR_ADDR_OVERFLOW", dma_error_code, ERR_ADDR_OVERFLOW);
        clear_dma_error();

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 13: Held Start Request ---");
        @(negedge clk);
        dma_src_addr      = 32'h0000_1600;
        dma_dst_addr      = 32'h0000_2600;
        dma_transfer_len  = 16'd2;
        dma_use_ping_pong = 1'b0;
        dma_start         = 1'b1; // Keep high indefinitely!
        wait_done(50);
        check_bool("S13.1: Transfer completed while dma_start held high", dma_done_pulse, 1'b1);
        repeat (5) @(posedge clk);
        check_bool("S13.2: DUT returned to IDLE despite dma_start held", dma_busy, 1'b0);
        check_val("S13.3: State remains ST_IDLE without duplicate transfer", dma_state, ST_IDLE);
        @(negedge clk);
        dma_start = 1'b0;
        @(negedge clk);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 14: Reset While Idle ---");
        @(negedge clk);
        rst_n = 1'b0;
        @(negedge clk);
        check_val("S14.1: State in ST_IDLE under reset", dma_state, ST_IDLE);
        check_bool("S14.2: Busy is 0 under reset", dma_busy, 1'b0);
        rst_n = 1'b1;
        @(negedge clk);
        check_val("S14.3: State remains ST_IDLE after reset released", dma_state, ST_IDLE);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 15: Reset During Active Transfer ---");
        cfg_w_delay = 5;
        start_dma(32'h0000_1700, 32'h0000_2700, 16'd8, 1'b0);
        repeat (4) @(posedge clk);
        check_bool("S15.1: DMA active prior to reset assertion", dma_busy, 1'b1);
        @(negedge clk);
        rst_n = 1'b0;
        @(negedge clk);
        check_bool("S15.2: Immediate busy drop on reset assertion", dma_busy, 1'b0);
        check_val("S15.3: Immediate state reset to ST_IDLE", dma_state, ST_IDLE);
        rst_n = 1'b1;
        cfg_w_delay = 0;
        @(posedge clk);
        // Post-reset recovery transfer
        start_dma(32'h0000_1800, 32'h0000_2800, 16'd2, 1'b0);
        wait_done(50);
        check_bool("S15.4: Successful clean transfer post-reset recovery", dma_done_pulse, 1'b1);

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 16: Error Handling on Slave Responses ---");
        // 16a: Read response SLVERR
        flush_slave();
        cfg_rresp_err = 1'b1;
        start_dma(32'h0000_1900, 32'h0000_2900, 16'd4, 1'b0);
        repeat (10) @(posedge clk);
        check_bool("S16.1: Error flag asserted on slave read error", dma_error_flag, 1'b1);
        check_val("S16.2: Error code is ERR_SLV_READ_RESP", dma_error_code, ERR_SLV_READ_RESP);
        flush_slave();
        clear_dma_error();

        // 16b: Write response SLVERR
        flush_slave();
        cfg_bresp_err = 1'b1;
        start_dma(32'h0000_1900, 32'h0000_2900, 16'd2, 1'b0);
        repeat (15) @(posedge clk);
        check_bool("S16.3: Error flag asserted on slave write error", dma_error_flag, 1'b1);
        check_val("S16.4: Error code is ERR_SLV_WRITE_RESP", dma_error_code, ERR_SLV_WRITE_RESP);
        flush_slave();
        clear_dma_error();

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 17: Repeated Transfers Across Different Addresses ---");
        flush_slave();
        // Transfer 1
        start_dma(32'h0000_0200, 32'h0000_0600, 16'd3, 1'b0);
        wait_done(50);
        check_bool("S17.1: Transfer 1 completed", dma_done_pulse, 1'b1);
        // Transfer 2 immediately
        start_dma(32'h0000_0300, 32'h0000_0700, 16'd5, 1'b0);
        wait_done(60);
        check_bool("S17.2: Transfer 2 completed", dma_done_pulse, 1'b1);
        for (loop_i = 0; loop_i < 3; loop_i = loop_i + 1) begin
            check_val($sformatf("S17.3.%0d: Transfer 1 data match %0d", loop_i, loop_i),
                      dst_memory[(32'h0600 >> 2) + loop_i],
                      src_memory[(32'h0200 >> 2) + loop_i]);
        end
        for (loop_i = 0; loop_i < 5; loop_i = loop_i + 1) begin
            check_val($sformatf("S17.4.%0d: Transfer 2 data match %0d", loop_i, loop_i),
                      dst_memory[(32'h0700 >> 2) + loop_i],
                      src_memory[(32'h0300 >> 2) + loop_i]);
        end

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 18: No Completion Before All Responses Received ---");
        flush_slave();
        cfg_b_delay = 8;
        start_dma(32'h0000_1A00, 32'h0000_2A00, 16'd2, 1'b0);
        repeat (12) @(posedge clk);
        check_bool("S18.1: No premature done pulse while responses in flight", dma_done_pulse, 1'b0);
        check_val("S18.2: State is ST_WAIT_RESP", dma_state, ST_WAIT_RESP);
        wait_done(50);
        check_bool("S18.3: Done pulse asserted upon final response arrival", dma_done_pulse, 1'b1);
        cfg_b_delay = 0;

        // ---------------------------------------------------------------------
        $display("\n--- SCENARIO 19: Ping-Pong Buffer Coordination ---");
        flush_slave();
        // Backpressure when producer is NOT ready
        pp_producer_ready = 1'b0;
        start_dma(32'h0000_1B00, 32'h0000_2B00, 16'd2, 1'b1);
        @(posedge clk);
        @(negedge clk);
        check_val("S19.1: DMA held in ST_VALIDATE when pp_producer_ready is 0", dma_state, ST_VALIDATE);
        check_bool("S19.2: pp_producer_start is low", pp_producer_start, 1'b0);
        // Release buffer
        pp_producer_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        check_bool("S19.3: pp_producer_start asserts to lock buffer", pp_producer_start, 1'b1);
        wait_done(50);
        check_bool("S19.4: pp_producer_done asserts upon transfer completion", pp_producer_done, 1'b1);
        check_bool("S19.5: dma_done_pulse synchronized with pp_producer_done", dma_done_pulse, 1'b1);

        // ---------------------------------------------------------------------
        // Test Summary
        // ---------------------------------------------------------------------
        $display("\n==================================================================");
        $display("TSK-06 Test Summary: Total=%0d, Passed=%0d, Failed=%0d", test_count, pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-06 DMA Controller Tests Passed!");
            $finish(0);
        end else begin
            $display("[FAILURE] Some TSK-06 tests failed!");
            $finish(1);
        end
    end

endmodule
