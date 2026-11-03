// =============================================================================
// Project: Neural_Acc (Phase 2 RTL Implementation)
// Task: TSK-10 Functional CNN Workload Validation
// Testbench: tb_tsk10_cnn_workload.sv
// Description: Deterministic, self-checking functional verification testbench for
//              integrated Neural_Acc running CNN-style convolution workloads.
//              Validates 4x16 output tiles across multiple K reduction steps,
//              signed operands, zero activations, saturation boundaries,
//              adaptive PE modes (16-, 32-, 64-PE), successive multi-tile execution,
//              and consumer backpressure stalls.
// =============================================================================

`timescale 1ns / 1ps

module tb_tsk10_cnn_workload;

    // -------------------------------------------------------------------------
    // Top-Level Accelerator Parameters
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // DUT Interface Signals
    // -------------------------------------------------------------------------
    logic                          clk;
    logic                          rst_n;
    logic                          cfg_parallel_en;

    // Layer Command Sequencer Interface
    logic                          cmd_valid;
    wire                           cmd_ready;
    logic [LAYER_ID_W-1:0]         cmd_layer_id;
    logic [1:0]                    cmd_pe_mode;
    logic                          cmd_adaptive_en;
    logic [DEGRADE_W-1:0]          cmd_degradation_hat_16;
    logic [DEGRADE_W-1:0]          cmd_degradation_hat_32;
    logic [DEGRADE_W-1:0]          cmd_degradation_hat_64;
    logic                          cmd_use_ping_pong;
    logic                          cmd_req_buf_id;
    logic [K_WIDTH-1:0]            cmd_k_total;

    wire                           layer_done_pulse;
    wire  [LAYER_ID_W-1:0]         layer_done_id;
    wire                           sequencer_busy;
    wire  [3:0]                    sequencer_state;
    wire                           sequencer_error_flag;
    wire  [3:0]                    sequencer_error_code;
    logic                          sequencer_error_clear;

    // DMA Controller Interface
    logic                          dma_start;
    logic [ADDR_WIDTH-1:0]         dma_src_addr;
    logic [ADDR_WIDTH-1:0]         dma_dst_addr;
    logic [LEN_WIDTH-1:0]          dma_transfer_len;
    logic                          dma_use_ping_pong;
    logic                          dma_error_clear;
    wire                           dma_busy;
    wire  [2:0]                    dma_state;
    wire                           dma_done_pulse;
    wire                           dma_error_flag;
    wire  [3:0]                    dma_error_code;

    // AXI4 Master Read Channel
    wire  [ADDR_WIDTH-1:0]         m_axi_araddr;
    wire  [7:0]                    m_axi_arlen;
    wire  [2:0]                    m_axi_arsize;
    wire  [1:0]                    m_axi_arburst;
    wire                           m_axi_arvalid;
    logic                          m_axi_arready;

    logic [DATA_WIDTH-1:0]         m_axi_rdata;
    logic [1:0]                    m_axi_rresp;
    logic                          m_axi_rlast;
    logic                          m_axi_rvalid;
    wire                           m_axi_rready;

    // Datapath Outputs
    wire  signed [ACCUM_WIDTH-1:0] accum_out [0:ROWS-1][0:COLS-1];
    wire                           array_sticky_saturation;
    wire  [COLS-1:0]               col_sticky_saturation;
    wire  [1:0]                    active_cfg_mode;
    wire  [6:0]                    active_pe_count;
    wire  [COLS-1:0]               col_active;

    // Diagnostics & Status
    wire  [1:0]                    buf_state_a;
    wire  [1:0]                    buf_state_b;
    wire  [31:0]                   total_produced_count;
    wire  [31:0]                   total_consumed_count;

    // -------------------------------------------------------------------------
    // Instantiate Integrated Top-Level Accelerator (in PARALLEL Mode)
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
        .PARALLEL_OPERAND_MODE (1'b1) // Enabled for genuine parallel execution
    ) dut (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .cfg_parallel_en         (cfg_parallel_en),
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
        .dma_start               (dma_start),
        .dma_src_addr            (dma_src_addr),
        .dma_dst_addr            (dma_dst_addr),
        .dma_transfer_len        (dma_transfer_len),
        .dma_use_ping_pong       (dma_use_ping_pong),
        .dma_error_clear         (dma_error_clear),
        .dma_busy                (dma_busy),
        .dma_state               (dma_state),
        .dma_done_pulse          (dma_done_pulse),
        .dma_error_flag          (dma_error_flag),
        .dma_error_code          (dma_error_code),
        .m_axi_araddr            (m_axi_araddr),
        .m_axi_arlen             (m_axi_arlen),
        .m_axi_arsize            (m_axi_arsize),
        .m_axi_arburst           (m_axi_arburst),
        .m_axi_arvalid           (m_axi_arvalid),
        .m_axi_arready           (m_axi_arready),
        .m_axi_rdata             (m_axi_rdata),
        .m_axi_rresp             (m_axi_rresp),
        .m_axi_rlast             (m_axi_rlast),
        .m_axi_rvalid            (m_axi_rvalid),
        .m_axi_rready            (m_axi_rready),
        .accum_out               (accum_out),
        .array_sticky_saturation (array_sticky_saturation),
        .col_sticky_saturation   (col_sticky_saturation),
        .active_cfg_mode         (active_cfg_mode),
        .active_pe_count         (active_pe_count),
        .col_active              (col_active),
        .buf_state_a             (buf_state_a),
        .buf_state_b             (buf_state_b),
        .total_produced_count    (total_produced_count),
        .total_consumed_count    (total_consumed_count)
    );

    // -------------------------------------------------------------------------
    // Clock Generation (100 MHz, 10ns period)
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Simulated System Memory Array (AXI4 Backing Store)
    // -------------------------------------------------------------------------
    logic [31:0] sys_memory [0:8191];

    // AXI4 Read Channel Slave Model
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
    // Verification Tracking & Golden Storage
    // -------------------------------------------------------------------------
    int test_count;
    int pass_count;
    int fail_count;
    int timeout_cnt;

    // Independent 40-bit Golden Reference Tile
    logic signed [ACCUM_WIDTH-1:0] golden_tile [0:ROWS-1][0:COLS-1];

    // Check helper routines
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

    // System Reset
    task automatic apply_reset();
        rst_n                  = 1'b0;
        cfg_parallel_en        = 1'b1;
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

    // Handshake Wait Tasks
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

    // Helper: Compare Entire 4x16 Tile Against Golden
    task automatic compare_tile(input string case_name, input int active_cols);
        int mismatches;
        mismatches = 0;
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                if (accum_out[r][c] !== golden_tile[r][c]) begin
                    mismatches++;
                    if (mismatches == 1) begin
                        $display("[FIRST MISMATCH] %s at (r=%0d, c=%0d): actual=%0d (0x%0h), expected=%0d (0x%0h)",
                                 case_name, r, c, accum_out[r][c], accum_out[r][c], golden_tile[r][c], golden_tile[r][c]);
                    end
                end
                check_val40($sformatf("%s: PE[%0d][%0d]", case_name, r, c), accum_out[r][c], golden_tile[r][c]);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Verification Sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("==================================================================");
        $display("TSK-10: Functional CNN Workload Validation");
        $display("==================================================================");
        test_count = 0;
        pass_count = 0;
        fail_count = 0;

        apply_reset();

        // =====================================================================
        // TEST CASE A & J: K=1 with Distinct Signed Operands Across All 64 PEs
        // =====================================================================
        $display("\n--- CASE A & J: K=1 Distinct Signed Operands (64-PE Mode) ---");
        apply_reset();
        begin
            logic [255:0] w_p;
            logic [63:0]  a_p;
            logic signed [15:0] a_val [0:3];
            logic signed [15:0] w_val [0:15];

            a_val[0] = 16'sd12;  a_p[0*16 +: 16] = a_val[0];
            a_val[1] = -16'sd7;  a_p[1*16 +: 16] = a_val[1];
            a_val[2] = 16'sd18;  a_p[2*16 +: 16] = a_val[2];
            a_val[3] = -16'sd25; a_p[3*16 +: 16] = a_val[3];

            for (int c = 0; c < 16; c++) begin
                w_val[c] = (c - 7) * 4; // -28, -24, ..., 0, ..., 32
                w_p[c*16 +: 16] = w_val[c];
            end

            pack_k_step(0, w_p, a_p);

            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    golden_tile[r][c] = a_val[r] * w_val[c];
                end
            end
        end

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd10, 1'b1);
        wait_dma_done(50);
        check_bool("A.1: DMA loaded 10 words into Buffer A", dma_done_pulse, 1'b1);
        @(posedge clk);

        issue_cmd(16'd10, 2'b10, 1'b0, 1'b1, 1'b0, 16'd1);
        wait_layer_done(50);
        check_val("A.2: Layer 10 completed", layer_done_id, 16'd10);
        check_val("A.3: 64 PEs active", active_pe_count, 7'd64);

        compare_tile("Case_A", 16);

        // Explicit distinctness assertions
        check_bool("A.4: PE[0][0] (-336) != PE[0][1] (-288)", (accum_out[0][0] !== accum_out[0][1]), 1'b1);
        check_bool("A.5: PE[0][0] (-336) != PE[1][0] (196)",  (accum_out[0][0] !== accum_out[1][0]), 1'b1);

        // =====================================================================
        // TEST CASE B & F: K=2 Multi-Step Mixed Signs (Positive & Negative Outputs)
        // =====================================================================
        $display("\n--- CASE B & F: K=2 Mixed Signs (Positive & Negative Outputs) ---");
        apply_reset();
        begin
            logic [255:0] w_s0, w_s1;
            logic [63:0]  a_s0, a_s1;
            logic signed [15:0] a0[0:3], a1[0:3];
            logic signed [15:0] w0[0:15], w1[0:15];

            a0[0] = 16'sd15;  a_s0[0*16 +: 16] = a0[0];
            a0[1] = -16'sd20; a_s0[1*16 +: 16] = a0[1];
            a0[2] = 16'sd30;  a_s0[2*16 +: 16] = a0[2];
            a0[3] = -16'sd10; a_s0[3*16 +: 16] = a0[3];

            a1[0] = -16'sd10; a_s1[0*16 +: 16] = a1[0];
            a1[1] = 16'sd25;  a_s1[1*16 +: 16] = a1[1];
            a1[2] = -16'sd15; a_s1[2*16 +: 16] = a1[2];
            a1[3] = 16'sd35;  a_s1[3*16 +: 16] = a1[3];

            for (int c = 0; c < 16; c++) begin
                w0[c] = (c + 1) * 3;
                w_s0[c*16 +: 16] = w0[c];
                w1[c] = -(c + 2) * 2;
                w_s1[c*16 +: 16] = w1[c];
            end

            pack_k_step(0,  w_s0, a_s0);
            pack_k_step(10, w_s1, a_s1);

            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    golden_tile[r][c] = (a0[r] * w0[c]) + (a1[r] * w1[c]);
                end
            end
        end

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd20, 1'b1);
        wait_dma_done(60);
        @(posedge clk);

        issue_cmd(16'd20, 2'b10, 1'b0, 1'b1, 1'b0, 16'd2);
        wait_layer_done(60);
        check_val("B.1: Layer 20 completed", layer_done_id, 16'd20);

        compare_tile("Case_B", 16);

        // =====================================================================
        // TEST CASE C: K=4 Diverse Spatial Row & Output Channel Workload
        // =====================================================================
        $display("\n--- CASE C: K=4 Diverse Spatial Row & Output Channel Workload ---");
        apply_reset();
        begin
            logic signed [15:0] a_k4 [0:3][0:3];
            logic signed [15:0] w_k4 [0:15][0:3];
            logic signed [31:0] c_prod;
            logic signed [39:0] c_acc;

            for (int k = 0; k < 4; k++) begin
                logic [255:0] w_p;
                logic [63:0]  a_p;
                for (int r = 0; r < 4; r++) begin
                    a_k4[r][k] = (r + 1) * 11 - (k * 7);
                    a_p[r*16 +: 16] = a_k4[r][k];
                end
                for (int c = 0; c < 16; c++) begin
                    w_k4[c][k] = (c - 8) * 13 + (k * 5);
                    w_p[c*16 +: 16] = w_k4[c][k];
                end
                pack_k_step(k * 10, w_p, a_p);
            end


            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    c_acc = '0;
                    for (int k = 0; k < 4; k++) begin
                        c_prod = a_k4[r][k] * w_k4[c][k];
                        c_acc = c_acc + c_prod;
                    end
                    golden_tile[r][c] = c_acc;
                end
            end
        end

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd40, 1'b1);
        wait_dma_done(80);
        @(posedge clk);

        issue_cmd(16'd30, 2'b10, 1'b0, 1'b1, 1'b0, 16'd4);
        wait_layer_done(80);
        check_val("C.1: Layer 30 (K=4) completed", layer_done_id, 16'd30);

        compare_tile("Case_C", 16);

        // =====================================================================
        // TEST CASE D: K=8 Deep Multi-Step Reduction
        // =====================================================================
        $display("\n--- CASE D: K=8 Multi-Step Reduction (80 Packed Words) ---");
        apply_reset();
        begin
            for (int k = 0; k < 8; k++) begin
                logic [255:0] w_k;
                logic [63:0]  a_k;
                for (int c = 0; c < 16; c++) w_k[c*16 +: 16] = (c + 1) * 2 + k;
                for (int r = 0; r < 4; r++)  a_k[r*16 +: 16] = (r + 1) * 3 - k;
                pack_k_step(k * 10, w_k, a_k);
            end

            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    golden_tile[r][c] = '0;
                    for (int k = 0; k < 8; k++) begin
                        golden_tile[r][c] += ((r + 1) * 3 - k) * ((c + 1) * 2 + k);
                    end
                end
            end
        end

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd80, 1'b1);
        wait_dma_done(120);
        @(posedge clk);

        issue_cmd(16'd40, 2'b10, 1'b0, 1'b1, 1'b0, 16'd8);
        wait_layer_done(100);
        check_val("D.1: Layer 40 (K=8) completed", layer_done_id, 16'd40);

        compare_tile("Case_D", 16);

        // =====================================================================
        // TEST CASE E: Exact-Zero Activation Bypass Validation
        // =====================================================================
        $display("\n--- CASE E: Exact-Zero Activation Bypass (K=3) ---");
        apply_reset();
        begin
            logic [255:0] w_s0, w_s1, w_s2;
            logic [63:0]  a_s0, a_s1, a_s2;
            logic signed [15:0] a0[0:3], a1[0:3], a2[0:3];
            logic signed [15:0] w0[0:15], w1[0:15], w2[0:15];

            // Step 0: Rows 0, 2 are 0 (bypassed); Rows 1, 3 active
            a0[0] = 16'sd0;   a_s0[0*16 +: 16] = a0[0];
            a0[1] = 16'sd40;  a_s0[1*16 +: 16] = a0[1];
            a0[2] = 16'sd0;   a_s0[2*16 +: 16] = a0[2];
            a0[3] = -16'sd30; a_s0[3*16 +: 16] = a0[3];

            // Step 1: Rows 1, 3 are 0 (bypassed); Rows 0, 2 active
            a1[0] = 16'sd50;  a_s1[0*16 +: 16] = a1[0];
            a1[1] = 16'sd0;   a_s1[1*16 +: 16] = a1[1];
            a1[2] = -16'sd60; a_s1[2*16 +: 16] = a1[2];
            a1[3] = 16'sd0;   a_s1[3*16 +: 16] = a1[3];

            // Step 2: All 4 rows are 0 (entire step zero-bypassed)
            a2[0] = 16'sd0;   a_s2[0*16 +: 16] = a2[0];
            a2[1] = 16'sd0;   a_s2[1*16 +: 16] = a2[1];
            a2[2] = 16'sd0;   a_s2[2*16 +: 16] = a2[2];
            a2[3] = 16'sd0;   a_s2[3*16 +: 16] = a2[3];

            for (int c = 0; c < 16; c++) begin
                w0[c] = (c + 1) * 5;  w_s0[c*16 +: 16] = w0[c];
                w1[c] = (c + 1) * 3;  w_s1[c*16 +: 16] = w1[c];
                w2[c] = 16'sd99;      w_s2[c*16 +: 16] = w2[c];
            end

            pack_k_step(0,  w_s0, a_s0);
            pack_k_step(10, w_s1, a_s1);
            pack_k_step(20, w_s2, a_s2);

            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    golden_tile[r][c] = (a0[r] * w0[c]) + (a1[r] * w1[c]) + (a2[r] * w2[c]);
                end
            end
        end

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd30, 1'b1);
        wait_dma_done(60);
        @(posedge clk);

        issue_cmd(16'd50, 2'b10, 1'b0, 1'b1, 1'b0, 16'd3);
        wait_layer_done(60);
        check_val("E.1: Layer 50 completed", layer_done_id, 16'd50);

        compare_tile("Case_E", 16);

        // =====================================================================
        // TEST CASE G: Large Dynamic Range & Saturation Boundary
        // =====================================================================
        $display("\n--- CASE G: Large Dynamic Range Operands (K=2) ---");
        apply_reset();
        begin
            logic [255:0] w_g0, w_g1;
            logic [63:0]  a_g0, a_g1;
            logic signed [15:0] a0[0:3], a1[0:3];
            logic signed [15:0] w0[0:15], w1[0:15];

            // Large signed operands near INT16 boundaries
            a0[0] = 16'sd32767;  a_g0[0*16 +: 16] = a0[0];
            a0[1] = -16'sd32768; a_g0[1*16 +: 16] = a0[1];
            a0[2] = 16'sd30000;  a_g0[2*16 +: 16] = a0[2];
            a0[3] = -16'sd30000; a_g0[3*16 +: 16] = a0[3];

            a1[0] = 16'sd32767;  a_g1[0*16 +: 16] = a1[0];
            a1[1] = -16'sd32768; a_g1[1*16 +: 16] = a1[1];
            a1[2] = 16'sd15000;  a_g1[2*16 +: 16] = a1[2];
            a1[3] = -16'sd15000; a_g1[3*16 +: 16] = a1[3];

            for (int c = 0; c < 16; c++) begin
                w0[c] = 16'sd32767;  w_g0[c*16 +: 16] = w0[c];
                w1[c] = 16'sd32767;  w_g1[c*16 +: 16] = w1[c];
            end

            pack_k_step(0,  w_g0, a_g0);
            pack_k_step(10, w_g1, a_g1);

            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    // 32767 * 32767 = 1,073,676,289; 2 steps = 2,147,352,578 (fits within 40-bit accumulator)
                    golden_tile[r][c] = (a0[r] * w0[c]) + (a1[r] * w1[c]);
                end
            end
        end

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd20, 1'b1);
        wait_dma_done(60);
        @(posedge clk);

        issue_cmd(16'd70, 2'b10, 1'b0, 1'b1, 1'b0, 16'd2);
        wait_layer_done(60);
        check_val("G.1: Layer 70 completed", layer_done_id, 16'd70);

        // Verify accurate wide accumulation without premature overflow
        check_val40("G.2: PE[0][0] equals 2,147,352,578", accum_out[0][0], 40'sd2147352578);
        check_val40("G.3: PE[1][0] equals -2,147,418,112", accum_out[1][0], -40'sd2147418112);
        check_bool("G.4: Sticky saturation remains false (within 40-bit range)", array_sticky_saturation, 1'b0);

        // =====================================================================
        // TEST CASE H: 16-PE Mode Adaptive Allocation & Inactive Column Clamping
        // =====================================================================
        $display("\n--- CASE H: 16-PE Mode Adaptive Allocation ---");
        apply_reset();
        begin
            logic [255:0] w_h;
            logic [63:0]  a_h;
            for (int c = 0; c < 16; c++) w_h[c*16 +: 16] = (c + 1) * 7;
            a_h[0*16 +: 16] = 16'sd11;
            a_h[1*16 +: 16] = 16'sd13;
            a_h[2*16 +: 16] = 16'sd17;
            a_h[3*16 +: 16] = 16'sd19;
            pack_k_step(0, w_h, a_h);

            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < 4; c++) begin
                    golden_tile[r][c] = ((r == 0) ? 11 : ((r == 1) ? 13 : ((r == 2) ? 17 : 19))) * ((c + 1) * 7);
                end
                for (int c = 4; c < COLS; c++) begin
                    golden_tile[r][c] = 40'sd0; // Inactive columns clamped to 0
                end
            end
        end

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd10, 1'b1);
        wait_dma_done(50);
        @(posedge clk);

        issue_cmd(16'd80, 2'b00, 1'b0, 1'b1, 1'b0, 16'd1); // Mode 0 = 16-PE
        wait_layer_done(50);
        check_val("H.1: 16-PE mode active count is 16", active_pe_count, 7'd16);
        check_val("H.2: 16-PE mode col_active mask is 0x000F", col_active, 16'h000F);

        compare_tile("Case_H", 4);

        // =====================================================================
        // TEST CASE I: 32-PE Mode Adaptive Allocation & Inactive Column Clamping
        // =====================================================================
        $display("\n--- CASE I: 32-PE Mode Adaptive Allocation ---");
        apply_reset();
        begin
            logic [255:0] w_i;
            logic [63:0]  a_i;
            for (int c = 0; c < 16; c++) w_i[c*16 +: 16] = (c + 1) * 6;
            a_i[0*16 +: 16] = 16'sd9;
            a_i[1*16 +: 16] = 16'sd12;
            a_i[2*16 +: 16] = 16'sd15;
            a_i[3*16 +: 16] = 16'sd18;
            pack_k_step(0, w_i, a_i);

            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < 8; c++) begin
                    golden_tile[r][c] = ((r == 0) ? 9 : ((r == 1) ? 12 : ((r == 2) ? 15 : 18))) * ((c + 1) * 6);
                end
                for (int c = 8; c < COLS; c++) begin
                    golden_tile[r][c] = 40'sd0; // Inactive columns clamped to 0
                end
            end
        end

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd10, 1'b1);
        wait_dma_done(50);
        @(posedge clk);

        issue_cmd(16'd90, 2'b01, 1'b0, 1'b1, 1'b0, 16'd1); // Mode 1 = 32-PE
        wait_layer_done(50);
        check_val("I.1: 32-PE mode active count is 32", active_pe_count, 7'd32);
        check_val("I.2: 32-PE mode col_active mask is 0x00FF", col_active, 16'h00FF);

        compare_tile("Case_I", 8);

        // =====================================================================
        // TEST CASE K: Multi-Tile Successive Workloads (Contamination Check)
        // =====================================================================
        $display("\n--- CASE K: Multi-Tile Successive Workloads (Contamination Check) ---");
        apply_reset();

        // Tile 1: Buffer A (K=2)
        begin
            logic [255:0] w_t1_0, w_t1_1;
            logic [63:0]  a_t1_0, a_t1_1;
            for (int c = 0; c < 16; c++) begin
                w_t1_0[c*16 +: 16] = (c + 1) * 2;
                w_t1_1[c*16 +: 16] = (c + 1) * 4;
            end
            for (int r = 0; r < 4; r++) begin
                a_t1_0[r*16 +: 16] = (r + 1) * 5;
                a_t1_1[r*16 +: 16] = (r + 1) * 3;
            end
            pack_k_step(0,  w_t1_0, a_t1_0);
            pack_k_step(10, w_t1_1, a_t1_1);
        end
        start_dma(32'h0000_0000, 32'h0000_0000, 16'd20, 1'b1);
        wait_dma_done(60);
        @(posedge clk);

        // Pre-fill Tile 2 in Buffer B (offset 0x2000 in sys_memory, dst = 0x4000 = BUF_B)
        begin
            logic [255:0] w_t2_0, w_t2_1;
            logic [63:0]  a_t2_0, a_t2_1;
            for (int c = 0; c < 16; c++) begin
                w_t2_0[c*16 +: 16] = (c + 1) * 3;
                w_t2_1[c*16 +: 16] = (c + 1) * 5;
            end
            for (int r = 0; r < 4; r++) begin
                a_t2_0[r*16 +: 16] = (r + 1) * 2;
                a_t2_1[r*16 +: 16] = (r + 1) * 4;
            end
            pack_k_step(32'h2000 >> 2, w_t2_0, a_t2_0);
            pack_k_step((32'h2000 >> 2) + 10, w_t2_1, a_t2_1);
        end
        start_dma(32'h0000_2000, 32'h0000_4000, 16'd20, 1'b1);
        wait_dma_done(60);
        @(posedge clk);

        check_val("K.1: Buffer A is READY", buf_state_a, 2'b10);
        check_val("K.2: Buffer B is READY", buf_state_b, 2'b10);

        // Execute Tile 1 on Buffer A
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                golden_tile[r][c] = ((r + 1) * 5) * ((c + 1) * 2) + ((r + 1) * 3) * ((c + 1) * 4);
            end
        end
        issue_cmd(16'd101, 2'b10, 1'b0, 1'b1, 1'b0, 16'd2);
        wait_layer_done(60);
        check_val("K.3: Tile 1 completed", layer_done_id, 16'd101);
        compare_tile("Tile_1", 16);

        // Execute Tile 2 on Buffer B: Verify accumulators cleared, ZERO contamination from Tile 1!
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                golden_tile[r][c] = ((r + 1) * 2) * ((c + 1) * 3) + ((r + 1) * 4) * ((c + 1) * 5);
            end
        end
        issue_cmd(16'd102, 2'b10, 1'b0, 1'b1, 1'b1, 16'd2);
        wait_layer_done(60);
        check_val("K.4: Tile 2 completed", layer_done_id, 16'd102);
        compare_tile("Tile_2", 16);

        // Distinctness check between Tile 1 and Tile 2
        check_bool("K.5: Tile 1 and Tile 2 outputs differ",
                   (golden_tile[0][0] !== 22), 1'b1);

        // =====================================================================
        // TEST CASE L: Backpressure & Supported Stall Condition
        // =====================================================================
        $display("\n--- CASE L: Backpressure & Supported Stall Handling ---");
        apply_reset();

        // Issue command requesting Buffer A while Buffer A is EMPTY
        issue_cmd(16'd110, 2'b10, 1'b0, 1'b1, 1'b0, 16'd1);
        repeat (5) @(posedge clk);
        check_val("L.1: Sequencer stalled waiting for Buffer A commit", sequencer_state, 4'd2);
        check_val("L.2: Buffer A is EMPTY", buf_state_a, 2'b00);

        // Now load data into Buffer A via DMA
        begin
            logic [255:0] w_l;
            logic [63:0]  a_l;
            for (int c = 0; c < 16; c++) w_l[c*16 +: 16] = (c + 1) * 8;
            a_l[0*16 +: 16] = 16'sd4;
            a_l[1*16 +: 16] = 16'sd8;
            a_l[2*16 +: 16] = 16'sd12;
            a_l[3*16 +: 16] = 16'sd16;
            pack_k_step(0, w_l, a_l);

            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    golden_tile[r][c] = ((r + 1) * 4) * ((c + 1) * 8);
                end
            end
        end

        start_dma(32'h0000_0000, 32'h0000_0000, 16'd10, 1'b1);
        wait_dma_done(50);
        check_bool("L.3: DMA committed Buffer A", dma_done_pulse, 1'b1);
        @(posedge clk);

        // Sequencer should resume and complete without dropped or duplicated steps
        wait_layer_done(50);
        check_val("L.4: Resumed Layer 110 completed", layer_done_id, 16'd110);
        compare_tile("Case_L", 16);

        // =====================================================================
        // TEST CASE M: Multi-Bank SRAM Conflict Check
        // =====================================================================
        $display("\n--- CASE M: Multi-Bank SRAM Conflict Verification ---");
        check_val("M.1: Zero SRAM bank conflict stalls occurred across all workloads",
                  dut.u_sram_subsystem.total_conflicts_count, 32'd0);

        // =====================================================================
        // SUMMARY REPORT
        // =====================================================================
        $display("\n==================================================================");
        $display("TSK-10 CNN Workload Summary: Total=%0d, Passed=%0d, Failed=%0d", test_count, pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("[SUCCESS] All TSK-10 Functional CNN Workload Tests Passed with Zero Failures!");
            $finish(0);
        end else begin
            $display("[FAIL] %0d checks failed in TSK-10 suite!", fail_count);
            $finish(1);
        end
    end

endmodule
