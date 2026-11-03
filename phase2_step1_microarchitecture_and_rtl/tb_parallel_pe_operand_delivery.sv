// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-09 Parallel PE Operand Delivery Verification
// Module: tb_parallel_pe_operand_delivery.sv
// Description: Verification testbench for independent 4x16 parallel operand
//              delivery across the 64-PE array.
// =============================================================================

`timescale 1ns / 1ps

module tb_parallel_pe_operand_delivery;

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

    // Layer Command Interface
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

    // DMA Configuration Interface
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

    // AXI Master Read Channel
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

    // Testbench Variables
    logic [31:0] sys_memory [0:4095];
    int          test_count;
    int          pass_count;
    int          fail_count;
    int          idx, loop_i, timeout_cnt;

    // Golden Reference Model Matrix
    logic signed [ACCUM_WIDTH-1:0] golden_ref [0:ROWS-1][0:COLS-1];

    // -------------------------------------------------------------------------
    // Device Under Test (DUT) - PARALLEL_OPERAND_MODE = 1
    // -------------------------------------------------------------------------
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
        .PARALLEL_OPERAND_MODE (1'b1)
    ) dut (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .cfg_parallel_en       (1'b1),
        .cmd_valid             (cmd_valid),
        .cmd_ready             (cmd_ready),
        .cmd_layer_id          (cmd_layer_id),
        .cmd_pe_mode           (cmd_pe_mode),
        .cmd_adaptive_en       (cmd_adaptive_en),
        .cmd_degradation_hat_16(cmd_degradation_hat_16),
        .cmd_degradation_hat_32(cmd_degradation_hat_32),
        .cmd_degradation_hat_64(cmd_degradation_hat_64),
        .cmd_use_ping_pong     (cmd_use_ping_pong),
        .cmd_req_buf_id        (cmd_req_buf_id),
        .cmd_k_total           (cmd_k_total),
        .layer_done_pulse      (layer_done_pulse),
        .layer_done_id         (layer_done_id),
        .sequencer_busy        (sequencer_busy),
        .sequencer_state       (sequencer_state),
        .sequencer_error_flag  (sequencer_error_flag),
        .sequencer_error_code  (sequencer_error_code),
        .sequencer_error_clear (sequencer_error_clear),
        .dma_start             (dma_start),
        .dma_src_addr          (dma_src_addr),
        .dma_dst_addr          (dma_dst_addr),
        .dma_transfer_len      (dma_transfer_len),
        .dma_use_ping_pong     (dma_use_ping_pong),
        .dma_error_clear       (dma_error_clear),
        .dma_busy              (dma_busy),
        .dma_state             (dma_state),
        .dma_done_pulse        (dma_done_pulse),
        .dma_error_flag        (dma_error_flag),
        .dma_error_code        (dma_error_code),
        .m_axi_araddr          (m_axi_araddr),
        .m_axi_arlen           (m_axi_arlen),
        .m_axi_arsize          (m_axi_arsize),
        .m_axi_arburst         (m_axi_arburst),
        .m_axi_arvalid         (m_axi_arvalid),
        .m_axi_arready         (m_axi_arready),
        .m_axi_rdata           (m_axi_rdata),
        .m_axi_rresp           (m_axi_rresp),
        .m_axi_rlast           (m_axi_rlast),
        .m_axi_rvalid          (m_axi_rvalid),
        .m_axi_rready          (m_axi_rready),
        .accum_out             (accum_out),
        .array_sticky_saturation(array_sticky_saturation),
        .col_sticky_saturation (col_sticky_saturation),
        .active_cfg_mode       (active_cfg_mode),
        .active_pe_count       (active_pe_count),
        .col_active            (col_active),
        .buf_state_a           (buf_state_a),
        .buf_state_b           (buf_state_b),
        .total_produced_count  (total_produced_count),
        .total_consumed_count  (total_consumed_count)
    );

    // Clock Generation
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // AXI Slave Memory Responder
    logic [31:0] ar_addr_latched;
    logic [7:0]  ar_len_latched;
    int          axi_burst_cnt;
    typedef enum logic [1:0] {AXI_IDLE, AXI_DATA} axi_state_t;
    axi_state_t axi_st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_arready   <= 1'b0;
            m_axi_rvalid    <= 1'b0;
            m_axi_rdata     <= '0;
            m_axi_rresp     <= 2'b00;
            m_axi_rlast     <= 1'b0;
            axi_st          <= AXI_IDLE;
            ar_addr_latched <= '0;
            ar_len_latched  <= '0;
            axi_burst_cnt   <= 0;
        end else begin
            case (axi_st)
                AXI_IDLE: begin
                    m_axi_rvalid  <= 1'b0;
                    m_axi_rlast   <= 1'b0;
                    m_axi_arready <= 1'b1;
                    if (m_axi_arvalid && m_axi_arready) begin
                        ar_addr_latched <= m_axi_araddr;
                        ar_len_latched  <= m_axi_arlen;
                        axi_burst_cnt   <= 0;
                        m_axi_arready   <= 1'b0;
                        axi_st          <= AXI_DATA;
                    end
                end

                AXI_DATA: begin
                    if (!m_axi_rvalid || m_axi_rready) begin
                        m_axi_rvalid <= 1'b1;
                        m_axi_rdata  <= sys_memory[(ar_addr_latched >> 2) + axi_burst_cnt];
                        m_axi_rresp  <= 2'b00;
                        if (axi_burst_cnt == ar_len_latched) begin
                            m_axi_rlast <= 1'b1;
                            axi_st      <= AXI_IDLE;
                        end else begin
                            m_axi_rlast   <= 1'b0;
                            axi_burst_cnt <= axi_burst_cnt + 1;
                        end
                    end
                end
            endcase
        end
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

    // System Reset Task
    task automatic apply_reset();
        rst_n                  = 1'b0;
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

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // Command Dispatch
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
        cmd_degradation_hat_16 = 32'd0;
        cmd_degradation_hat_32 = 32'd0;
        cmd_degradation_hat_64 = 32'd0;
        cmd_use_ping_pong      = use_pp;
        cmd_req_buf_id         = buf_id;
        cmd_k_total            = k_tot;
        @(negedge clk);
        cmd_valid              = 1'b0;
    endtask

    // DMA Dispatch
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

    // Wait Tasks (with 10x safety factor to accommodate burst lengths)
    task automatic wait_layer_done(input int max_cycles);
        timeout_cnt = 0;
        while (!layer_done_pulse && (timeout_cnt < max_cycles * 10)) begin
            @(posedge clk);
            timeout_cnt++;
        end
        if (timeout_cnt >= max_cycles * 10) begin
            $display("[ERROR] Timeout waiting for layer_done_pulse!");
        end
    endtask

    task automatic wait_dma_done(input int max_cycles);
        timeout_cnt = 0;
        while (!dma_done_pulse && (timeout_cnt < max_cycles * 10)) begin
            @(posedge clk);
            timeout_cnt++;
        end
        if (timeout_cnt >= max_cycles * 10) begin
            $display("[ERROR] Timeout waiting for dma_done_pulse!");
        end
    endtask

    // -------------------------------------------------------------------------
    // Helper Task: Pack One K-Step into System Memory using packed vectors
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // MAIN VERIFICATION PROCEDURE
    // -------------------------------------------------------------------------
    initial begin
        $display("==================================================================");
        $display("TSK-09: Independent 4x16 Parallel PE Operand Delivery Verification");
        $display("==================================================================");
        test_count = 0;
        pass_count = 0;
        fail_count = 0;

        apply_reset();

        // =====================================================================
        // SCENARIO 1: Distinct Signed Operands Across 64 PEs (K=2, 64-PE Mode)
        // =====================================================================
        $display("\n--- SCENARIO 1: Distinct Signed Operands Across All 64 PEs (K=2) ---");
        apply_reset();

        begin
            logic [255:0] w_s0;
            logic [63:0]  a_s0;
            logic [255:0] w_s1;
            logic [63:0]  a_s1;
            logic signed [15:0] a_val0 [0:3];
            logic signed [15:0] w_val0 [0:15];
            logic signed [15:0] a_val1 [0:3];
            logic signed [15:0] w_val1 [0:15];

            // Step 0: Distinct weights per column, distinct activations per row
            for (int c = 0; c < 16; c++) begin
                w_val0[c] = c + 1; // 1, 2, ..., 16
                w_s0[c*16 +: 16] = w_val0[c];
            end
            a_val0[0] = 16'sd10;  a_s0[0*16 +: 16] = a_val0[0];
            a_val0[1] = -16'sd5;  a_s0[1*16 +: 16] = a_val0[1];
            a_val0[2] = 16'sd20;  a_s0[2*16 +: 16] = a_val0[2];
            a_val0[3] = -16'sd12; a_s0[3*16 +: 16] = a_val0[3];

            // Step 1: Distinct weights per column, distinct activations per row
            for (int c = 0; c < 16; c++) begin
                w_val1[c] = -(c + 2); // -2, -3, ..., -17
                w_s1[c*16 +: 16] = w_val1[c];
            end
            a_val1[0] = -16'sd8;  a_s1[0*16 +: 16] = a_val1[0];
            a_val1[1] = 16'sd14;  a_s1[1*16 +: 16] = a_val1[1];
            a_val1[2] = -16'sd6;  a_s1[2*16 +: 16] = a_val1[2];
            a_val1[3] = 16'sd25;  a_s1[3*16 +: 16] = a_val1[3];

            pack_k_step(0,  w_s0, a_s0);
            pack_k_step(10, w_s1, a_s1);

            // Compute software golden reference
            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    golden_ref[r][c] = (a_val0[r] * w_val0[c]) + (a_val1[r] * w_val1[c]);
                end
            end
        end

        // Ingest 20 words via DMA into Buffer A
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd20, 1'b1);
        wait_dma_done(200);
        check_bool("S1.1: DMA ingested 20 words into Buffer A", dma_done_pulse, 1'b1);
        @(posedge clk);

        // Execute Layer 101 with K=2 in 64-PE mode
        issue_cmd(16'd101, 2'b10, 1'b0, 1'b1, 1'b0, 16'd2);
        wait_layer_done(200);
        check_val("S1.2: Layer 101 completed", layer_done_id, 16'd101);

        // Verify that all 64 PE outputs match independent golden calculations
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                check_val40($sformatf("S1.3: PE[%0d][%0d] matches independent golden", r, c),
                            accum_out[r][c], golden_ref[r][c]);
            end
        end

        // Non-Trivial Distinctness Check (Strict Requirement 12)
        check_bool("S1.4: PE[0][0] and PE[0][1] are distinct across columns",
                   (accum_out[0][0] !== accum_out[0][1]), 1'b1);
        check_bool("S1.5: PE[0][0] and PE[1][0] are distinct across rows",
                   (accum_out[0][0] !== accum_out[1][0]), 1'b1);
        check_bool("S1.6: PE[0][0] (26) and PE[3][15] (-617) are distinct across corners",
                   (accum_out[0][0] !== accum_out[3][15]), 1'b1);

        // =====================================================================
        // SCENARIO 2: Mixed Zero/Nonzero Activations & Exact-Zero Skipping (K=3)
        // =====================================================================
        $display("\n--- SCENARIO 2: Mixed Zero and Nonzero Activations & Zero Skipping (K=3) ---");
        apply_reset();

        begin
            logic [255:0] w_s0, w_s1, w_s2;
            logic [63:0]  a_s0, a_s1, a_s2;
            logic signed [15:0] a_val0 [0:3], a_val1 [0:3], a_val2 [0:3];
            logic signed [15:0] w_val0 [0:15], w_val1 [0:15], w_val2 [0:15];

            // Step 0: Row 0 is 0 (skip), Row 1 is 30, Row 2 is 0 (skip), Row 3 is -15
            for (int c = 0; c < 16; c++) begin
                w_val0[c] = (c + 1);
                w_s0[c*16 +: 16] = w_val0[c];
            end
            a_val0[0] = 16'sd0;   a_s0[0*16 +: 16] = a_val0[0];
            a_val0[1] = 16'sd30;  a_s0[1*16 +: 16] = a_val0[1];
            a_val0[2] = 16'sd0;   a_s0[2*16 +: 16] = a_val0[2];
            a_val0[3] = -16'sd15; a_s0[3*16 +: 16] = a_val0[3];

            // Step 1: Row 0 is 25, Row 1 is 0 (skip), Row 2 is -40, Row 3 is 0 (skip)
            for (int c = 0; c < 16; c++) begin
                w_val1[c] = 2 * (c + 1);
                w_s1[c*16 +: 16] = w_val1[c];
            end
            a_val1[0] = 16'sd25;  a_s1[0*16 +: 16] = a_val1[0];
            a_val1[1] = 16'sd0;   a_s1[1*16 +: 16] = a_val1[1];
            a_val1[2] = -16'sd40; a_s1[2*16 +: 16] = a_val1[2];
            a_val1[3] = 16'sd0;   a_s1[3*16 +: 16] = a_val1[3];

            // Step 2: All rows are 0 (all skipped!)
            for (int c = 0; c < 16; c++) begin
                w_val2[c] = 16'sd100;
                w_s2[c*16 +: 16] = w_val2[c];
            end
            a_val2[0] = 16'sd0; a_s2[0*16 +: 16] = a_val2[0];
            a_val2[1] = 16'sd0; a_s2[1*16 +: 16] = a_val2[1];
            a_val2[2] = 16'sd0; a_s2[2*16 +: 16] = a_val2[2];
            a_val2[3] = 16'sd0; a_s2[3*16 +: 16] = a_val2[3];

            pack_k_step(0,  w_s0, a_s0);
            pack_k_step(10, w_s1, a_s1);
            pack_k_step(20, w_s2, a_s2);

            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    golden_ref[r][c] = (a_val0[r] * w_val0[c]) + (a_val1[r] * w_val1[c]) + (a_val2[r] * w_val2[c]);
                end
            end
        end

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd30, 1'b1);
        wait_dma_done(60);
        @(posedge clk);

        issue_cmd(16'd201, 2'b10, 1'b0, 1'b1, 1'b0, 16'd3);
        wait_layer_done(60);
        check_val("S2.1: Layer 201 completed", layer_done_id, 16'd201);

        // Verify independent zero-skipping preserves accumulators
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                check_val40($sformatf("S2.2: PE[%0d][%0d] zero-skipping matched", r, c),
                            accum_out[r][c], golden_ref[r][c]);
            end
        end

        // =====================================================================
        // SCENARIO 3: Adaptive PE Allocation & Inactive Column Clamping
        // =====================================================================
        $display("\n--- SCENARIO 3: Adaptive Allocation Modes (16-PE and 32-PE Modes) ---");

        // Part A: 16-PE Mode (Columns 0..3 active, Columns 4..15 clamped)
        apply_reset();
        begin
            logic [255:0] w_m0;
            logic [63:0]  a_m0;
            for (int c = 0; c < 16; c++) w_m0[c*16 +: 16] = (c + 1) * 3;
            a_m0[0*16 +: 16] = 16'sd7;
            a_m0[1*16 +: 16] = 16'sd11;
            a_m0[2*16 +: 16] = 16'sd13;
            a_m0[3*16 +: 16] = 16'sd17;
            pack_k_step(0, w_m0, a_m0);
        end
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd10, 1'b1);
        wait_dma_done(50);
        @(posedge clk);

        issue_cmd(16'd301, 2'b00, 1'b0, 1'b1, 1'b0, 16'd1); // 16-PE mode
        wait_layer_done(50);
        check_val("S3.1: 16-PE mode active count is 16", active_pe_count, 7'd16);
        check_val("S3.2: 16-PE mode col_active is 0x000F", col_active, 16'h000F);

        // Check active columns 0..3
        check_val40("S3.3: PE[0][0] equals 7 * 3 = 21", accum_out[0][0], 40'sd21);
        check_val40("S3.4: PE[3][3] equals 17 * 12 = 204", accum_out[3][3], 40'sd204);
        // Check inactive columns 4..15 are strictly clamped to 0
        check_val40("S3.5: Inactive PE[0][4] clamped to 0", accum_out[0][4], 40'sd0);
        check_val40("S3.6: Inactive PE[3][15] clamped to 0", accum_out[3][15], 40'sd0);

        // Part B: 32-PE Mode (Columns 0..7 active, Columns 8..15 clamped)
        apply_reset();
        begin
            logic [255:0] w_m1;
            logic [63:0]  a_m1;
            for (int c = 0; c < 16; c++) w_m1[c*16 +: 16] = (c + 1) * 2;
            a_m1[0*16 +: 16] = 16'sd5;
            a_m1[1*16 +: 16] = 16'sd10;
            a_m1[2*16 +: 16] = 16'sd15;
            a_m1[3*16 +: 16] = 16'sd20;
            pack_k_step(0, w_m1, a_m1);
        end
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd10, 1'b1);
        wait_dma_done(50);
        @(posedge clk);

        issue_cmd(16'd302, 2'b01, 1'b0, 1'b1, 1'b0, 16'd1); // 32-PE mode
        wait_layer_done(50);
        check_val("S3.7: 32-PE mode active count is 32", active_pe_count, 7'd32);
        check_val("S3.8: 32-PE mode col_active is 0x00FF", col_active, 16'h00FF);
        check_val40("S3.9: PE[0][7] equals 5 * 16 = 80", accum_out[0][7], 40'sd80);
        check_val40("S3.10: Inactive PE[0][8] clamped to 0", accum_out[0][8], 40'sd0);

        // =====================================================================
        // SCENARIO 4: Multi-Step K Progression (K=8 Reduction Steps)
        // =====================================================================
        $display("\n--- SCENARIO 4: Multi-Step K Progression (K=8, 80 Words) ---");
        apply_reset();

        for (int k = 0; k < 8; k++) begin
            logic [255:0] w_k;
            logic [63:0]  a_k;
            for (int c = 0; c < 16; c++) w_k[c*16 +: 16] = (c + 1) + k;
            for (int r = 0; r < 4; r++)  a_k[r*16 +: 16] = (r + 1) * 2;
            pack_k_step(k * 10, w_k, a_k);
        end

        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                golden_ref[r][c] = '0;
                for (int k = 0; k < 8; k++) begin
                    golden_ref[r][c] += ((r + 1) * 2) * ((c + 1) + k);
                end
            end
        end

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd80, 1'b1);
        wait_dma_done(120);
        @(posedge clk);

        issue_cmd(16'd401, 2'b10, 1'b0, 1'b1, 1'b0, 16'd8);
        wait_layer_done(100);
        check_val("S4.1: K=8 Layer completed", layer_done_id, 16'd401);

        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                check_val40($sformatf("S4.2: PE[%0d][%0d] K=8 accumulation match", r, c),
                            accum_out[r][c], golden_ref[r][c]);
            end
        end

        // =====================================================================
        // SCENARIO 5: Multi-Bank SRAM Conflict Monitoring
        // =====================================================================
        $display("\n--- SCENARIO 5: SRAM Conflict Monitoring ---");
        check_val("S5.1: Zero SRAM bank conflict stalls occurred",
                  dut.u_sram_subsystem.total_conflicts_count, 32'd0);

        // =====================================================================
        // SCENARIO 6: Backpressure & Delayed Operand Availability (Buffer A)
        // =====================================================================
        $display("\n--- SCENARIO 6: Backpressure & Delayed Operand Availability ---");
        apply_reset();

        // Request Buffer A (req_buf_id = 0) while Buffer A is EMPTY
        issue_cmd(16'd601, 2'b10, 1'b0, 1'b1, 1'b0, 16'd1);
        repeat (5) @(posedge clk);
        check_val("S6.1: Sequencer stalled waiting for Buffer A", sequencer_state, 4'd2);
        check_val("S6.2: Buffer A is EMPTY", buf_state_a, 2'b00);

        // Now populate Buffer A data into sys_memory at offset 0x2000
        begin
            logic [255:0] w_b;
            logic [63:0]  a_b;
            for (int c = 0; c < 16; c++) w_b[c*16 +: 16] = (c + 1) * 4;
            a_b[0*16 +: 16] = 16'sd3;
            a_b[1*16 +: 16] = 16'sd6;
            a_b[2*16 +: 16] = 16'sd9;
            a_b[3*16 +: 16] = 16'sd12;
            pack_k_step(32'h2000 >> 2, w_b, a_b);
        end

        // DMA produces Buffer A (dst = 0x0000 = BUF_A_BASE)
        start_dma(32'h0000_2000, 32'h0000_0000, 16'd10, 1'b1);
        wait_dma_done(50);
        check_bool("S6.3: DMA produced Buffer A", dma_done_pulse, 1'b1);
        @(posedge clk);

        // Sequencer should un-stall and finish execution
        wait_layer_done(50);
        check_val("S6.4: Un-stalled Layer 601 completed", layer_done_id, 16'd601);
        check_val40("S6.5: PE[0][0] equals 3 * 4 = 12", accum_out[0][0], 40'sd12);
        check_val40("S6.6: PE[3][15] equals 12 * 64 = 768", accum_out[3][15], 40'sd768);

        // =====================================================================
        // SCENARIO 7: Overlapped Ping-Pong Buffer Switching (Buffer A -> Buffer B)
        // =====================================================================
        $display("\n--- SCENARIO 7: Overlapped Ping-Pong Buffering (Buffer A -> Buffer B) ---");
        apply_reset();

        // 1. Fill Buffer A with Layer 701 data
        begin
            logic [255:0] w_pa;
            logic [63:0]  a_pa;
            for (int c = 0; c < 16; c++) w_pa[c*16 +: 16] = (c + 1);
            a_pa[0*16 +: 16] = 16'sd10;
            a_pa[1*16 +: 16] = 16'sd20;
            a_pa[2*16 +: 16] = 16'sd30;
            a_pa[3*16 +: 16] = 16'sd40;
            pack_k_step(32'h1000 >> 2, w_pa, a_pa);
        end
        start_dma(32'h0000_1000, 32'h0000_0000, 16'd10, 1'b1);
        wait_dma_done(50);
        @(posedge clk);

        // 2. Pre-fill Buffer B with Layer 702 data
        begin
            logic [255:0] w_pb;
            logic [63:0]  a_pb;
            for (int c = 0; c < 16; c++) w_pb[c*16 +: 16] = (c + 1) * 5;
            a_pb[0*16 +: 16] = 16'sd2;
            a_pb[1*16 +: 16] = 16'sd4;
            a_pb[2*16 +: 16] = 16'sd6;
            a_pb[3*16 +: 16] = 16'sd8;
            pack_k_step(32'h2500 >> 2, w_pb, a_pb);
        end
        start_dma(32'h0000_2500, 32'h0000_4000, 16'd10, 1'b1);
        wait_dma_done(50);
        @(posedge clk);

        check_val("S7.1: Buffer A is READY", buf_state_a, 2'b10);
        check_val("S7.2: Buffer B is READY concurrently", buf_state_b, 2'b10);

        // Execute Layer 701 on Buffer A
        issue_cmd(16'd701, 2'b10, 1'b0, 1'b1, 1'b0, 16'd1);
        wait_layer_done(50);
        check_val("S7.3: Layer 701 completed", layer_done_id, 16'd701);
        check_val40("S7.4: Layer 701 PE[0][0] equals 10 * 1 = 10", accum_out[0][0], 40'sd10);
        check_val("S7.5: Buffer A consumed and EMPTY", buf_state_a, 2'b00);
        check_val("S7.6: Buffer B retained READY", buf_state_b, 2'b10);

        // Immediately execute Layer 702 on Buffer B without reload
        issue_cmd(16'd702, 2'b10, 1'b0, 1'b1, 1'b1, 16'd1);
        wait_layer_done(50);
        check_val("S7.7: Layer 702 completed", layer_done_id, 16'd702);
        check_val40("S7.8: Layer 702 PE[0][0] equals 2 * 5 = 10", accum_out[0][0], 40'sd10);
        check_val40("S7.9: Layer 702 PE[3][15] equals 8 * 80 = 640", accum_out[3][15], 40'sd640);
        check_val("S7.10: Buffer B consumed and EMPTY", buf_state_b, 2'b00);

        // =====================================================================
        // FINAL SUMMARY
        // =====================================================================
        $display("\n==================================================================");
        $display("TSK-09 Parallel Delivery Summary: Total=%0d, Passed=%0d, Failed=%0d",
                 test_count, pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-09 Parallel PE Operand Delivery Tests Passed with Zero Failures!");
            $finish(0);
        end else begin
            $display("[FAIL] %0d tests failed in TSK-09 suite!", fail_count);
            $finish(1);
        end
    end

endmodule
